// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract Dropper {
    event DropCreated(
        uint256 indexed dropId,
        bytes32 merkleRoot,
        uint256 totalTokens,
        address indexed tokenAddress,
        uint256 expirationTimestamp,
        address expirationRecipient,
        string merkleTreeURI
    );

    struct DropData {
        bytes32 merkleRoot;
        uint256 totalTokens;
        uint256 claimedTokens;
        address tokenAddress;
        uint256 expirationTimestamp;
        address expirationRecipient;
    }

    error MerkleRootNotSet();
    error TotalTokenIsZero();
    error TokenAddressIsZero();
    error ExpirationTimestampInPast();
    error DropStillLive();
    error AllTokensClaimed();
    error DropExpired();
    error DropAlreadyClaimed();
    error InsufficientTokensRemaining();
    error InvalidMerkleProof();
    error ArityMismatch();

    mapping(uint256 => DropData) private _drops;
    mapping(uint256 => mapping(address => bool)) private _claimed;
    uint256 public numDrops;

    function createDrop(
        bytes32 merkleRoot,
        uint256 totalTokens,
        address tokenAddress,
        uint256 expirationTimestamp,
        address expirationRecipient,
        string calldata merkleTreeURI
    )
        external
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
            expirationTimestamp: expirationTimestamp,
            expirationRecipient: expirationRecipient
        });

        emit DropCreated(
            dropId, merkleRoot, totalTokens, tokenAddress, expirationTimestamp, expirationRecipient, merkleTreeURI
        );
    }

    function refundToRecipient(uint256 dropId) external {
        DropData storage drop = _drops[dropId];
        if (drop.expirationTimestamp > block.timestamp) revert DropStillLive();
        if (drop.totalTokens == drop.claimedTokens) revert AllTokensClaimed();

        IERC20(_drops[dropId].tokenAddress).transfer(
            _drops[dropId].expirationRecipient, _drops[dropId].totalTokens - _drops[dropId].claimedTokens
        );

        _drops[dropId].claimedTokens = _drops[dropId].totalTokens;
    }

    function claim(uint256 dropId, uint256 amount, bytes32[] calldata merkleProof) public {
        DropData storage drop = _drops[dropId];

        if (drop.expirationTimestamp <= block.timestamp) revert DropExpired();
        if (_claimed[dropId][msg.sender]) revert DropAlreadyClaimed();
        if (drop.claimedTokens + amount > drop.totalTokens) revert InsufficientTokensRemaining();

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount));
        if (!MerkleProof.verifyCalldata(merkleProof, drop.merkleRoot, leaf)) revert InvalidMerkleProof();

        _claimed[dropId][msg.sender] = true;
        drop.claimedTokens += amount;

        IERC20(drop.tokenAddress).transfer(msg.sender, amount);
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
}
