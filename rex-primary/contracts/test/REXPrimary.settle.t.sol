// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {Codec} from "@rex-shared/Codec.sol";
import "../src/REXPrimary.sol";
import "@rex-shared/Receipt.sol";
import "@rex-shared/IHyperlane.sol";
import "./mocks/MockERC20.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import "@rex-shared-mocks/MockNavOracle.sol";
import "@rex-shared/INavOracle.sol";
import {perSecondSchedule, warpToNextPeriod} from "./helpers/TestSchedule.sol";

contract REXPrimarySettleTest is Test {
    MockMailbox mailbox;
    MockERC20 usdc;
    MockCollateralWarpRoute usdcRoute;
    MockSyntheticWarpRoute wrwaRoute;
    MockNavOracle navOracle;
    REXPrimary rex;

    address alice = makeAddr("alice");
    address executor = makeAddr("executor");
    uint32 constant PRUV_DOMAIN = 7336;

    receive() external payable {}

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function setUp() public {
        mailbox = new MockMailbox(PRUV_DOMAIN);
        mailbox.setQuoteFee(0);
        usdc = new MockERC20("USDC", 6);
        usdcRoute = new MockCollateralWarpRoute(usdc);
        usdcRoute.setGasQuote(0);
        wrwaRoute = new MockSyntheticWarpRoute("wRWA", 6);
        navOracle = new MockNavOracle(1e18);
        rex = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            0,
            uint64(block.timestamp + 1),
            1 days,
            0,
            0,
            address(0xFEE),
            SC3Params({
                navOracle: INavOracle(address(navOracle)),
                minRedeem: 0,
                redeemCancelFeeBps: 0,
                subFulfillTimeout: 10 days,
                redemptionFeeBps: 0,
                redeemFulfillTimeout: 10 days,
                windDownWindow: 9 days,
                schedule: perSecondSchedule()
            })
        );
        rex.enrollRemote(PRUV_DOMAIN, _b32(executor));
        _reachEpochBased(rex);

        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(rex), 100e6);
        rex.requestDeposit(100e6);
        vm.stopPrank();
        rex.initiateSubEpoch();
    }

    /// @dev Reach EpochBased via a zero-raise vacuous launchpad close (launchpadMinimum == 0),
    /// which creates NO batch, so subscribe batch ids still start at 1.
    function _reachEpochBased(REXPrimary r) internal {
        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad();
    }

    /// @dev Delivers the return instruction as the enrolled PRUV executor would.
    function _deliverReturn(uint256 shares) internal {
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Subscribe, amount: shares, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
    }

    function test_return_without_covering_wrwa_reverts() public {
        vm.expectRevert(NotReadyToExecute.selector);
        _deliverReturn(98e6);
    }

    function test_return_with_tokens_records_the_pot() public {
        wrwaRoute.deliverTokens(_b32(address(rex)), 98e6);
        _deliverReturn(98e6);
        (,, uint256 returnedAmount, bool returnReceived) = rex.batchLeg(1, false);
        assertEq(returnedAmount, 98e6);
        assertTrue(returnReceived);
        // E6 (ADR-018): settledUnclaimed is credited at RECORD, before settleSubBatch ever runs.
        assertEq(rex.settledUnclaimed(), 98e6, "reserved at record, not at settle");
    }

    function test_settle_before_the_return_reverts() public {
        vm.expectRevert(NotReadyToExecute.selector);
        rex.settleSubBatch(1);
    }

    function test_settle_marks_settled() public {
        wrwaRoute.deliverTokens(_b32(address(rex)), 98e6);
        _deliverReturn(98e6);
        rex.settleSubBatch(1);

        (uint8 status,,) = rex.subBatch(1);
        assertEq(status, uint8(BatchStatus.Settled));
    }

    function test_settle_twice_reverts() public {
        wrwaRoute.deliverTokens(_b32(address(rex)), 98e6);
        _deliverReturn(98e6);
        rex.settleSubBatch(1);
        vm.expectRevert(InvalidState.selector);
        rex.settleSubBatch(1);
    }

    /// @dev T1: settle is permissionless once the return has recorded -- it only flips a
    /// Bridged batch to Settled, no privileged decision. A dead/censoring keeper must not be
    /// able to block this.
    function test_settle_by_non_keeper_succeeds() public {
        wrwaRoute.deliverTokens(_b32(address(rex)), 98e6);
        _deliverReturn(98e6);

        vm.prank(makeAddr("stranger"));
        rex.settleSubBatch(1);

        (uint8 status,,) = rex.subBatch(1);
        assertEq(status, uint8(BatchStatus.Settled));
    }

    /// @dev T3: guard-parity defense-in-depth. Once the Subscribe return has recorded
    /// (returnReceived = true, status stays Bridged), a different-kind second delivery
    /// (SubAborted) for the SAME batch must not be able to re-process it.
    function test_subscribe_return_then_subaborted_for_same_batch_reverts() public {
        wrwaRoute.deliverTokens(_b32(address(rex)), 98e6);
        _deliverReturn(98e6);

        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.SubAborted, amount: 98e6, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        vm.expectRevert(InvalidState.selector);
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
    }

    /// @dev Reproduces the aggregate-balance rendezvous bug: batch 1 settles but is
    /// left unclaimed, so its wRWA sits in the contract. Batch 2's instruction then
    /// arrives before batch 2's tokens. The stale check (raw `balanceOf`) would pass
    /// because batch 1's unclaimed pot alone covers batch 2's amount; the fixed check
    /// must subtract `settledUnclaimed` and still revert.
    function test_later_batch_instruction_not_satisfied_by_earlier_unclaimed_pot() public {
        // batch 1: settle, leave alice's payout unclaimed.
        wrwaRoute.deliverTokens(_b32(address(rex)), 98e6);
        _deliverReturn(98e6);
        rex.settleSubBatch(1);
        assertEq(rex.settledUnclaimed(), 98e6);

        // batch 2: a fresh epoch, bridged immediately (minSub == 0).
        usdc.mint(alice, 50e6);
        vm.startPrank(alice);
        usdc.approve(address(rex), 50e6);
        rex.requestDeposit(50e6);
        vm.stopPrank();
        warpToNextPeriod(rex); // ADR-025: one close per period
        rex.initiateSubEpoch();

        // batch 2's instruction arrives first; batch 2's wRWA has NOT landed yet.
        // The contract's raw balance is still 98e6 (batch 1's unclaimed pot), which
        // is >= batch 2's 49e6 amount, so the stale check would wrongly pass.
        bytes memory body =
            Codec.encode(Instruction({legId: 2, kind: RequestKind.Subscribe, amount: 49e6, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        vm.expectRevert(NotReadyToExecute.selector);
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
    }

    /// @dev After batch 1 fully claims, `settledUnclaimed` should equal only the
    /// floor-division dust (never negative, never underflowing), and the unreserved
    /// balance should be exactly zero so a later batch's early instruction still
    /// correctly reverts.
    function test_settled_unclaimed_tracks_dust_after_full_claim() public {
        wrwaRoute.deliverTokens(_b32(address(rex)), 98e6);
        _deliverReturn(98e6);
        rex.settleSubBatch(1);

        uint256 id = encodeId(CLASS_SUB_EPOCH, 1);
        vm.prank(alice);
        rex.claim(id, 100e6);

        uint256 balance = wrwaRoute.balanceOf(address(rex));
        uint256 reserved = rex.settledUnclaimed();
        // sole holder, so payout == returnedAmount exactly (no dust in this case);
        // the invariant balance - reserved == 0 must hold regardless.
        assertEq(balance, reserved);
    }

    function test_unenrolled_sender_is_rejected() public {
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 98e6, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        vm.expectRevert(UnauthorizedSender.selector);
        rex.handle(PRUV_DOMAIN, _b32(alice), body);
    }

    /// @dev A redeemer's escrowed wRWA must NOT satisfy a subscribe batch's return (D6 rendezvous).
    function test_redeem_escrow_does_not_satisfy_a_subscribe_return() public {
        address bob = makeAddr("bob");
        wrwaRoute.deliverTokens(_b32(bob), 98e6);
        vm.startPrank(bob);
        IERC20(address(wrwaRoute)).approve(address(rex), 98e6);
        rex.requestRedeem(98e6);
        vm.stopPrank();
        // batch 1's return instruction arrives, but batch 1's OWN wRWA has not landed
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 98e6, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        vm.expectRevert(NotReadyToExecute.selector);
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
    }
}
