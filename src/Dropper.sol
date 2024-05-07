// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.25;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { MerkleProof } from "openzeppelin-contracts/contracts/utils/cryptography/MerkleProof.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import { Ownable } from "openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title Dropper
 * @author PartyDAO
 * @notice Dropper contract for creating merkle tree based airdrops. Note: this contract is compatible only with ERC20
 * compliant tokens (no fee on transfer or rebasing tokens).
 */
contract Dropper is Ownable {
    using SafeERC20 for IERC20;

    event DropCreated(
        uint256 indexed dropId,
        bytes32 merkleRoot,
        uint256 totalTokens,
        address indexed tokenAddress,
        uint40 startTimestamp,
        uint40 expirationTimestamp,
        address expirationRecipient,
        MerkleMetadata merkleMetadata
    );

    event DropClaimed(uint256 indexed dropId, address indexed recipient, address indexed tokenAddress, uint256 amount);

    event DropRefunded(uint256 indexed dropId, address indexed recipient, address indexed tokenAddress, uint256 amount);

    event ClaimFeeSet(uint256 oldClaimFee, uint256 claimFee);

    event OwnerShareBpsSet(uint16 oldOwnerShareBps, uint16 ownerShareBps);

    struct DropData {
        // Merkle root for the token drop
        bytes32 merkleRoot;
        // Total number of tokens to be dropped
        uint256 totalTokens;
        // Number of tokens claimed so far
        uint256 claimedTokens;
        // Address of the token to be dropped
        address tokenAddress;
        // Timestamp at which the drop will become live
        uint40 startTimestamp;
        // Timestamp at which the drop will expire
        uint40 expirationTimestamp;
        // The owner share in basis points for each claim fee
        uint16 ownerShareBps;
        // The fee to claim a drop in ETH
        uint256 claimFee;
        // Address to which the remaining tokens will be refunded after expiration
        address expirationRecipient;
        // Fees from drop claims will be sent here
        address feeRecipient;
    }

    struct PermitArgs {
        uint256 amount;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct MerkleMetadata {
        string merkleTreeURI;
        string dropDescription;
    }

    error InsufficientPermitAmount();
    error MerkleRootNotSet();
    error TotalTokenIsZero();
    error TokenAddressIsZero();
    error ExpirationTimestampInPast();
    error EndBeforeStart();
    error DropStillLive();
    error AllTokensClaimed();
    error DropNotLive();
    error DropAlreadyClaimed();
    error InsufficientTokensRemaining();
    error InvalidMerkleProof();
    error ArityMismatch();
    error InvalidDropId();
    error ExpirationRecipientIsZero();
    error InvalidBps();
    error InvalidMsgValue();

    mapping(uint256 => DropData) public drops;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    /// @notice The number of drops created on this contract
    uint256 public numDrops;

    /// @notice The fee to claim a drop in ETH. This is cached per drop.
    uint256 private currentClaimFee;

    /// @notice The owner share in basis points (1/10000) for claim fee. This is cached per drop.
    uint16 private currentOwnerShareBps;

    constructor(address owner, uint256 initialClaimFee, uint16 initialOwnerShareBps) Ownable(owner) {
        if (initialOwnerShareBps > 10_000) revert InvalidBps();
        currentClaimFee = initialClaimFee;
        currentOwnerShareBps = initialOwnerShareBps;
    }

    /**
     * @notice Permits the token and creates a new drop with the given parameters
     * @param permitArgs The permit arguments to be passed to the token's permit function
     * @param merkleRoot The merkle root of the merkle tree for the drop
     * @param totalTokens The total number of tokens to be dropped
     * @param tokenAddress The address of the ERC20 token to be dropped. Note: token may not have fee on transfer or
     * rebasing
     * @param startTimestamp The timestamp at which the drop will become live
     * @param expirationTimestamp The timestamp at which the drop will expire
     * @param expirationRecipient The address to which the remaining tokens will be refunded after expiration
     * @param merkleMetadata The metadata for the drop
     * @return dropId The ID of the newly created drop
     */
    function permitAndCreateDrop(
        PermitArgs calldata permitArgs,
        bytes32 merkleRoot,
        uint256 totalTokens,
        address tokenAddress,
        uint40 startTimestamp,
        uint40 expirationTimestamp,
        address expirationRecipient,
        address feeRecipient,
        bool claimFeeEnabled,
        MerkleMetadata calldata merkleMetadata
    )
        external
        returns (uint256)
    {
        // Revert if insufficient approval will be given by permit
        if (permitArgs.amount < totalTokens) revert InsufficientPermitAmount();

        _callPermit(tokenAddress, permitArgs);

        return createDrop(
            merkleRoot,
            totalTokens,
            tokenAddress,
            startTimestamp,
            expirationTimestamp,
            expirationRecipient,
            feeRecipient,
            claimFeeEnabled,
            merkleMetadata
        );
    }

    /**
     * @notice Create a new drop with the given parameters
     * @param merkleRoot The merkle root of the merkle tree for the drop
     * @param totalTokens The total number of tokens to be dropped
     * @param tokenAddress The address of the ERC20 token to be dropped. Note: token may not have fee on transfer or
     * rebasing
     * @param startTimestamp The timestamp at which the drop will become live
     * @param expirationTimestamp The timestamp at which the drop will expire
     * @param expirationRecipient The address to which the remaining tokens will be refunded after expiration
     * @param merkleMetadata The metadata for the drop
     * @return dropId The ID of the newly created drop
     */
    function createDrop(
        bytes32 merkleRoot,
        uint256 totalTokens,
        address tokenAddress,
        uint40 startTimestamp,
        uint40 expirationTimestamp,
        address expirationRecipient,
        address feeRecipient,
        bool claimFeeEnabled,
        MerkleMetadata calldata merkleMetadata
    )
        public
        returns (uint256 dropId)
    {
        if (merkleRoot == bytes32(0)) revert MerkleRootNotSet();
        if (totalTokens == 0) revert TotalTokenIsZero();
        if (tokenAddress == address(0)) revert TokenAddressIsZero();
        if (expirationTimestamp <= block.timestamp) revert ExpirationTimestampInPast();
        if (expirationTimestamp <= startTimestamp) revert EndBeforeStart();
        if (expirationRecipient == address(0)) revert ExpirationRecipientIsZero();

        IERC20(tokenAddress).safeTransferFrom(msg.sender, address(this), totalTokens);

        dropId = ++numDrops;

        drops[dropId] = DropData({
            merkleRoot: merkleRoot,
            totalTokens: totalTokens,
            claimedTokens: 0,
            tokenAddress: tokenAddress,
            startTimestamp: startTimestamp,
            expirationTimestamp: expirationTimestamp,
            ownerShareBps: claimFeeEnabled ? currentOwnerShareBps : 0,
            claimFee: claimFeeEnabled ? currentClaimFee : 0,
            expirationRecipient: expirationRecipient,
            feeRecipient: feeRecipient
        });

        emit DropCreated(
            dropId,
            merkleRoot,
            totalTokens,
            tokenAddress,
            startTimestamp,
            expirationTimestamp,
            expirationRecipient,
            merkleMetadata
        );
    }

    /**
     * @notice Refund the remaining tokens to the expiration recipient after the expiration timestamp
     * @param dropId The drop ID of the drop to refund
     */
    function refundToRecipient(uint256 dropId) external {
        if (dropId > numDrops || dropId == 0) revert InvalidDropId();
        DropData storage drop = drops[dropId];
        if (drop.expirationTimestamp > block.timestamp) revert DropStillLive();
        if (drop.totalTokens == drop.claimedTokens) revert AllTokensClaimed();

        address expirationRecipient = drop.expirationRecipient;
        uint256 tokensToRefund = drop.totalTokens - drop.claimedTokens;
        drop.claimedTokens = drop.totalTokens;
        address tokenAddress = drop.tokenAddress;

        IERC20(tokenAddress).safeTransfer(expirationRecipient, tokensToRefund);

        emit DropRefunded(dropId, expirationRecipient, tokenAddress, tokensToRefund);
    }

    /**
     * @notice Claim tokens from a drop for `msg.sender`
     * @param dropId The drop ID to claim
     * @param amount The amount of tokens to claim
     * @param merkleProof The merkle inclusion proof
     */
    function _claim(uint256 dropId, uint256 amount, bytes32[] calldata merkleProof) internal {
        if (dropId > numDrops || dropId == 0) revert InvalidDropId();
        DropData storage drop = drops[dropId];

        if (drop.expirationTimestamp <= block.timestamp || block.timestamp < drop.startTimestamp) revert DropNotLive();
        if (hasClaimed[dropId][msg.sender]) revert DropAlreadyClaimed();
        if (drop.claimedTokens + amount > drop.totalTokens) revert InsufficientTokensRemaining();

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount));
        if (!MerkleProof.verifyCalldata(merkleProof, drop.merkleRoot, leaf)) revert InvalidMerkleProof();

        hasClaimed[dropId][msg.sender] = true;
        drop.claimedTokens += amount;

        address tokenAddress = drop.tokenAddress;
        IERC20(tokenAddress).safeTransfer(msg.sender, amount);

        // Distribute fee
        uint256 fee = drop.claimFee;

        if (fee > 0) {
            if (address(this).balance < fee) revert InvalidMsgValue();

            uint256 ownerShare = fee * drop.ownerShareBps / 10_000;

            owner().call{ value: ownerShare, gas: 100_000 }("");
            drop.feeRecipient.call{ value: fee - ownerShare, gas: 100_000 }("");
        }

        emit DropClaimed(dropId, msg.sender, tokenAddress, amount);
    }

    function claim(uint256 dropId, uint256 amount, bytes32[] calldata merkleProof) external payable {
        _claim(dropId, amount, merkleProof);

        uint256 remainingBalance = address(this).balance;
        if (remainingBalance > 0) {
            msg.sender.call{ value: remainingBalance, gas: 100_000 }("");
        }
    }

    /**
     * @notice Claim multiple drops for `msg.sender`
     * @param dropIds The drop IDs to claim
     * @param amounts The amounts of tokens to claim
     * @param merkleProofs The merkle inclusion proofs
     */
    function batchClaim(
        uint256[] calldata dropIds,
        uint256[] calldata amounts,
        bytes32[][] calldata merkleProofs
    )
        external
        payable
    {
        if (dropIds.length != amounts.length || dropIds.length != merkleProofs.length) revert ArityMismatch();

        for (uint256 i = 0; i < dropIds.length; i++) {
            _claim(dropIds[i], amounts[i], merkleProofs[i]);
        }

        uint256 remainingBalance = address(this).balance;
        if (remainingBalance > 0) {
            msg.sender.call{ value: remainingBalance }("");
        }
    }

    /**
     * @dev Calls permit function on the token contract
     */
    function _callPermit(address tokenAddress, PermitArgs calldata permitArgs) internal {
        // We do not revert if the permit fails as the permit operation is callable by anyone
        try IERC20Permit(tokenAddress).permit(
            msg.sender, address(this), permitArgs.amount, permitArgs.deadline, permitArgs.v, permitArgs.r, permitArgs.s
        ) { } catch { }
    }

    /**
     * @dev Returns the version of the contract. Decimal versions indicate change in logic. Number change indicates
     * change in ABI.
     */
    function VERSION() external pure returns (string memory) {
        return "2.0.0";
    }

    /**
     * @notice Set the claim fee for future drops
     * @param newClaimFee The fee to claim a drop in ETH
     */
    function setClaimFee(uint256 newClaimFee) external onlyOwner {
        emit ClaimFeeSet(currentClaimFee, newClaimFee);
        currentClaimFee = newClaimFee;
    }

    /**
     * @notice Set the owner share in basis points for claim fee for future drops
     * @param newOwnerShareBps The owner share in basis points (1/10000)
     */
    function setOwnerShareBps(uint16 newOwnerShareBps) external onlyOwner {
        if (newOwnerShareBps > 10_000) revert InvalidBps();

        emit OwnerShareBpsSet(currentOwnerShareBps, newOwnerShareBps);
        currentOwnerShareBps = newOwnerShareBps;
    }
}
