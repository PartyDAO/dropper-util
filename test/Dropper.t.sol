// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import { PRBTest } from "@prb/test/src/PRBTest.sol";
import { console2 } from "forge-std/src/console2.sol";
import { StdCheats } from "forge-std/src/StdCheats.sol";
import { Dropper } from "../src/Dropper.sol";
import { MockERC20 } from "forge-std//src/mocks/MockERC20.sol";

contract DropperTest is PRBTest, StdCheats {
    event DropCreated(
        uint256 indexed dropId,
        bytes32 merkleRoot,
        uint256 totalTokens,
        address indexed tokenAddress,
        uint256 expirationTimestamp,
        address expirationRecipient,
        string merkleTreeURI
    );

    event DropClaimed(
        uint256 indexed dropId,
        address indexed recipient,
        address indexed tokenAddress,
        uint256 amount
    );

    event DropRefunded(
        uint256 indexed dropId,
        address indexed recipient,
        address indexed tokenAddress,
        uint256 amount
    );

    Dropper dropper;
    MockERC20 token;
    bytes32[] merkleProof;
    bytes32 merkleRoot;
    uint256 dropId;

    address[4] members;
    uint256[4] amounts;

    function setUp() public {
        dropper = new Dropper();
        token = new MockERC20();
        token.initialize("Mock Token", "MTK", 18);

        members = [
            vm.addr(1),
            vm.addr(2),
            vm.addr(3),
            vm.addr(4)
        ];
        amounts = [100e18, 200e18, 300e18, 400e18];
        merkleRoot = _constructTree(members, amounts);
    }

    // Constructs a merkle root from the given 4-member allow list.
    function _constructTree(address[4] memory _members, uint256[4] memory _amounts) private pure returns (bytes32) {
        return _hashNode(
            _hashNode(_hashLeaf(_members[0], _amounts[0]), _hashLeaf(_members[1], _amounts[1])),
            _hashNode(_hashLeaf(_members[2], _amounts[2]), _hashLeaf(_members[3], _amounts[3]))
        );
    }

    function _hashNode(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, b));
    }

    function _hashLeaf(address a, uint256 amount) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, amount));
    }

    function testCreateDrop() public {
        deal(address(token), address(this), 1000e18);
        token.approve(address(dropper), 1000e18);

        vm.expectEmit(true, true, true, true);
        emit DropCreated(
            1, merkleRoot, 1000e18, address(token), block.timestamp + 3600, address(this), "someURI"
        );

        dropId = dropper.createDrop(
            merkleRoot, 1000e18, address(token), block.timestamp + 3600, address(this), "someURI"
        );

        assertEq(dropId, 1);
        assertEq(token.balanceOf(address(dropper)), 1000e18);
    }

    function testCreateDropMerkleRootNotSet() public {
        deal(address(token), address(this), 1000e18);
        token.approve(address(dropper), 1000e18);

        vm.expectRevert(abi.encodeWithSelector(Dropper.MerkleRootNotSet.selector));
        dropper.createDrop(bytes32(0), 1000e18, address(token), block.timestamp + 3600, address(this), "someURI");
    }

    function testCreateDropTotalTokenIsZero() public {
        deal(address(token), address(this), 1000e18);
        token.approve(address(dropper), 1000e18);

        vm.expectRevert(abi.encodeWithSelector(Dropper.TotalTokenIsZero.selector));
        dropper.createDrop(merkleRoot, 0, address(token), block.timestamp + 3600, address(this), "someURI");
    }

    function testCreateDropTokenAddressIsZero() public {
        deal(address(token), address(this), 1000e18);
        token.approve(address(dropper), 1000e18);

        vm.expectRevert(abi.encodeWithSelector(Dropper.TokenAddressIsZero.selector));
        dropper.createDrop(merkleRoot, 1000e18, address(0), block.timestamp + 3600, address(this), "someURI");
    }

    function testCreateDropExpirationTimestampInPast() public {
        deal(address(token), address(this), 1000e18);
        token.approve(address(dropper), 1000e18);

        vm.expectRevert(abi.encodeWithSelector(Dropper.ExpirationTimestampInPast.selector));
        dropper.createDrop(merkleRoot, 1000e18, address(token), block.timestamp - 1, address(this), "someURI");
    }

    function testClaim() public {
        testCreateDrop();

        address member = members[0];
        uint256 amount = amounts[0];
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = _hashLeaf(members[1], amounts[1]);
        proof[1] = _hashNode(_hashLeaf(members[2], amounts[2]), _hashLeaf(members[3], amounts[3]));

        // vm.expectEmit(true, true, true, true);
        // emit DropClaimed(dropId, member, address(token), amount);

        vm.prank(member);
        dropper.claim(dropId, amount, proof);

        assertEq(token.balanceOf(member), amount);
        assertEq(token.balanceOf(address(dropper)), 1000e18 - amount);
    }

    function testClaimDropExpired() public {
        testCreateDrop();

        uint256 amount = amounts[0];
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = _hashLeaf(members[1], amounts[1]);
        proof[1] = _hashNode(_hashLeaf(members[2], amounts[2]), _hashLeaf(members[3], amounts[3]));

        vm.warp(block.timestamp + 3601);

        vm.expectRevert(abi.encodeWithSelector(Dropper.DropExpired.selector));
        dropper.claim(dropId, amount, proof);
    }

    function testClaimDropAlreadyClaimed() public {
        testCreateDrop();

        address member = members[0];
        uint256 amount = amounts[0];
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = _hashLeaf(members[1], amounts[1]);
        proof[1] = _hashNode(_hashLeaf(members[2], amounts[2]), _hashLeaf(members[3], amounts[3]));

        vm.startPrank(member);
        dropper.claim(dropId, amount, proof);

        vm.expectRevert(abi.encodeWithSelector(Dropper.DropAlreadyClaimed.selector));
        dropper.claim(dropId, amount, proof);
        vm.stopPrank();
    }

    function testClaimInsufficientTokensRemaining() public {
        testCreateDrop();

        uint256 amount = 1000e18 + 1;
        bytes32[] memory proof = new bytes32[](2);
        proof[0] = _hashLeaf(members[1], amounts[1]);
        proof[1] = _hashNode(_hashLeaf(members[2], amounts[2]), _hashLeaf(members[3], amounts[3]));

        vm.expectRevert(abi.encodeWithSelector(Dropper.InsufficientTokensRemaining.selector));
        dropper.claim(dropId, amount, proof);
    }

    function testClaimInvalidMerkleProof() public {
        testCreateDrop();

        uint256 amount = amounts[0];
        bytes32[] memory invalidProof = new bytes32[](1);
        invalidProof[0] = bytes32(uint256(1));

        vm.expectRevert(abi.encodeWithSelector(Dropper.InvalidMerkleProof.selector));
        dropper.claim(dropId, amount, invalidProof);
    }

    function testBatchClaim() public {
        testCreateDrop();

        address member = members[0];
        uint256 amount1 = amounts[0];
        uint256 amount2 = amounts[1];
        bytes32[] memory proof1 = new bytes32[](2);
        proof1[0] = _hashLeaf(members[1], amounts[1]);
        proof1[1] = _hashNode(_hashLeaf(members[2], amounts[2]), _hashLeaf(members[3], amounts[3]));
        bytes32[] memory proof2 = new bytes32[](2);
        proof2[0] = _hashLeaf(members[0], amounts[0]);
        proof2[1] = _hashNode(_hashLeaf(members[2], amounts[2]), _hashLeaf(members[3], amounts[3]));

        uint256[] memory dropIds = new uint256[](2);
        uint256[] memory claimAmounts = new uint256[](2);
        bytes32[][] memory proofs = new bytes32[][](2);

        dropIds[0] = dropId;
        dropIds[1] = dropId;
        claimAmounts[0] = amount1;
        claimAmounts[1] = amount2;
        proofs[0] = proof1;
        proofs[1] = proof2;

        vm.expectEmit(true, true, true, true);
        emit DropClaimed(dropId, member, address(token), amount1);
        vm.expectEmit(true, true, true, true);
        emit DropClaimed(dropId, member, address(token), amount2);

        vm.prank(member);
        dropper.batchClaim(dropIds, claimAmounts, proofs);

        assertEq(token.balanceOf(member), amount1 + amount2);
        assertEq(token.balanceOf(address(dropper)), 1000e18 - (amount1 + amount2));
    }

    function testBatchClaimArityMismatch() public {
        testCreateDrop();

        uint256[] memory dropIds = new uint256[](1);
        uint256[] memory invalidAmounts = new uint256[](2);
        bytes32[][] memory proofs = new bytes32[][](2);

        vm.expectRevert(abi.encodeWithSelector(Dropper.ArityMismatch.selector));
        dropper.batchClaim(dropIds, invalidAmounts, proofs);
    }

    function testRefundToRecipient() public {
        testCreateDrop();

        vm.warp(block.timestamp + 3601);

        uint256 tokensToRefund = 1000e18;

        vm.expectEmit(true, true, true, true);
        emit DropRefunded(dropId, address(this), address(token), tokensToRefund);

        dropper.refundToRecipient(dropId);

        assertEq(token.balanceOf(address(dropper)), 0);
        assertEq(token.balanceOf(address(this)), 1000e18);
    }

    function testRefundToRecipientDropStillLive() public {
        testCreateDrop();

        vm.expectRevert(abi.encodeWithSelector(Dropper.DropStillLive.selector));
        dropper.refundToRecipient(dropId);
    }

    function testRefundToRecipientAllTokensClaimed() public {
        testCreateDrop();

        bytes32[][] memory proofs = new bytes32[][](4);
        for (uint256 i = 0; i < 4; i++) {
            proofs[i] = new bytes32[](2);
            proofs[i][0] = _hashLeaf(members[(i + 1) % 4], amounts[(i + 1) % 4]);
            proofs[i][1] = _hashNode(
                _hashLeaf(members[(i + 2) % 4], amounts[(i + 2) % 4]),
                _hashLeaf(members[(i + 3) % 4], amounts[(i + 3) % 4])
            );

            vm.prank(members[i]);
            dropper.claim(dropId, amounts[i], proofs[i]);
        }

        vm.warp(block.timestamp + 3601);

        vm.expectRevert(abi.encodeWithSelector(Dropper.AllTokensClaimed.selector));
        dropper.refundToRecipient(dropId);
    }
}