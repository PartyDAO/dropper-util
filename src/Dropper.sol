// SPDX-License-Identifier: GPL-3.0
pragma solidity >=0.8.25;

import { IERC20 } from "openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { MerkleProof } from "openzeppelin-contracts/contracts/utils/cryptography/MerkleProof.sol";
import { SafeERC20 } from "openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";

/**
 * @title Dropper
 * @author PartyDAO
 * @notice Dropper contract for creating merkle tree based airdrops. Note: this contract is compatible only with ERC20
 * compliant tokens (no fee on transfer or rebasing tokens).
 */
contract Dropper {
    using SafeERC20 for IERC20;

    event DropCreated(
        uint256 indexed dropId,
        DropStaticData dropStaticData,
        uint256 claimFee,
        FeeRecipient[] feeRecipients,
        DropMetadata dropMetadata
    );

    event DropClaimed(uint256 indexed dropId, address indexed recipient, address indexed tokenAddress, uint256 amount);

    event DropRefunded(uint256 indexed dropId, address indexed recipient, address indexed tokenAddress, uint256 amount);

    event ClaimFeeSet(uint256 oldClaimFee, uint256 claimFee);

    struct DropStaticData {
        // Merkle root for the token drop
        bytes32 merkleRoot;
        // Total number of tokens to be dropped
        uint256 totalTokens;
        // Address of the token to be dropped
        address tokenAddress;
        // Timestamp at which the drop will become live
        uint40 startTimestamp;
        // Timestamp at which the drop will expire
        uint40 expirationTimestamp;
        // Address to which the remaining tokens will be refunded after expiration
        address expirationRecipient;
    }

    struct FeeRecipient {
        address recipient;
        uint16 percentageBps;
    }

    struct DropFeeData {
        // The fee to claim a drop in ETH
        uint256 claimFee;
        // Fees from drop claims will be sent here. Percentage bps must add to 10_000
        FeeRecipient[] feeRecipients;
    }

    struct PermitArgs {
        uint256 amount;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    struct DropMetadata {
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
    error InvalidFeeRecipient();

    mapping(uint256 => DropStaticData) private dropStaticDatas;
    mapping(uint256 => DropFeeData) private dropFeeDatas;
    mapping(uint256 => uint256) private claimedTokens;
    mapping(uint256 => mapping(address => bool)) public hasClaimed;

    /// @notice The number of drops created on this contract
    uint256 public numDrops;

    /**
     * @notice Permits the token and creates a new drop with the given parameters
     * @param permitArgs The permit arguments to be passed to the token's permit function
     * @param dropStaticData The static data for a drop (excluding fee data and metadata)
     * @param claimFee The claim fee for the drop
     * @param feeRecipients The fee recipients and their respective percentages
     * @param dropMetadata The metadata for the drop
     * @return dropId The ID of the newly created drop
     */
    function permitAndCreateDrop(
        PermitArgs calldata permitArgs,
        DropStaticData calldata dropStaticData,
        uint256 claimFee,
        FeeRecipient[] calldata feeRecipients,
        DropMetadata calldata dropMetadata
    )
        external
        returns (uint256)
    {
        // Revert if insufficient approval will be given by permit
        if (permitArgs.amount < dropStaticData.totalTokens) revert InsufficientPermitAmount();

        _callPermit(dropStaticData.tokenAddress, permitArgs);

        return createDrop(dropStaticData, claimFee, feeRecipients, dropMetadata);
    }

    /**
     * @notice Create a new drop with the given parameters
     * @param dropStaticData The static data for a drop (excluding fee data and metadata)
     * @param claimFee The claim fee for the drop
     * @param feeRecipients The fee recipients and their respective percentages
     * @param dropMetadata The metadata for the drop
     * @return dropId The ID of the newly created drop
     */
    function createDrop(
        DropStaticData calldata dropStaticData,
        uint256 claimFee,
        FeeRecipient[] calldata feeRecipients,
        DropMetadata calldata dropMetadata
    )
        public
        returns (uint256 dropId)
    {
        if (dropStaticData.merkleRoot == bytes32(0)) revert MerkleRootNotSet();
        if (dropStaticData.totalTokens == 0) revert TotalTokenIsZero();
        if (dropStaticData.tokenAddress == address(0)) revert TokenAddressIsZero();
        if (dropStaticData.expirationTimestamp <= block.timestamp) revert ExpirationTimestampInPast();
        if (dropStaticData.expirationTimestamp <= dropStaticData.startTimestamp) revert EndBeforeStart();
        if (dropStaticData.expirationRecipient == address(0)) revert ExpirationRecipientIsZero();

        IERC20(dropStaticData.tokenAddress).safeTransferFrom(msg.sender, address(this), dropStaticData.totalTokens);

        dropId = ++numDrops;

        dropStaticDatas[dropId] = dropStaticData;
        dropFeeDatas[dropId].claimFee = claimFee;

        if (claimFee != 0) {
            // Validate fee recipients and send to storage
            uint16 sumBps;
            for (uint256 i = 0; i < feeRecipients.length; i++) {
                if (feeRecipients[i].recipient == address(0)) revert InvalidFeeRecipient();
                if (feeRecipients[i].percentageBps == 0) revert InvalidFeeRecipient();
                dropFeeDatas[dropId].feeRecipients.push(feeRecipients[i]);
                sumBps += feeRecipients[i].percentageBps;
            }
            if (sumBps != 10_000) revert InvalidBps();
        }

        emit DropCreated(dropId, dropStaticData, claimFee, feeRecipients, dropMetadata);
    }

    /**
     * @notice Get the drop data for a given drop ID
     */
    function getDrop(uint256 dropId)
        external
        view
        returns (DropStaticData memory dropStaticData, DropFeeData memory dropFeeData, uint256 dropTokensClaimed)
    {
        if (dropId > numDrops || dropId == 0) revert InvalidDropId();

        dropStaticData = dropStaticDatas[dropId];
        dropFeeData = dropFeeDatas[dropId];
        dropTokensClaimed = claimedTokens[dropId];
    }

    /**
     * @notice Refund the remaining tokens to the expiration recipient after the expiration timestamp
     * @param dropId The drop ID of the drop to refund
     */
    function refundToRecipient(uint256 dropId) external {
        if (dropId > numDrops || dropId == 0) revert InvalidDropId();
        DropStaticData storage drop = dropStaticDatas[dropId];
        uint256 dropClaimedTokens = claimedTokens[dropId];
        if (drop.expirationTimestamp > block.timestamp) revert DropStillLive();
        if (drop.totalTokens == dropClaimedTokens) revert AllTokensClaimed();

        address expirationRecipient = drop.expirationRecipient;
        uint256 tokensToRefund = drop.totalTokens - dropClaimedTokens;
        claimedTokens[dropId] = drop.totalTokens;
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
        DropStaticData memory drop = dropStaticDatas[dropId];
        DropFeeData memory dropFeeData = dropFeeDatas[dropId];

        if (drop.expirationTimestamp <= block.timestamp || block.timestamp < drop.startTimestamp) revert DropNotLive();
        if (hasClaimed[dropId][msg.sender]) revert DropAlreadyClaimed();
        uint256 dropClaimedTokens = claimedTokens[dropId];
        if (dropClaimedTokens + amount > drop.totalTokens) revert InsufficientTokensRemaining();

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount));
        if (!MerkleProof.verifyCalldata(merkleProof, drop.merkleRoot, leaf)) revert InvalidMerkleProof();

        hasClaimed[dropId][msg.sender] = true;
        claimedTokens[dropId] = dropClaimedTokens + amount;

        address tokenAddress = drop.tokenAddress;
        IERC20(tokenAddress).safeTransfer(msg.sender, amount);

        // Distribute fee
        uint256 fee = dropFeeData.claimFee;

        if (fee > 0) {
            if (address(this).balance < fee) revert InvalidMsgValue();

            for (uint256 i = 0; i < dropFeeData.feeRecipients.length; i++) {
                dropFeeData.feeRecipients[i].recipient.call{
                    value: dropFeeData.feeRecipients[i].percentageBps * fee / 10_000,
                    gas: 100_000
                }("");
            }
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
            msg.sender.call{ value: remainingBalance, gas: 100_000 }("");
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
}
