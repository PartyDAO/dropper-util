// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import { PRBTest, Vm } from "@prb/test/src/PRBTest.sol";
import { StdCheats } from "forge-std/src/StdCheats.sol";
import { Dropper } from "../src/Dropper.sol";
import { MockERC20 } from "forge-std/src/mocks/MockERC20.sol";
import { Merkle } from "murky/src/Merkle.sol";

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

    event DropClaimed(uint256 indexed dropId, address indexed recipient, address indexed tokenAddress, uint256 amount);

    event DropRefunded(uint256 indexed dropId, address indexed recipient, address indexed tokenAddress, uint256 amount);

    Dropper public dropper;
    MockERC20 public token;
    Merkle public merkle;

    function setUp() public {
        dropper = new Dropper();
        token = new MockERC20();
        token.initialize("Mock Token", "MTK", 18);
        merkle = new Merkle();
    }

    function _hashLeaf(address a, uint256 amount) private pure returns (bytes32) {
        return keccak256(abi.encodePacked(a, amount));
    }

    function testCreateDrop(
        address[4] memory recipients,
        uint40[4] memory amounts
    )
        public
        returns (uint256 dropId, bytes32[] memory merkleLeaves)
    {
        for (uint256 i = 0; i < recipients.length; i++) {
            for (uint256 j = i; j < recipients.length; j++) {
                if (i != j) {
                    vm.assume(recipients[i] != recipients[j]);
                }
                vm.assume(recipients[i] != address(dropper));
            }
        }

        merkleLeaves = new bytes32[](4);

        uint256 totalDropAmount;
        for (uint256 i = 0; i < 4; i++) {
            vm.assume(recipients[i] != address(0));
            vm.assume(amounts[i] > 0);
            merkleLeaves[i] = _hashLeaf(recipients[i], amounts[i]);
            totalDropAmount += amounts[i];
        }

        bytes32 merkleRoot = merkle.getRoot(merkleLeaves);

        deal(address(token), address(this), totalDropAmount);
        token.approve(address(dropper), totalDropAmount);

        uint256 expectedDropId = dropper.numDrops() + 1;
        vm.expectEmit(true, true, true, true);
        emit DropCreated(
            expectedDropId,
            merkleRoot,
            totalDropAmount,
            address(token),
            block.timestamp + 3600,
            address(this),
            "someURI"
        );

        uint256 balanceBefore = token.balanceOf(address(dropper));
        dropId = dropper.createDrop(
            merkleRoot, totalDropAmount, address(token), block.timestamp + 3600, address(this), "someURI"
        );

        assertEq(dropId, expectedDropId);
        assertEq(token.balanceOf(address(dropper)), balanceBefore + totalDropAmount);
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
        dropper.createDrop(bytes32(uint256(1)), 0, address(token), block.timestamp + 3600, address(this), "someURI");
    }

    function testCreateDropTokenAddressIsZero() public {
        deal(address(token), address(this), 1000e18);
        token.approve(address(dropper), 1000e18);

        vm.expectRevert(abi.encodeWithSelector(Dropper.TokenAddressIsZero.selector));
        dropper.createDrop(bytes32(uint256(1)), 1000e18, address(0), block.timestamp + 3600, address(this), "someURI");
    }

    function testCreateDropExpirationTimestampInPast() public {
        deal(address(token), address(this), 1000e18);
        token.approve(address(dropper), 1000e18);

        vm.expectRevert(abi.encodeWithSelector(Dropper.ExpirationTimestampInPast.selector));
        dropper.createDrop(bytes32(uint256(1)), 1000e18, address(token), block.timestamp - 1, address(this), "someURI");
    }

    function testClaim(address[4] memory recipients, uint40[4] memory amounts) public {
        (uint256 dropId, bytes32[] memory merkleLeaves) = testCreateDrop(recipients, amounts);

        for (uint256 i = 0; i < 4; i++) {
            address member = recipients[i];
            uint256 amount = amounts[i];

            bytes32[] memory proof = merkle.getProof(merkleLeaves, i);

            vm.expectEmit(true, true, true, true);
            emit DropClaimed(dropId, member, address(token), amount);

            vm.prank(member);
            dropper.claim(dropId, amount, proof);

            assertEq(token.balanceOf(member), amount);
        }

        // All have claimed
        assertEq(token.balanceOf(address(dropper)), 0);
    }

    function testClaimDropExpired(address[4] memory recipients, uint40[4] memory amounts) public {
        (uint256 dropId, bytes32[] memory merkleLeaves) = testCreateDrop(recipients, amounts);

        uint256 amount = amounts[0];

        vm.warp(block.timestamp + 3601);

        bytes32[] memory proof = merkle.getProof(merkleLeaves, 0);

        vm.expectRevert(abi.encodeWithSelector(Dropper.DropExpired.selector));
        vm.prank(recipients[0]);
        dropper.claim(dropId, amount, proof);
    }

    function testClaimDropAlreadyClaimed(address[4] memory recipients, uint40[4] memory amounts) public {
        (uint256 dropId, bytes32[] memory merkleLeaves) = testCreateDrop(recipients, amounts);

        address member = recipients[0];
        uint256 amount = amounts[0];
        bytes32[] memory proof = merkle.getProof(merkleLeaves, 0);

        vm.startPrank(member);
        dropper.claim(dropId, amount, proof);

        vm.expectRevert(abi.encodeWithSelector(Dropper.DropAlreadyClaimed.selector));
        dropper.claim(dropId, amount, proof);
        vm.stopPrank();
    }

    function testClaimInsufficientTokensRemaining(address[4] memory recipients, uint40[4] memory amounts) public {
        for (uint256 i = 0; i < recipients.length; i++) {
            for (uint256 j = i; j < recipients.length; j++) {
                if (i != j) {
                    vm.assume(recipients[i] != recipients[j]);
                }
                vm.assume(recipients[i] != address(dropper));
            }
        }

        bytes32[] memory merkleLeaves = new bytes32[](4);

        uint256 totalDropAmount = 1;
        for (uint256 i = 0; i < 4; i++) {
            vm.assume(recipients[i] != address(0));
            vm.assume(amounts[i] > 1);
            merkleLeaves[i] = _hashLeaf(recipients[i], amounts[i]);
        }

        bytes32 merkleRoot = merkle.getRoot(merkleLeaves);

        deal(address(token), address(this), totalDropAmount);
        token.approve(address(dropper), totalDropAmount);

        uint256 expectedDropId = dropper.numDrops() + 1;
        vm.expectEmit(true, true, true, true);
        emit DropCreated(
            expectedDropId,
            merkleRoot,
            totalDropAmount,
            address(token),
            block.timestamp + 3600,
            address(this),
            "someURI"
        );

        uint256 balanceBefore = token.balanceOf(address(dropper));
        uint256 dropId = dropper.createDrop(
            merkleRoot, totalDropAmount, address(token), block.timestamp + 3600, address(this), "someURI"
        );

        assertEq(dropId, expectedDropId);
        assertEq(token.balanceOf(address(dropper)), balanceBefore + totalDropAmount);

        bytes32[] memory proof = merkle.getProof(merkleLeaves, 0);
        vm.expectRevert(abi.encodeWithSelector(Dropper.InsufficientTokensRemaining.selector));
        vm.prank(recipients[0]);
        dropper.claim(dropId, amounts[0], proof);
    }

    function testClaimInvalidMerkleProof(address[4] memory recipients, uint40[4] memory amounts) public {
        (uint256 dropId, bytes32[] memory merkleLeaves) = testCreateDrop(recipients, amounts);

        uint256 amount = amounts[0];
        bytes32[] memory invalidProof = merkle.getProof(merkleLeaves, 0);
        invalidProof[0] = invalidProof[1];

        vm.expectRevert(abi.encodeWithSelector(Dropper.InvalidMerkleProof.selector));
        vm.prank(recipients[0]);
        dropper.claim(dropId, amount, invalidProof);
    }

    function testBatchClaim(address[4] memory recipients, uint40[4] memory amounts) public {
        (uint256 dropId1, bytes32[] memory merkleLeaves) = testCreateDrop(recipients, amounts);
        (uint256 dropId2,) = testCreateDrop(recipients, amounts);

        address member = recipients[0];

        uint256[] memory dropIds = new uint256[](2);
        dropIds[0] = dropId1;
        dropIds[1] = dropId2;
        uint256[] memory claimAmounts = new uint256[](2);
        claimAmounts[0] = claimAmounts[1] = amounts[0];
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = proofs[1] = merkle.getProof(merkleLeaves, 0);

        vm.expectEmit(true, true, true, true);
        emit DropClaimed(dropId1, member, address(token), amounts[0]);
        vm.expectEmit(true, true, true, true);
        emit DropClaimed(dropId2, member, address(token), amounts[0]);

        vm.prank(member);
        dropper.batchClaim(dropIds, claimAmounts, proofs);

        assertEq(token.balanceOf(member), uint256(amounts[0]) * 2);
    }

    function testBatchClaimArityMismatch() public {
        uint256[] memory dropIds = new uint256[](1);
        uint256[] memory invalidAmounts = new uint256[](2);
        bytes32[][] memory proofs = new bytes32[][](2);

        vm.expectRevert(abi.encodeWithSelector(Dropper.ArityMismatch.selector));
        dropper.batchClaim(dropIds, invalidAmounts, proofs);
    }

    function testRefundToRecipient() public {
        (uint256 dropId,) =
            testCreateDrop([address(1), address(2), address(3), address(4)], [uint40(100), 1000, 1000, 1000]);

        vm.warp(block.timestamp + 3601);

        uint256 tokensToRefund = 3100;

        vm.expectEmit(true, true, true, true);
        emit DropRefunded(dropId, address(this), address(token), tokensToRefund);

        dropper.refundToRecipient(dropId);

        assertEq(token.balanceOf(address(dropper)), 0);
        assertEq(token.balanceOf(address(this)), tokensToRefund);
    }

    function testRefundToRecipientDropStillLive() public {
        (uint256 dropId,) =
            testCreateDrop([address(1), address(2), address(3), address(4)], [uint40(100), 1000, 1000, 1000]);

        vm.expectRevert(abi.encodeWithSelector(Dropper.DropStillLive.selector));
        dropper.refundToRecipient(dropId);
    }

    function testRefundToRecipientAllTokensClaimed() public {
        testClaim([address(1), address(2), address(3), address(4)], [uint40(100), 1000, 1000, 1000]);

        vm.warp(block.timestamp + 3601);

        vm.expectRevert(abi.encodeWithSelector(Dropper.AllTokensClaimed.selector));
        dropper.refundToRecipient(1);
    }

    function test_permitAndCreateDrop_works(uint256 creatorPk) external {
        vm.assume(creatorPk != 0);
        vm.assume(
            creatorPk
                < 95_792_089_237_316_195_423_570_985_008_687_907_852_837_564_279_074_904_382_605_163_141_518_161_494_337
        );
        Vm.Wallet memory creator = vm.createWallet(creatorPk, "Creator");

        address[4] memory recipients = [address(1), address(2), address(3), address(4)];
        uint40[4] memory amounts = [uint40(100), 1000, 1000, 1000];

        bytes32[] memory merkleLeaves = new bytes32[](4);

        uint256 totalDropAmount;
        for (uint256 i = 0; i < 4; i++) {
            merkleLeaves[i] = _hashLeaf(recipients[i], amounts[i]);
            totalDropAmount += amounts[i];
        }

        bytes32 merkleRoot = merkle.getRoot(merkleLeaves);

        deal(address(token), creator.addr, totalDropAmount);
        (uint8 v, bytes32 r, bytes32 s) =
            _signPermit(creator, address(token), address(dropper), totalDropAmount, block.timestamp + 1);

        uint256 expectedDropId = dropper.numDrops() + 1;
        vm.expectEmit(true, true, true, true);
        emit DropCreated(
            expectedDropId,
            merkleRoot,
            totalDropAmount,
            address(token),
            block.timestamp + 3600,
            address(this),
            "someURI"
        );

        vm.prank(creator.addr);
        dropper.permitAndCreateDrop(
            totalDropAmount,
            block.timestamp + 1,
            v,
            r,
            s,
            merkleRoot,
            totalDropAmount,
            address(token),
            block.timestamp + 3600,
            address(this),
            "someURI"
        );
    }

    function _signPermit(
        Vm.Wallet memory wallet,
        address permitToken,
        address spender,
        uint256 value,
        uint256 deadline
    )
        internal
        returns (uint8, bytes32, bytes32)
    {
        uint256 nonce = MockERC20(permitToken).nonces(wallet.addr);
        bytes32 permitTypeHash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 domainSeparator = token.DOMAIN_SEPARATOR();

        bytes32 structHash = keccak256(abi.encode(permitTypeHash, wallet.addr, spender, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", domainSeparator, structHash));

        return vm.sign(wallet, digest);
    }
}
