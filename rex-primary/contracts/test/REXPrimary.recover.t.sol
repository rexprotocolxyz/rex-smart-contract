// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {Codec} from "@rex-shared/Codec.sol";
import "../src/REXPrimary.sol";
import "@rex-shared/Receipt.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/INavOracle.sol";
import "@rex-shared/Errors.sol";
import "./mocks/MockERC20.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import "@rex-shared-mocks/MockNavOracle.sol";
import {perSecondSchedule, warpToNextPeriod, warpBy} from "./helpers/TestSchedule.sol";

/// @dev M-1 (audit remediation, spec section 11): `recoverStuckBatch` -- the scoped, owner-gated
/// recovery for a redeem/subscribe batch stuck `Bridged` because its return leg is
/// un-processable (e.g. an under-delivered/short return keeps rendezvous-ing `NotReadyToExecute`
/// forever). Mirrors `REXPrimary.sweep.t.sol`'s harness style.
contract REXPrimaryRecoverTest is Test {
    event StuckBatchRecovered(uint64 indexed batchId, bool isRedeem, uint256 residual);

    MockMailbox mailbox;
    MockERC20 usdc;
    MockCollateralWarpRoute usdcRoute;
    MockSyntheticWarpRoute wrwaRoute;
    MockNavOracle navOracle;
    REXPrimary rex;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address executor = makeAddr("executor");
    address feeRecipient = address(0xFEE);
    uint32 constant PRUV_DOMAIN = 7336;
    uint64 constant REDEEM_FULFILL_TIMEOUT = 10 days;
    uint64 constant SUB_FULFILL_TIMEOUT = 3 days;
    uint64 constant WIND_DOWN_WINDOW = 9 days;

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
        wrwaRoute.setGasQuote(0);
        navOracle = new MockNavOracle(1e18);
        rex = _deploy(0, feeRecipient); // minRedeem 0 -> every redeem bridges immediately
        rex.enrollRemote(PRUV_DOMAIN, _b32(executor));
        _toEpochBased(rex);
    }

    /// @dev A second pool with a nonzero minRedeem, for the still-`Accumulating` guard case (a
    /// redeem request below `minRedeem_` never bridges). Mirrors REXPrimaryLifecycleTest's
    /// `_redeemPool`.
    /// @param minRedeem_ In **wRWA** (ADR-026 D2); this fixture's NAV is a fixed 1e18 and both mocks
    /// are 6-decimal, so the threshold reads the same as under the old USDC-value gate.
    function _deploy(uint256 minRedeem_, address feeRecipient_) internal returns (REXPrimary r) {
        r = new REXPrimary(
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
            feeRecipient_,
            SC3Params({
                navOracle: INavOracle(address(navOracle)),
                minRedeem: minRedeem_,
                redeemCancelFeeBps: 0,
                // DELIBERATELY unequal to redeemFulfillTimeout. They were both 10 days, which made
                // `recoverStuckBatch`'s per-leg choice unobservable: swapping the subscribe leg
                // onto the redeem timeout kept every test green. Shipped config differs (3d vs
                // 10d), so that swap would be a real 3-day/10-day error on the money path.
                subFulfillTimeout: SUB_FULFILL_TIMEOUT,
                redemptionFeeBps: 0,
                redeemFulfillTimeout: REDEEM_FULFILL_TIMEOUT,
                windDownWindow: WIND_DOWN_WINDOW,
                schedule: perSecondSchedule()
            })
        );
    }

    /// @dev Reach EpochBased via a zero-raise vacuous launchpad close (launchpadMinimum == 0 in
    /// `_deploy`), so no bridge plumbing / msg.value is needed.
    function _toEpochBased(REXPrimary r) internal {
        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad();
    }

    /// @dev Helper: mint wRWA to `who`, approve, requestRedeem on `r`.
    function _requestRedeem(REXPrimary r, address who, uint256 amount) internal {
        wrwaRoute.deliverTokens(_b32(who), amount);
        vm.startPrank(who);
        IERC20(address(wrwaRoute)).approve(address(r), amount);
        r.requestRedeem(amount);
        vm.stopPrank();
    }

    /// @dev Helper: mint usdc to `who`, approve, requestDeposit on `r`.
    function _requestDeposit(REXPrimary r, address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(r), amount);
        r.requestDeposit(amount);
        vm.stopPrank();
    }

    /// @dev Deliver a SHORT/partial USDC return for a redeem batch's covering collateral, then
    /// attempt (and expect to fail) the paired instruction -- the rendezvous can never complete
    /// because `_usdcFresh()` never reaches the full `instr.amount`, so `returnReceived` never
    /// latches and the batch is stuck `Bridged` forever (the M-1 scenario). Returns the short
    /// amount that lands in `balanceOf` outside every reserve.
    function _deliverShortRedeemReturn(REXPrimary r, uint64 batchId, uint256 shortAmount, uint256 fullAmount) internal {
        usdc.mint(address(usdcRoute), shortAmount);
        usdcRoute.deliverTokens(_b32(address(r)), shortAmount);
        bytes memory body = Codec.encode(
            Instruction({legId: batchId, kind: RequestKind.Redeem, amount: fullAmount, navAtInitiate: 1e18})
        );
        vm.prank(address(mailbox));
        vm.expectRevert(NotReadyToExecute.selector);
        r.handle(PRUV_DOMAIN, _b32(executor), body);
    }

    /// @notice M-1 core scenario: a redeem batch bridges, its return under-delivers (short), the
    /// rendezvous can never complete, and the batch sits `Bridged` forever -- stranding the short
    /// USDC AND keeping `outstandingRedeemBatches() != 0`, which blocks `triggerShutDown`.
    /// `recoverStuckBatch` (only reachable once the bridge deadline has passed) terminates the
    /// batch and unblocks shut-down, LEAVING the stranded residual in place (ADR-031); `sweep`,
    /// reachable again now that quiescence is restored, is what moves it to `feeRecipient`.
    function test_M1_recover_unblocks_shutdown_and_leaves_residual() public {
        _requestRedeem(rex, alice, 50e6);
        rex.initiateSubEpoch(); // minRedeem 0 -> redeem batch 1 bridges in-tx, now Bridged
        assertEq(rex.outstandingRedeemBatches(), 1);

        _deliverShortRedeemReturn(rex, 1, 40e6, 50e6); // only 40e6 of the expected 50e6 lands
        (,, uint256 returnedAmount, bool returnReceived) = rex.batchLeg(1, true);
        assertFalse(returnReceived, "rendezvous never completes on a short return");
        assertEq(returnedAmount, 0);
        assertEq(usdc.balanceOf(address(rex)), 40e6, "short USDC stranded, outside every reserve");

        // Stuck window: sweep refuses (quiescence gate), and shut-down cannot complete even once
        // the wind-down window elapses -- batch 1 is still Bridged.
        vm.expectRevert(InvalidState.selector);
        rex.sweep(address(usdc), feeRecipient, 40e6);

        rex.triggerWindDown();
        vm.warp(block.timestamp + WIND_DOWN_WINDOW + 1 days + 1); // past wind-down AND bridge deadline
        vm.expectRevert(WindDownNotComplete.selector);
        rex.triggerShutDown();

        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        // The event reports the residual it LEAVES BEHIND -- the verb moves no tokens (2026-09-18
        // review: paying `balance - reserved` here could take a parallel batch's landed return).
        vm.expectEmit(true, false, false, true, address(rex));
        emit StuckBatchRecovered(1, true, 40e6);
        rex.recoverStuckBatch(1, true);

        assertEq(rex.outstandingRedeemBatches(), 0, "outstanding drops by 1");
        assertEq(usdc.balanceOf(feeRecipient), feeBefore, "recovery moves no tokens");
        assertEq(usdc.balanceOf(address(rex)), 40e6, "the residual stays, for sweep to judge");

        rex.triggerShutDown(); // now reachable
        assertEq(uint8(rex.state()), uint8(REXPrimary.LifecycleState.ShutDown));

        // Quiescence is restored, so `sweep` -- the one place allowed to judge an unreserved
        // balance -- is what actually collects the residual.
        rex.sweep(address(usdc), feeRecipient, 40e6);
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, 40e6, "the residual leaves through sweep");
        assertEq(usdc.balanceOf(address(rex)), 0, "nothing left stray");
    }

    /// @dev Deliver a SHORT/partial wRWA return for a subscribe batch's covering payout, then
    /// attempt (and expect to fail) the paired instruction -- the rendezvous can never complete
    /// because `_wrwaFresh()` never reaches the full `instr.amount`, so `returnReceived` never
    /// latches and the batch is stuck `Bridged` forever (the M-1 scenario, subscribe leg). The
    /// short amount lands in `balanceOf` outside every reserve. Mirrors `_deliverShortRedeemReturn`.
    function _deliverShortSubReturn(REXPrimary r, uint64 batchId, uint256 shortAmount, uint256 fullAmount) internal {
        wrwaRoute.deliverTokens(_b32(address(r)), shortAmount);
        bytes memory body = Codec.encode(
            Instruction({legId: batchId, kind: RequestKind.Subscribe, amount: fullAmount, navAtInitiate: 1e18})
        );
        vm.prank(address(mailbox));
        vm.expectRevert(NotReadyToExecute.selector);
        r.handle(PRUV_DOMAIN, _b32(executor), body);
    }

    /// @notice Symmetric twin of `test_M1_recover_unblocks_shutdown_and_leaves_residual` for the
    /// SUBSCRIBE leg (`isRedeem == false`): a subscribe batch bridges, its wRWA return
    /// under-delivers (short), the rendezvous can never complete, and the batch sits `Bridged`
    /// forever -- stranding the short wRWA AND keeping `outstandingSubBatches() != 0`, which
    /// blocks `triggerShutDown`. `recoverStuckBatch(_, false)` terminates the batch and unblocks
    /// shut-down, LEAVING the stranded residual in place (ADR-031); `sweep` then moves it to
    /// `feeRecipient` on the wRWA leg too.
    function test_M1_recover_subscribe_leg_unblocks_shutdown_and_leaves_residual() public {
        _requestDeposit(rex, alice, 100e6);
        rex.initiateSubEpoch(); // minSub 0 -> subscribe batch 1 bridges in-tx, now Bridged
        assertEq(rex.outstandingSubBatches(), 1); // created, not terminated (terminated counter is internal)

        _deliverShortSubReturn(rex, 1, 80e6, 100e6); // only 80e6 of the expected 100e6 lands
        (,, uint256 returnedAmount, bool returnReceived) = rex.batchLeg(1, false);
        assertFalse(returnReceived, "rendezvous never completes on a short return");
        assertEq(returnedAmount, 0);
        assertEq(IERC20(address(wrwaRoute)).balanceOf(address(rex)), 80e6, "short wRWA stranded, outside every reserve");

        // Stuck window: sweep refuses (quiescence gate), and shut-down cannot complete even once
        // the wind-down window elapses -- batch 1 is still Bridged.
        vm.expectRevert(InvalidState.selector);
        rex.sweep(address(wrwaRoute), feeRecipient, 80e6);

        rex.triggerWindDown();
        // Warp past the WIND-DOWN window explicitly. It used to read `rex.subFulfillTimeout()`
        // here, which both hid the per-leg distinction and made the test assert a value it had
        // just asked the contract for.
        vm.warp(block.timestamp + WIND_DOWN_WINDOW + 1);
        vm.expectRevert(WindDownNotComplete.selector);
        rex.triggerShutDown();

        uint256 feeBefore = IERC20(address(wrwaRoute)).balanceOf(feeRecipient);
        vm.expectEmit(true, false, false, true, address(rex));
        emit StuckBatchRecovered(1, false, 80e6);
        rex.recoverStuckBatch(1, false);

        // outstanding==0 (created==1) proves the terminated counter incremented exactly once: a
        // double increment would underflow outstandingSubBatches() and revert, not read 0.
        assertEq(rex.outstandingSubBatches(), 0, "outstanding drops by 1, terminated once");
        assertEq(IERC20(address(wrwaRoute)).balanceOf(feeRecipient), feeBefore, "recovery moves no tokens");
        assertEq(IERC20(address(wrwaRoute)).balanceOf(address(rex)), 80e6, "the residual stays, for sweep to judge");

        rex.triggerShutDown(); // now reachable
        assertEq(uint8(rex.state()), uint8(REXPrimary.LifecycleState.ShutDown));

        // Quiescence restored -> `sweep` collects the residual, on the wRWA leg too.
        rex.sweep(address(wrwaRoute), feeRecipient, 80e6);
        assertEq(
            IERC20(address(wrwaRoute)).balanceOf(feeRecipient) - feeBefore, 80e6, "the residual leaves through sweep"
        );
        assertEq(IERC20(address(wrwaRoute)).balanceOf(address(rex)), 0, "nothing left stray");
    }

    /// @notice A live batch can NEVER be recovered: still-`Bridged`-but-pre-deadline, and any
    /// non-`Bridged` status (`Accumulating`, `Settled`), all revert.
    function test_M1_reverts_on_live_batch() public {
        // (a) Bridged but pre-deadline.
        _requestRedeem(rex, alice, 50e6);
        rex.initiateSubEpoch(); // batch 1 Bridged
        vm.expectRevert(AbortBeforeDeadline.selector);
        rex.recoverStuckBatch(1, true);

        // fulfil the batch for real instead of recovering it, proving Settled also guards shut.
        _fulfillRedeemBatch(rex, 1, 50e6);
        vm.expectRevert(InvalidState.selector);
        rex.recoverStuckBatch(1, true); // (b) Settled, not Bridged

        // (c) still-Accumulating: a redeem request below a nonzero minRedeem never bridges.
        REXPrimary r2 = _deploy(100e6, makeAddr("fee2"));
        r2.enrollRemote(PRUV_DOMAIN, _b32(executor));
        _toEpochBased(r2);
        _requestRedeem(r2, alice, 40e6); // below minRedeem 100e6 -> stays Accumulating, batch 1
        vm.expectRevert(InvalidState.selector);
        r2.recoverStuckBatch(1, true);
    }

    /// @dev Helper: deliver a redeem batch's full covering USDC return and settle normally.
    function _fulfillRedeemBatch(REXPrimary r, uint64 batchId, uint256 amount) internal {
        usdc.mint(address(usdcRoute), amount);
        usdcRoute.deliverTokens(_b32(address(r)), amount);
        bytes memory body =
            Codec.encode(Instruction({legId: batchId, kind: RequestKind.Redeem, amount: amount, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        r.handle(PRUV_DOMAIN, _b32(executor), body);
        r.settleRedeemBatch(batchId);
    }

    /// @notice 2026-09-18 actor-behaviour review, B1: recovering a DEAD batch must not touch a
    /// HEALTHY parallel batch's return that has physically landed while its paired instruction is
    /// still in flight. That money sits in `balanceOf` outside every reserve counter
    /// (`settledRedeemUSDC` is credited inside `_onInstruction`), so the old `balance - reserved`
    /// payout took it to `feeRecipient` -- after which the victim's instruction reverted
    /// `NotReadyToExecute` forever and its holders claimed zero. Fails without the fix.
    function test_recover_leaves_a_parallel_batchs_landed_return_alone() public {
        // Batch 1: the genuine M-1 case -- a short return no rendezvous can ever complete.
        _requestRedeem(rex, alice, 50e6);
        rex.initiateSubEpoch();
        _deliverShortRedeemReturn(rex, 1, 40e6, 50e6);

        // Batch 2: a perfectly healthy redeem, bridged in the next period (parallel, ADR-018).
        _requestRedeem(rex, bob, 30e6);
        uint64 epoch2 = rex.currentEpochId(); // the epoch bob's receipt was minted into
        warpToNextPeriod(rex);
        rex.initiateSubEpoch();
        assertEq(rex.outstandingRedeemBatches(), 2, "both batches outstanding");

        // Batch 2's USDC return LANDS; its paired instruction is still in flight (spec §3.4).
        usdc.mint(address(usdcRoute), 30e6);
        usdcRoute.deliverTokens(_b32(address(rex)), 30e6);
        assertEq(usdc.balanceOf(address(rex)), 70e6, "40e6 stranded (batch 1) + 30e6 in flight (batch 2)");

        // Recover the dead batch 1 once past its deadline.
        warpBy(REDEEM_FULFILL_TIMEOUT + 1);
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        rex.recoverStuckBatch(1, true);
        assertEq(usdc.balanceOf(feeRecipient), feeBefore, "recovery took nothing from anyone");
        assertEq(usdc.balanceOf(address(rex)), 70e6, "batch 2's money is untouched");

        // Batch 2's instruction lands late and settles normally.
        bytes memory body =
            Codec.encode(Instruction({legId: 2, kind: RequestKind.Redeem, amount: 30e6, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
        rex.settleRedeemBatch(2);

        // Bob is paid in full (this fixture's redemptionFeeBps is 0).
        uint256 id2 = encodeId(CLASS_RED_EPOCH, epoch2);
        vm.prank(bob);
        rex.claim(id2, 30e6);
        assertEq(usdc.balanceOf(bob), 30e6, "the healthy parallel batch paid in full");

        // Only batch 1's own residual is left, and `sweep` is what collects it.
        assertEq(usdc.balanceOf(address(rex)), 40e6, "batch 1's residual, and nothing else");
        rex.sweep(address(usdc), feeRecipient, 40e6);
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, 40e6, "the fee recipient gets the dead batch's residual");
    }

    /// @notice The cost of leaving the residual in place, pinned: it raises `_usdcFresh()`, so a
    /// LATER batch's rendezvous can complete against money that is not its own. That is bounded
    /// misattribution, never an accounting error -- the credit happens once, at record; a repeat
    /// delivery is a no-op; the claim pays once; reserves never exceed the balance; and only the
    /// leftover is sweepable. (Demanded by the 2026-09-18 fix review.)
    function test_recovery_residual_can_complete_a_later_short_return_without_double_credit() public {
        _requestRedeem(rex, alice, 50e6);
        rex.initiateSubEpoch();
        _deliverShortRedeemReturn(rex, 1, 40e6, 50e6);
        warpBy(REDEEM_FULFILL_TIMEOUT + 1);
        rex.recoverStuckBatch(1, true);
        assertEq(usdc.balanceOf(address(rex)), 40e6, "residual left behind");

        // Batch 2 bridges and its own return lands SHORT by 5e6 -- the residual covers the gap.
        _requestRedeem(rex, bob, 30e6);
        uint64 epoch2 = rex.currentEpochId(); // the epoch bob's receipt was minted into
        warpToNextPeriod(rex);
        rex.initiateSubEpoch();
        usdc.mint(address(usdcRoute), 25e6);
        usdcRoute.deliverTokens(_b32(address(rex)), 25e6);
        bytes memory body =
            Codec.encode(Instruction({legId: 2, kind: RequestKind.Redeem, amount: 30e6, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
        assertEq(rex.settledRedeemUSDC(), 30e6, "credited once, at record");
        assertLe(
            rex.settledRedeemUSDC() + rex.heldEscrowUSDC(),
            usdc.balanceOf(address(rex)),
            "reserves never exceed the physical balance"
        );

        // A repeat delivery of the same leg is a no-op (`processedLeg`), not a second credit.
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
        assertEq(rex.settledRedeemUSDC(), 30e6, "no double credit");

        rex.settleRedeemBatch(2);
        uint256 id2 = encodeId(CLASS_RED_EPOCH, epoch2);
        vm.prank(bob);
        rex.claim(id2, 30e6);
        assertEq(usdc.balanceOf(bob), 30e6, "paid once, in full");
        assertEq(rex.settledRedeemUSDC(), 0, "the pot is exactly emptied");

        // What remains is only the leftover, sweepable now that nothing is in flight.
        assertEq(usdc.balanceOf(address(rex)), 35e6, "40e6 residual + 25e6 landed - 30e6 paid");
        uint256 feeBefore = usdc.balanceOf(feeRecipient);
        rex.sweep(address(usdc), feeRecipient, 35e6);
        assertEq(usdc.balanceOf(feeRecipient) - feeBefore, 35e6, "only the leftover is sweepable");
    }

    function test_M1_recoverStuckBatch_non_owner_reverts() public {
        _requestRedeem(rex, alice, 50e6);
        rex.initiateSubEpoch();
        vm.warp(block.timestamp + REDEEM_FULFILL_TIMEOUT + 1);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(); // OwnableUnauthorizedAccount
        rex.recoverStuckBatch(1, true);
    }
}
