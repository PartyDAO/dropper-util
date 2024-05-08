// SPDX-License-Identifier: UNLICENSED
pragma solidity >=0.8.25 <0.9.0;

import { PRBTest, Vm } from "@prb/test/src/PRBTest.sol";
import { StdCheats } from "forge-std/src/StdCheats.sol";
import { Dropper } from "../src/Dropper.sol";
import { MockERC20 } from "forge-std/src/mocks/MockERC20.sol";
import { Merkle } from "murky/src/Merkle.sol";
import { IERC20Permit } from "openzeppelin-contracts/contracts/token/ERC20/extensions/IERC20Permit.sol";

contract DropperTest is PRBTest, StdCheats {
    event DropCreated(
        uint256 indexed dropId,
        Dropper.DropStaticData dropStaticData,
        uint256 claimFee,
        Dropper.FeeRecipient[] feeRecipients,
        Dropper.DropMetadata dropMetadata
    );
    event DropClaimed(uint256 indexed dropId, address indexed recipient, address indexed tokenAddress, uint256 amount);

    event DropRefunded(uint256 indexed dropId, address indexed recipient, address indexed tokenAddress, uint256 amount);

    event ClaimFeeSet(uint256 oldClaimFee, uint256 claimFee);

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

    function testCreateDropWithFee(
        address[4] memory recipients,
        uint40[4] memory amounts,
        uint256 claimFee,
        address[4] memory feeRecipientAddresses
    )
        public
        returns (uint256 dropId, bytes32[] memory merkleLeaves)
    {
        Dropper.FeeRecipient[] memory feeRecipients = new Dropper.FeeRecipient[](0);
        if (claimFee != 0) {
            feeRecipients = new Dropper.FeeRecipient[](4);
            vm.assume(claimFee < type(uint96).max);
            vm.assume(feeRecipientAddresses.length < 10);
            vm.assume(feeRecipientAddresses.length != 0);
            for (uint256 i = 0; i < feeRecipients.length; i++) {
                vm.assume(uint256(uint160(feeRecipientAddresses[i])) > 1e5);
                vm.assume(feeRecipientAddresses[i] != address(this));
                vm.assume(feeRecipientAddresses[i] != address(dropper));
                vm.assume(feeRecipientAddresses[i] != address(token));
                vm.assume(feeRecipientAddresses[i] != VM_ADDRESS);

                feeRecipients[i].recipient = feeRecipientAddresses[i];
                feeRecipients[i] = Dropper.FeeRecipient({ recipient: feeRecipientAddresses[i], percentageBps: 2500 });

                for (uint256 j = i; j < feeRecipients.length; j++) {
                    if (i != j) {
                        vm.assume(feeRecipientAddresses[i] != feeRecipientAddresses[j]);
                    }
                }
                for (uint256 j = 0; j < recipients.length; j++) {
                    vm.assume(feeRecipientAddresses[i] != recipients[j]);
                }
            }
        }

        for (uint256 i = 0; i < recipients.length; i++) {
            vm.assume(recipients[i] != address(this));
            vm.assume(recipients[i] != address(dropper));
            for (uint256 j = i; j < recipients.length; j++) {
                if (i != j) {
                    vm.assume(recipients[i] != recipients[j]);
                }
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

        Dropper.DropStaticData memory dropStaticData = Dropper.DropStaticData({
            merkleRoot: merkleRoot,
            totalTokens: totalDropAmount,
            tokenAddress: address(token),
            startTimestamp: uint40(block.timestamp),
            expirationTimestamp: uint40(block.timestamp + 3600),
            expirationRecipient: address(this)
        });
        Dropper.DropMetadata memory dropMetadata =
            Dropper.DropMetadata({ merkleTreeURI: "someURI", dropDescription: "My Drop" });

        uint256 expectedDropId = dropper.numDrops() + 1;
        vm.expectEmit(true, true, true, true);
        emit DropCreated(expectedDropId, dropStaticData, claimFee, feeRecipients, dropMetadata);

        uint256 balanceBefore = token.balanceOf(address(dropper));
        dropId = dropper.createDrop(dropStaticData, claimFee, feeRecipients, dropMetadata);

        assertEq(dropId, expectedDropId);
        assertEq(token.balanceOf(address(dropper)), balanceBefore + totalDropAmount);
    }

    function testCreateDrop(
        address[4] memory recipients,
        uint40[4] memory amounts
    )
        public
        returns (uint256 dropId, bytes32[] memory merkleLeaves)
    {
        return testCreateDropWithFee(recipients, amounts, 0, [address(0), address(0), address(0), address(0)]);
    }

    function testCreateDropMerkleRootNotSet() public {
        deal(address(token), address(this), 1000e18);
        token.approve(address(dropper), 1000e18);

        vm.expectRevert(abi.encodeWithSelector(Dropper.MerkleRootNotSet.selector));
        dropper.createDrop(
            Dropper.DropStaticData({
                merkleRoot: bytes32(0),
                totalTokens: 1000e18,
                tokenAddress: address(token),
                startTimestamp: uint40(block.timestamp),
                expirationTimestamp: uint40(block.timestamp + 3600),
                expirationRecipient: address(this)
            }),
            0,
            new Dropper.FeeRecipient[](0),
            Dropper.DropMetadata({ merkleTreeURI: "someURI", dropDescription: "My Drop" })
        );
    }

    function test_createDrop_revert_expirationRecipientIsZero() external {
        deal(address(token), address(this), 1000e18);
        token.approve(address(dropper), 1000e18);

        vm.expectRevert(Dropper.ExpirationRecipientIsZero.selector);
        dropper.createDrop(
            Dropper.DropStaticData({
                merkleRoot: bytes32(uint256(1)),
                totalTokens: 1000e18,
                tokenAddress: address(token),
                startTimestamp: uint40(block.timestamp),
                expirationTimestamp: uint40(block.timestamp + 3600),
                expirationRecipient: address(0)
            }),
            0,
            new Dropper.FeeRecipient[](0),
            Dropper.DropMetadata({ merkleTreeURI: "someURI", dropDescription: "My Drop" })
        );
    }

    function testCreateDropTotalTokenIsZero() public {
        deal(address(token), address(this), 1000e18);
        token.approve(address(dropper), 1000e18);

        vm.expectRevert(abi.encodeWithSelector(Dropper.TotalTokenIsZero.selector));
        dropper.createDrop(
            Dropper.DropStaticData({
                merkleRoot: bytes32(uint256(1)),
                totalTokens: 0,
                tokenAddress: address(token),
                startTimestamp: uint40(block.timestamp),
                expirationTimestamp: uint40(block.timestamp + 3600),
                expirationRecipient: address(this)
            }),
            0,
            new Dropper.FeeRecipient[](0),
            Dropper.DropMetadata({ merkleTreeURI: "someURI", dropDescription: "My Drop" })
        );
    }

    function testCreateDropTokenAddressIsZero() public {
        deal(address(token), address(this), 1000e18);
        token.approve(address(dropper), 1000e18);

        vm.expectRevert(abi.encodeWithSelector(Dropper.TokenAddressIsZero.selector));
        dropper.createDrop(
            Dropper.DropStaticData({
                merkleRoot: bytes32(uint256(1)),
                totalTokens: 1000e18,
                tokenAddress: address(0),
                startTimestamp: uint40(block.timestamp),
                expirationTimestamp: uint40(block.timestamp + 3600),
                expirationRecipient: address(this)
            }),
            0,
            new Dropper.FeeRecipient[](0),
            Dropper.DropMetadata({ merkleTreeURI: "someURI", dropDescription: "My Drop" })
        );
    }

    function testCreateDropExpirationTimestampInPast() public {
        deal(address(token), address(this), 1000e18);
        token.approve(address(dropper), 1000e18);

        vm.expectRevert(abi.encodeWithSelector(Dropper.ExpirationTimestampInPast.selector));
        dropper.createDrop(
            Dropper.DropStaticData({
                merkleRoot: bytes32(uint256(1)),
                totalTokens: 1000e18,
                tokenAddress: address(token),
                startTimestamp: uint40(block.timestamp),
                expirationTimestamp: uint40(block.timestamp - 1),
                expirationRecipient: address(this)
            }),
            0,
            new Dropper.FeeRecipient[](0),
            Dropper.DropMetadata({ merkleTreeURI: "someURI", dropDescription: "My Drop" })
        );
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
            assertTrue(dropper.hasClaimed(dropId, member));
        }

        // All have claimed
        assertEq(token.balanceOf(address(dropper)), 0);
    }

    function test_claim_withClaimFee(
        address[4] memory recipients,
        uint40[4] memory amounts,
        uint256 claimFee,
        address[4] memory feeRecipientAddresses
    )
        public
    {
        vm.assume(claimFee > 0);

        (uint256 dropId, bytes32[] memory merkleLeaves) =
            testCreateDropWithFee(recipients, amounts, claimFee, feeRecipientAddresses);

        (, Dropper.DropFeeData memory dropFeeData,) = dropper.getDrop(dropId);

        for (uint256 i = 0; i < 4; i++) {
            address member = recipients[i];
            uint256 amount = amounts[i];

            vm.deal(member, dropFeeData.claimFee);

            bytes32[] memory proof = merkle.getProof(merkleLeaves, i);

            vm.expectEmit(true, true, true, true);
            emit DropClaimed(dropId, member, address(token), amount);

            uint256[] memory feeRecipientBalancesBefore = new uint256[](feeRecipientAddresses.length);

            for (uint256 j = 0; j < feeRecipientAddresses.length; j++) {
                feeRecipientBalancesBefore[j] = feeRecipientAddresses[j].balance;
            }

            vm.prank(member);
            dropper.claim{ value: dropFeeData.claimFee }(dropId, amount, proof);

            for (uint256 j = 0; j < feeRecipientAddresses.length; j++) {
                assertEq(
                    feeRecipientAddresses[j].balance,
                    feeRecipientBalancesBefore[j]
                        + dropFeeData.claimFee * dropFeeData.feeRecipients[j].percentageBps / 10_000
                );
            }

            assertEq(token.balanceOf(member), amount);
            assertTrue(dropper.hasClaimed(dropId, member));
        }
    }

    function test_claim_revert_claimFeeNotEnough(
        address[4] memory recipients,
        uint40[4] memory amounts,
        uint256 claimFee,
        address[4] memory feeRecipientAddresses
    )
        public
    {
        vm.assume(claimFee > 0);
        (uint256 dropId, bytes32[] memory merkleLeaves) =
            testCreateDropWithFee(recipients, amounts, claimFee, feeRecipientAddresses);

        (, Dropper.DropFeeData memory drop,) = dropper.getDrop(dropId);

        bytes32[] memory proof = merkle.getProof(merkleLeaves, 0);

        address member = recipients[0];
        vm.deal(member, drop.claimFee);

        vm.expectRevert(Dropper.InvalidMsgValue.selector);
        vm.prank(member);
        dropper.claim{ value: drop.claimFee - 1 }(dropId, amounts[0], proof);
    }

    function test_claim_revert_invalidDropId() external {
        vm.expectRevert(Dropper.InvalidDropId.selector);
        dropper.claim(0, 100, new bytes32[](0));
    }

    function testClaimDropExpired(address[4] memory recipients, uint40[4] memory amounts) public {
        (uint256 dropId, bytes32[] memory merkleLeaves) = testCreateDrop(recipients, amounts);

        uint256 amount = amounts[0];

        vm.warp(block.timestamp + 3601);

        bytes32[] memory proof = merkle.getProof(merkleLeaves, 0);

        vm.expectRevert(abi.encodeWithSelector(Dropper.DropNotLive.selector));
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

        Dropper.DropStaticData memory dropStaticData = Dropper.DropStaticData({
            merkleRoot: merkleRoot,
            totalTokens: totalDropAmount,
            tokenAddress: address(token),
            startTimestamp: uint40(block.timestamp),
            expirationTimestamp: uint40(block.timestamp + 3600),
            expirationRecipient: address(this)
        });
        Dropper.DropMetadata memory dropMetadata =
            Dropper.DropMetadata({ merkleTreeURI: "someURI", dropDescription: "My Drop" });

        uint256 expectedDropId = dropper.numDrops() + 1;
        vm.expectEmit(true, true, true, true);
        emit DropCreated(expectedDropId, dropStaticData, 0, new Dropper.FeeRecipient[](0), dropMetadata);

        uint256 balanceBefore = token.balanceOf(address(dropper));
        uint256 dropId = dropper.createDrop(dropStaticData, 0, new Dropper.FeeRecipient[](0), dropMetadata);

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

    function test_refundToRecipient_reverts_dropIdInvalid() public {
        (uint256 dropId,) =
            testCreateDrop([address(1), address(2), address(3), address(4)], [uint40(100), 1000, 1000, 1000]);

        vm.warp(block.timestamp + 3601);

        vm.expectRevert(Dropper.InvalidDropId.selector);
        dropper.refundToRecipient(dropId + 1);

        vm.expectRevert(Dropper.InvalidDropId.selector);
        dropper.refundToRecipient(0);
    }

    function test_createDrop_fail_endBeforeStart() external {
        vm.expectRevert(Dropper.EndBeforeStart.selector);
        dropper.createDrop(
            Dropper.DropStaticData({
                merkleRoot: bytes32(uint256(2)),
                totalTokens: 1e5,
                tokenAddress: address(token),
                startTimestamp: uint40(block.timestamp + 3601),
                expirationTimestamp: uint40(block.timestamp + 3600),
                expirationRecipient: address(this)
            }),
            0,
            new Dropper.FeeRecipient[](0),
            Dropper.DropMetadata({ merkleTreeURI: "someURI", dropDescription: "My Drop" })
        );
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

    function test_permitAndCreateDrop_permitWorks(uint256 creatorPk) external {
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

        Dropper.DropStaticData memory dropStaticData = Dropper.DropStaticData({
            merkleRoot: merkleRoot,
            totalTokens: totalDropAmount,
            tokenAddress: address(token),
            startTimestamp: uint40(block.timestamp),
            expirationTimestamp: uint40(block.timestamp + 3600),
            expirationRecipient: address(this)
        });
        Dropper.DropMetadata memory dropMetadata =
            Dropper.DropMetadata({ merkleTreeURI: "someURI", dropDescription: "My Drop" });

        uint256 expectedDropId = dropper.numDrops() + 1;
        vm.expectEmit(true, true, true, true);
        emit DropCreated(expectedDropId, dropStaticData, 0, new Dropper.FeeRecipient[](0), dropMetadata);

        Dropper.PermitArgs memory permitArgs = Dropper.PermitArgs(totalDropAmount, block.timestamp + 1, v, r, s);

        vm.prank(creator.addr);
        dropper.permitAndCreateDrop(
            permitArgs,
            Dropper.DropStaticData({
                merkleRoot: merkleRoot,
                totalTokens: totalDropAmount,
                tokenAddress: address(token),
                startTimestamp: uint40(block.timestamp),
                expirationTimestamp: uint40(block.timestamp + 3600),
                expirationRecipient: address(this)
            }),
            0,
            new Dropper.FeeRecipient[](0),
            Dropper.DropMetadata({ merkleTreeURI: "someURI", dropDescription: "My Drop" })
        );
    }

    function test_permitAndCreateDrop_reverts_insufficientPermitAmount(uint256 creatorPk) external {
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
            _signPermit(creator, address(token), address(dropper), totalDropAmount - 1, block.timestamp + 1);
        Dropper.PermitArgs memory permitArgs = Dropper.PermitArgs(totalDropAmount - 1, block.timestamp + 1, v, r, s);

        vm.prank(creator.addr);
        vm.expectRevert(Dropper.InsufficientPermitAmount.selector);
        dropper.permitAndCreateDrop(
            permitArgs,
            Dropper.DropStaticData({
                merkleRoot: merkleRoot,
                totalTokens: totalDropAmount,
                tokenAddress: address(token),
                startTimestamp: uint40(block.timestamp),
                expirationTimestamp: uint40(block.timestamp + 3600),
                expirationRecipient: address(this)
            }),
            0,
            new Dropper.FeeRecipient[](0),
            Dropper.DropMetadata({ merkleTreeURI: "someURI", dropDescription: "My Drop" })
        );
    }

    function test_permitAndCreateDrop_permitRevertsTxSuccess(uint256 creatorPk) external {
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
        Dropper.PermitArgs memory permitArgs = Dropper.PermitArgs(totalDropAmount, block.timestamp + 1, v, r, s);

        IERC20Permit(address(token)).permit(
            creator.addr, address(dropper), totalDropAmount, block.timestamp + 1, v, r, s
        );

        vm.prank(creator.addr);
        dropper.permitAndCreateDrop(
            permitArgs,
            Dropper.DropStaticData({
                merkleRoot: merkleRoot,
                totalTokens: totalDropAmount,
                tokenAddress: address(token),
                startTimestamp: uint40(block.timestamp),
                expirationTimestamp: uint40(block.timestamp + 3600),
                expirationRecipient: address(this)
            }),
            0,
            new Dropper.FeeRecipient[](0),
            Dropper.DropMetadata({ merkleTreeURI: "someURI", dropDescription: "My Drop" })
        );
    }

    function test_VERSION() external {
        assertEq(dropper.VERSION(), "2.0.0");
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

    receive() external payable { }
}
