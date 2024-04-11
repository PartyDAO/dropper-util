// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Permit.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract Dropper {
    event DropCreated(
        uint256 indexed dropId,
        bytes32 merkleRoot,
        uint256 totalTokens,
        address indexed tokenAddress,
        uint40 startTimestamp,
        uint40 expirationTimestamp,
        address expirationRecipient,
        string merkleTreeURI
    );

    event DropClaimed(uint256 indexed dropId, address indexed recipient, address indexed tokenAddress, uint256 amount);

    event DropRefunded(uint256 indexed dropId, address indexed recipient, address indexed tokenAddress, uint256 amount);

    struct DropData {
        bytes32 merkleRoot;
        uint256 totalTokens;
        uint256 claimedTokens;
        address tokenAddress;
        uint40 startTimestamp;
        uint40 expirationTimestamp;
        address expirationRecipient;
    }

    struct PermitArgs {
        uint256 amount;
        uint256 deadline;
        uint8 v;
        bytes32 r;
        bytes32 s;
    }

    error InsufficientPermitAmount();
    error MerkleRootNotSet();
    error TotalTokenIsZero();
    error TokenAddressIsZero();
    error ExpirationTimestampInPast();
    error DropStillLive();
    error AllTokensClaimed();
    error DropNotLive();
    error DropAlreadyClaimed();
    error InsufficientTokensRemaining();
    error InvalidMerkleProof();
    error ArityMismatch();

    mapping(uint256 => DropData) private _drops;
    mapping(uint256 => mapping(address => bool)) private _claimed;
    uint256 public numDrops;

    function permitAndCreateDrop(
        PermitArgs calldata permitArgs,
        bytes32 merkleRoot,
        uint256 totalTokens,
        address tokenAddress,
        uint40 startTimestamp,
        uint40 expirationTimestamp,
        address expirationRecipient,
        string calldata merkleTreeURI
    )
        external
    {
        // Revert if insufficient approval will be given by permit
        if (permitArgs.amount < totalTokens) revert InsufficientPermitAmount();

        _callPermit(tokenAddress, permitArgs);

        createDrop(
            merkleRoot,
            totalTokens,
            tokenAddress,
            startTimestamp,
            expirationTimestamp,
            expirationRecipient,
            merkleTreeURI
        );
    }

    function createDrop(
        bytes32 merkleRoot,
        uint256 totalTokens,
        address tokenAddress,
        uint40 startTimestamp,
        uint40 expirationTimestamp,
        address expirationRecipient,
        string calldata merkleTreeURI
    )
        public
        returns (uint256 dropId)
    {
        if (merkleRoot == bytes32(0)) revert MerkleRootNotSet();
        if (totalTokens == 0) revert TotalTokenIsZero();
        if (tokenAddress == address(0)) revert TokenAddressIsZero();
        if (expirationTimestamp <= block.timestamp) revert ExpirationTimestampInPast();

        IERC20(tokenAddress).transferFrom(msg.sender, address(this), totalTokens);

        dropId = ++numDrops;

        _drops[dropId] = DropData({
            merkleRoot: merkleRoot,
            totalTokens: totalTokens,
            claimedTokens: 0,
            tokenAddress: tokenAddress,
            startTimestamp: startTimestamp,
            expirationTimestamp: expirationTimestamp,
            expirationRecipient: expirationRecipient
        });

        emit DropCreated(
            dropId,
            merkleRoot,
            totalTokens,
            tokenAddress,
            startTimestamp,
            expirationTimestamp,
            expirationRecipient,
            merkleTreeURI
        );
    }

    function refundToRecipient(uint256 dropId) external {
        DropData storage drop = _drops[dropId];
        if (drop.expirationTimestamp > block.timestamp) revert DropStillLive();
        if (drop.totalTokens == drop.claimedTokens) revert AllTokensClaimed();

        address expirationRecipient = drop.expirationRecipient;
        uint256 tokensToRefund = drop.totalTokens - drop.claimedTokens;
        address tokenAddress = drop.tokenAddress;

        IERC20(tokenAddress).transfer(expirationRecipient, tokensToRefund);

        drop.claimedTokens = drop.totalTokens;

        emit DropRefunded(dropId, expirationRecipient, tokenAddress, tokensToRefund);
    }

    function claim(uint256 dropId, uint256 amount, bytes32[] calldata merkleProof) public {
        DropData storage drop = _drops[dropId];

        if (drop.expirationTimestamp <= block.timestamp || block.timestamp < drop.startTimestamp) revert DropNotLive();
        if (_claimed[dropId][msg.sender]) revert DropAlreadyClaimed();
        if (drop.claimedTokens + amount > drop.totalTokens) revert InsufficientTokensRemaining();

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount));
        if (!MerkleProof.verifyCalldata(merkleProof, drop.merkleRoot, leaf)) revert InvalidMerkleProof();

        _claimed[dropId][msg.sender] = true;
        drop.claimedTokens += amount;

        address tokenAddress = drop.tokenAddress;
        IERC20(tokenAddress).transfer(msg.sender, amount);

        emit DropClaimed(dropId, msg.sender, tokenAddress, amount);
    }

    function batchClaim(
        uint256[] calldata dropIds,
        uint256[] calldata amounts,
        bytes32[][] calldata merkleProofs
    )
        external
    {
        if (dropIds.length != amounts.length || dropIds.length != merkleProofs.length) revert ArityMismatch();

        for (uint256 i = 0; i < dropIds.length; i++) {
            claim(dropIds[i], amounts[i], merkleProofs[i]);
        }
    }

    function _callPermit(address tokenAddress, PermitArgs calldata permitArgs) internal {
        IERC20Permit(tokenAddress).permit(
            msg.sender, address(this), permitArgs.amount, permitArgs.deadline, permitArgs.v, permitArgs.r, permitArgs.s
        );
    }
}
