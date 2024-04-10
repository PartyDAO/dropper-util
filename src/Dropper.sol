// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

contract Dropper {
    struct DropData {
        bytes32 merkleRoot;
        uint256 totalToken;
        uint256 claimedTokens;
        address tokenAddress;
        uint256 expirationTimestamp;
        address expirationRecipient;
    }

    mapping(uint256 => DropData) private _drops;
    mapping(uint256 => mapping(address => bool)) private _claimed;
    uint256 public numDrops;

    function createDrop(
        bytes32 merkleRoot,
        uint256 totalToken,
        address tokenAddress,
        uint256 expirationTimestamp,
        address expirationRecipient
    )
        external
        returns (uint256 dropId)
    {
        require(merkleRoot != bytes32(0), "Dropper: merkleRoot not set");
        require(totalToken > 0, "Dropper: totalToken is 0");
        require(tokenAddress != address(0), "Dropper: tokenAddress is 0");
        require(expirationTimestamp > block.timestamp, "Dropper: expirationTimestamp is in the past");

        IERC20(tokenAddress).transferFrom(msg.sender, address(this), totalToken);

        dropId = ++numDrops;

        _drops[dropId] = DropData({
            merkleRoot: merkleRoot,
            totalToken: totalToken,
            claimedTokens: 0,
            tokenAddress: tokenAddress,
            expirationTimestamp: expirationTimestamp,
            expirationRecipient: expirationRecipient
        });
    }

    function refundToRecipient(uint256 dropId) external {
        require(_drops[dropId].expirationTimestamp <= block.timestamp, "Dropper: still live");

        IERC20(_drops[dropId].tokenAddress).transfer(
            _drops[dropId].expirationRecipient, _drops[dropId].totalToken - _drops[dropId].claimedTokens
        );
    }

    function claim(uint256 dropId, uint256 amount, bytes32[] calldata merkleProof) public {
        DropData storage drop = _drops[dropId];

        require(drop.expirationTimestamp > block.timestamp, "Dropper: expired");
        require(!_claimed[dropId][msg.sender], "Dropper: already claimed");
        require(drop.claimedTokens + amount <= drop.totalToken, "Dropper: not enough tokens");

        bytes32 leaf = keccak256(abi.encodePacked(msg.sender, amount));
        require(MerkleProof.verifyCalldata(merkleProof, drop.merkleRoot, leaf), "Dropper: invalid proof");

        _claimed[dropId][msg.sender] = true;
        drop.claimedTokens += amount;

        IERC20(drop.tokenAddress).transfer(msg.sender, amount);
    }

    function batchClaim(uint256[] calldata dropIds, uint256[] calldata amounts, bytes32[][] calldata merkleProofs) external {
        require(dropIds.length == amounts.length && dropIds.length == merkleProofs.length, "Dropper: arity mismatch");

        for (uint256 i = 0; i < dropIds.length; i++) {
            claim(dropIds[i], amounts[i], merkleProofs[i]);
        }
    }
}
