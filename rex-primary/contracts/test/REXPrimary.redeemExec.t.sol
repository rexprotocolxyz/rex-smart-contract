// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {Codec} from "@rex-shared/Codec.sol";
import "../src/REXPrimary.sol";
import {REXLens} from "../src/REXLens.sol";
import "@rex-shared/Receipt.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/Wire.sol";
import "./mocks/MockERC20.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import "@rex-shared-mocks/MockNavOracle.sol";
import "@rex-shared/INavOracle.sol";
import {perSecondSchedule, warpToNextPeriod} from "./helpers/TestSchedule.sol";

contract REXPrimaryRedeemExecTest is Test {
    MockMailbox mailbox;
    MockERC20 usdc;
    MockCollateralWarpRoute usdcRoute;
    MockSyntheticWarpRoute wrwaRoute;
    MockNavOracle navOracle;
    REXPrimary rex;
    REXLens lens;

    address alice = makeAddr("alice"); // subscriber
    address bob = makeAddr("bob"); // redeemer
    address executor = makeAddr("executor");
    uint32 constant PRUV_DOMAIN = 7336;
    uint256 constant MIN_REDEEM = 50e6; // wRWA (ADR-026 D2); the mock wRWA route is 6-decimal

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
                minRedeem: MIN_REDEEM,
                redeemCancelFeeBps: 0,
                subFulfillTimeout: 10 days,
                redemptionFeeBps: 0,
                redeemFulfillTimeout: 10 days,
                windDownWindow: 9 days,
                schedule: perSecondSchedule()
            })
        );
        rex.enrollRemote(PRUV_DOMAIN, _b32(executor));
        vm.warp(rex.launchpadStart() + rex.launchpadPeriod());
        rex.closeLaunchpad(); // vacuous close (minimum 0) -> EpochBased, no batch
        lens = new REXLens();
    }

    /// @dev Give `who` wRWA and escrow it into the current redeem epoch.
    function _requestRedeem(address who, uint256 amt) internal returns (uint256 id) {
        wrwaRoute.deliverTokens(_b32(who), amt);
        vm.startPrank(who);
        IERC20(address(wrwaRoute)).approve(address(rex), amt);
        id = rex.requestRedeem(amt);
        vm.stopPrank();
    }

    /// @dev Bob alone: his whole redeem side is the net and bridges immediately
    /// (amt >= MIN_REDEEM) as the first-ever redeem batch.
    function _bridgeRedeem(uint256 amt) internal returns (uint64 batchId) {
        _requestRedeem(bob, amt); // amt >= MIN_REDEEM
        warpToNextPeriod(rex); // ADR-025: one close per period
        rex.initiateSubEpoch();
        return 1;
    }

    /// @dev Delivers a redeem batch's return instruction as the enrolled PRUV executor would,
    /// crediting the covering token first (either order works -- the rendezvous check is what
    /// actually gates `_onInstruction`, not delivery order).
    function _deliverRedeemReturn(uint64 batchId, RequestKind kind, uint256 amount) internal {
        // credit the covering token, then deliver the return instruction (either order works)
        if (kind == RequestKind.Redeem) {
            usdc.mint(address(usdcRoute), amount); // fund the collateral route to unlock from
            usdcRoute.deliverTokens(_b32(address(rex)), amount);
        } else {
            wrwaRoute.deliverTokens(_b32(address(rex)), amount);
        }
        bytes memory body = Codec.encode(Instruction({legId: batchId, kind: kind, amount: amount, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
    }

    /// @dev A second deployment with a nonzero `redemptionFeeBps`, reusing this contract's mocks.
    function _deployFee(uint16 bps) internal returns (REXPrimary r) {
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
            address(0xFEE),
            SC3Params({
                navOracle: INavOracle(address(navOracle)),
                minRedeem: MIN_REDEEM,
                redeemCancelFeeBps: 0,
                subFulfillTimeout: 10 days,
                redemptionFeeBps: bps,
                redeemFulfillTimeout: 10 days,
                windDownWindow: 9 days,
                schedule: perSecondSchedule()
            })
        );
        r.enrollRemote(PRUV_DOMAIN, _b32(executor));
        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad();
    }

    function test_previewRedeem_grossMinusFee() public view {
        (uint256 out, uint256 fee) = lens.previewRedeem(address(rex), 100e6); // nav 1e18, fee 0 here
        assertEq(fee, 0);
        assertEq(out, 100e6);
    }

    /// @dev Task 1 deferred minor: previewRedeem's fee math was only ever exercised at fee == 0;
    /// pin the nonzero-bps arithmetic too (0.5% of a 1:1 nav gross).
    function test_previewRedeem_nonZeroFee() public {
        rex = _deployFee(50); // 0.5%
        (uint256 out, uint256 fee) = lens.previewRedeem(address(rex), 100e6);
        assertEq(fee, 500_000);
        assertEq(out, 99_500_000);
    }

    function test_redeemBatch_unknown_isNone() public view {
        (uint8 status, uint256 netIn, uint64 accrualStart, uint64 deadline) = rex.redeemBatch(999);
        assertEq(status, 0); // BatchStatus.None
        assertEq(netIn, 0);
        assertEq(accrualStart, 0);
        assertEq(deadline, 0);
    }

    function test_redeem_atMin_bridges() public {
        // the whole redeem side is the net (ADR-024)
        _requestRedeem(bob, 60e6); // >= MIN_REDEEM 50e6
        vm.expectEmit(true, true, true, false, address(rex));
        emit IREXRedeem.RedeemBatchBridged(1, 60e6, bytes32(0));
        rex.initiateSubEpoch();

        (uint8 status, uint256 netIn,,) = rex.redeemBatch(1);
        assertEq(status, 2); // BatchStatus.Bridged
        assertEq(netIn, 60e6);
        assertEq(rex.liveRedeemEscrow(), 0); // wRWA left escrow to bridge
        assertEq(IERC20(address(wrwaRoute)).balanceOf(address(rex)), 0); // burned by the synthetic route
    }

    /// @dev ADR-027: the accrual cap is gone, so a below-min batch accrues indefinitely and
    /// wind-down is the one thing that can still close it. What this test is about -- accrual to
    /// `Released` without ever bridging, and the event that announces it -- is unchanged.
    function test_redeem_belowMin_accrues_then_releases() public {
        _requestRedeem(bob, 30e6); // < MIN_REDEEM
        rex.initiateSubEpoch();
        (uint8 s1, uint256 n1,,) = rex.redeemBatch(1);
        assertEq(s1, 1); // Accumulating
        assertEq(n1, 30e6);
        assertEq(rex.liveRedeemEscrow(), 30e6); // not bridged: still escrowed

        // still below min when the fund decommissions -> released, never bridged
        _requestRedeem(bob, 5e6); // keeps it below min, still uninitiated
        warpToNextPeriod(rex);
        rex.initiateSubEpoch(); // folds the second 5e6 in: 35e6, still under MIN_REDEEM
        rex.triggerWindDown();
        vm.warp(block.timestamp + rex.windDownWindow() + 1);
        vm.expectEmit(true, true, true, true, address(rex));
        emit IREXMatching.BatchReleased(1, uint8(RequestKind.Redeem), 35e6);
        rex.releaseStaleRedeemBatch(1);
        (uint8 s2,,,) = rex.redeemBatch(1);
        assertEq(s2, 4); // BatchStatus.Released
    }

    /// @dev No-theft regression (SC5a Task 3 review, spec §14): R1's epoch must lock the moment
    /// initiateSubEpoch consumes it, so a later epoch's fresh escrow can never be drained by an
    /// earlier, already-bridged redeemer's cancel. Before the fix (`red.locked` gated on a
    /// then-existing matched amount, so a merely-bridged side stayed unlocked), this exact sequence let
    /// R1's cancelRequest pay out of R2's escrow: the underflow guard alone did not catch it because
    /// R2's larger balance covered the subtraction.
    function test_redeem_locked_blocks_cross_epoch_cancel() public {
        uint256 id1 = _requestRedeem(bob, 60e6); // R1, >= MIN_REDEEM -> bridges, epoch 1 (ctor starts at 1)
        rex.initiateSubEpoch();
        (uint8 status,,,) = rex.redeemBatch(1);
        assertEq(status, 2); // Bridged -- R1's wRWA is already gone to Pruv
        (,,,, bool locked1) = rex.epochSide(1, CLASS_RED_EPOCH);
        assertTrue(locked1, "R1's epoch locks the moment initiateSubEpoch consumes it");

        address r2 = makeAddr("r2");
        _requestRedeem(r2, 80e6); // R2, next epoch (2) -- fresh escrow, big enough to mask an underflow
        uint256 escrowBefore = rex.liveRedeemEscrow();

        vm.prank(bob);
        vm.expectRevert(EpochLocked.selector);
        rex.cancelRequest(id1, 60e6); // must revert, NOT drain R2's escrow

        assertEq(rex.liveRedeemEscrow(), escrowBefore, "R2's escrow untouched by R1's blocked cancel");
        assertEq(IERC20(address(wrwaRoute)).balanceOf(bob), 0, "R1 gets nothing back from a blocked cancel");
    }

    /// @dev Regression (Task 4 review, CRITICAL): redeem batches are PARALLEL (subscribe batches
    /// are too, since ADR-018), so the USDC/wRWA reserve MUST be credited at RECORD
    /// (`_onInstruction`), not deferred to `settleRedeemBatch` -- otherwise a batch that has
    /// recorded its return but not yet been settled leaves its USDC sitting in the raw balance,
    /// uncounted by any reserve, and a second in-flight batch's rendezvous can "borrow" it as if
    /// it were its own fresh arrival (spec §14 insolvency: both would eventually settle, double-
    /// crediting `settledRedeemUSDC` against one physical pile of USDC). R1 records its fulfilled
    /// return (crediting the reserve) but is deliberately left un-settled; R2, a second parallel
    /// batch whose own USDC has NOT arrived, must then fail to rendezvous.
    function test_redeem_parallel_batch_cannot_borrow_unsettled_reserve() public {
        uint64 r1 = _bridgeRedeem(60e6);
        _deliverRedeemReturn(r1, RequestKind.Redeem, 60e6); // records; credits the reserve
        assertEq(rex.settledRedeemUSDC(), 60e6);
        (uint8 r1Status,,,) = rex.redeemBatch(r1);
        assertEq(r1Status, 2); // still Bridged -- settleRedeemBatch deliberately never called

        _bridgeRedeem(60e6); // R2: a second, parallel redeem batch, bridged in a later epoch
        uint64 r2 = rex.nextRedeemBatchId() - 1;
        assertTrue(r2 != r1);

        // R2's own USDC has NOT arrived -- only R1's already-recorded 60e6 sits in the contract.
        // Pre-fix (credit deferred to settle), that 60e6 was still uncounted by any reserve and
        // this call would WRONGLY succeed by "borrowing" it.
        bytes memory body =
            Codec.encode(Instruction({legId: r2, kind: RequestKind.Redeem, amount: 60e6, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        vm.expectRevert(NotReadyToExecute.selector);
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
    }

    /// @dev SC5a Task 4: a fulfilled `Redeem` return settles into the USDC pot, keyed off
    /// `retKind` recorded at rendezvous.
    function test_redeem_fulfilled_settles_into_settledRedeemUsdc() public {
        uint64 id = _bridgeRedeem(60e6);
        _deliverRedeemReturn(id, RequestKind.Redeem, 60e6); // 60 wRWA -> 60 USDC @ nav 1e18
        vm.expectEmit(true, true, true, true, address(rex));
        emit IREXRedeem.RedeemBatchSettled(id, 60e6);
        rex.settleRedeemBatch(id);
        (uint8 s,,,) = rex.redeemBatch(id);
        assertEq(s, 3); // Settled
        assertEq(rex.settledRedeemUSDC(), 60e6);
    }

    /// @dev SC5a Task 4: a `RedeemAborted` return settles into the wRWA refund pot instead --
    /// same batch-level Settled status, no usdcReturned (event's second arg is 0).
    function test_redeem_aborted_settles_into_settledUnclaimed() public {
        uint64 id = _bridgeRedeem(60e6);
        _deliverRedeemReturn(id, RequestKind.RedeemAborted, 60e6); // wRWA back
        vm.expectEmit(true, true, true, true, address(rex));
        emit IREXRedeem.RedeemBatchSettled(id, 0);
        rex.settleRedeemBatch(id);
        assertEq(rex.settledUnclaimed(), 60e6);
    }

    /// @dev SC5a Task 4: the per-leg replay latch covers the redeem return too -- a duplicate
    /// delivery of the same (legId, kind) is a silent no-op, so settling afterward does not
    /// double-count the pot.
    function test_redeem_return_replay_isNoop() public {
        uint64 id = _bridgeRedeem(60e6);
        _deliverRedeemReturn(id, RequestKind.Redeem, 60e6);
        // second identical delivery: silent no-op (processedLeg latch)
        bytes memory body =
            Codec.encode(Instruction({legId: id, kind: RequestKind.Redeem, amount: 60e6, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
        rex.settleRedeemBatch(id);
        assertEq(rex.settledRedeemUSDC(), 60e6); // not doubled
    }

    /// @dev Regression (SC5a Task 4 fix): the SubAborted rendezvous must exclude the redeem-side
    /// USDC pot (`settledRedeemUSDC`), not just `heldEscrowUSDC`. Drives a settled redeem batch
    /// (settledRedeemUSDC = 100e6), so the contract's ENTIRE raw USDC balance is earmarked for
    /// redeemers, then bridges and aborts an unrelated subscribe batch. Pre-fix, `usdcFresh`
    /// (balance - heldEscrowUSDC only) would see the redeemers' 100e6 as "fresh" and let the abort
    /// rendezvous succeed with NONE of its own USDC having arrived -- a false positive that would
    /// double-reserve the same physical USDC into heldEscrowUSDC on top of the redeem pot
    /// (insolvency, spec §14).
    function test_subAborted_rendezvous_excludes_redeem_reserves() public {
        // epoch 1: bob's whole 100e6 redeem side bridges as redeem batch 1 -- fulfill and settle it
        _requestRedeem(bob, 100e6);
        rex.initiateSubEpoch();
        _deliverRedeemReturn(1, RequestKind.Redeem, 100e6);
        rex.settleRedeemBatch(1);
        assertEq(rex.settledRedeemUSDC(), 100e6);

        // the contract's whole USDC balance (100e6) is now earmarked for redeemers
        assertEq(usdc.balanceOf(address(rex)), 100e6);
        assertEq(rex.heldEscrowUSDC(), 0);

        // epoch 2: a fresh, unrelated subscribe bridges immediately
        usdc.mint(alice, 25e6);
        vm.startPrank(alice);
        usdc.approve(address(rex), 25e6);
        rex.requestDeposit(25e6);
        vm.stopPrank();
        warpToNextPeriod(rex); // ADR-025: one close per period
        rex.initiateSubEpoch();
        (uint8 subStatus,,) = rex.subBatch(1);
        assertEq(subStatus, uint8(BatchStatus.Bridged));

        // its own 25e6 has NOT arrived back yet -- only the redeemers' 100e6 sits in the contract.
        // Pre-fix, usdcFresh = 100e6 - heldEscrowUSDC(0) = 100e6 >= 25e6 would WRONGLY succeed.
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.SubAborted, amount: 25e6, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        vm.expectRevert(NotReadyToExecute.selector);
        rex.handle(PRUV_DOMAIN, _b32(executor), body);

        // the reverted attempt must not have latched or mutated any state
        (uint8 subStatusAfter,,) = rex.subBatch(1);
        assertEq(subStatusAfter, uint8(BatchStatus.Bridged));
        assertEq(rex.heldEscrowUSDC(), 0);

        // once its OWN 25e6 genuinely arrives, the identical instruction now succeeds
        usdc.mint(address(rex), 25e6);
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);

        (uint8 subStatusFinal,,) = rex.subBatch(1);
        assertEq(subStatusFinal, uint8(BatchStatus.Aborted));
        assertEq(rex.heldEscrowUSDC(), 25e6);
        // the redeemers' pot is untouched by the subscribe-side abort
        assertEq(rex.settledRedeemUSDC(), 100e6);
    }

    /// @dev SC5a Task 5, case 1 (Fulfilled): the payout is this epoch's slice of the batch's
    /// return, drawn from settledRedeemUSDC and fee'd once.
    function test_redeemClaim_fulfilled_paysNetMinusFee() public {
        rex = _deployFee(50); // 0.5%
        _requestRedeem(bob, 60e6); // the whole side is the net
        rex.initiateSubEpoch();
        _deliverRedeemReturn(1, RequestKind.Redeem, 60e6);
        rex.settleRedeemBatch(1);

        uint256 id = encodeId(CLASS_RED_EPOCH, 1);
        vm.prank(bob);
        rex.claim(id, 60e6);
        // gross 60e6, fee 0.5% = 300000, net 59_700_000
        assertEq(usdc.balanceOf(bob), 59_700_000);
        assertEq(usdc.balanceOf(address(0xFEE)), 300_000);
        assertEq(rex.settledRedeemUSDC(), 0);
    }

    /// @dev SC5a Task 5, case 2 (Aborted): the payout is the wRWA refund from settledUnclaimed --
    /// never fee'd.
    function test_redeemClaim_aborted_paysWrwaRefund_noFee() public {
        _requestRedeem(bob, 60e6);
        rex.initiateSubEpoch();
        _deliverRedeemReturn(1, RequestKind.RedeemAborted, 60e6);
        rex.settleRedeemBatch(1);

        uint256 id = encodeId(CLASS_RED_EPOCH, 1);
        vm.prank(bob);
        rex.claim(id, 60e6);
        assertEq(IERC20(address(wrwaRoute)).balanceOf(bob), 60e6); // wRWA back, untouched
        assertEq(rex.settledUnclaimed(), 0);
    }

    /// @dev SC5a Task 5, case 3 (Released): a below-min batch that never bridged pays its wRWA
    /// refund straight from liveRedeemEscrow, no fee. ADR-027 changed only how the batch reaches
    /// `Released` (wind-down, not an elapsed accrual cap); the claim branch under test is the same.
    function test_redeemClaim_released_paysWrwaRefund_fromLiveEscrow() public {
        uint256 id1 = _requestRedeem(bob, 30e6); // < MIN_REDEEM
        rex.initiateSubEpoch();

        _requestRedeem(bob, 5e6); // a second, never-initiated side: its escrow stays separate
        rex.triggerWindDown();
        vm.warp(block.timestamp + rex.windDownWindow() + 1);
        rex.releaseStaleRedeemBatch(1);
        (uint8 status,,,) = rex.redeemBatch(1);
        assertEq(status, 4); // BatchStatus.Released

        vm.prank(bob);
        rex.claim(id1, 30e6);
        assertEq(IERC20(address(wrwaRoute)).balanceOf(bob), 30e6);
        assertEq(rex.liveRedeemEscrow(), 5e6); // epoch 2's residual still escrowed, unclaimed
    }

    // ------------------------------------------------------------------------------------------
    // SC5a Task 8 -- named acceptance scenarios (spec 15, home portion).
    // ------------------------------------------------------------------------------------------

    /// @dev RS14 (multi-epoch batch allocation, ADR-015, spec 15): two epochs' below-min redeem
    /// residuals accrue into ONE batch that clears the minimum and bridges once, executes at a
    /// single nav1 (one returnedAmount), and each epoch's OWN holder claims a slice pro-rata to
    /// what THEIR epoch contributed. The Fulfilled analogue of
    /// test_redeem_belowMin_accrues_then_releases (which proves the same accrual for Released).
    /// An uneven returnedAmount forces a real epoch-level floor split, so "less dust" is not
    /// vacuous. Its first two epochs (bob's below-min 20e6 accrual, then r2 crossing MIN_REDEEM
    /// to bridge) also incidentally demonstrate RS5' (below-min residual accrues until it clears
    /// the minimum) on the redeem leg, so that scenario is not left silently unclaimed either.
    function test_redeemClaim_multiEpoch_fulfilled_sumsToReturnedLessDust() public {
        _requestRedeem(bob, 20e6); // epoch 1, < MIN_REDEEM -> batch 1 Accumulating
        rex.initiateSubEpoch();
        (uint8 s1, uint256 n1,,) = rex.redeemBatch(1);
        assertEq(s1, 1); // Accumulating
        assertEq(n1, 20e6);

        address r2 = makeAddr("r2");
        _requestRedeem(r2, 40e6); // epoch 2, pushes the SAME batch to 60e6 >= MIN_REDEEM -> bridges
        warpToNextPeriod(rex); // ADR-025: one close per period
        rex.initiateSubEpoch();
        (uint8 s2, uint256 n2,,) = rex.redeemBatch(1);
        assertEq(s2, 2); // Bridged
        assertEq(n2, 60e6, "one batch, two epochs' worth of residual");

        uint256 returnedAmount = 61_000_000; // nav1 uplift on the 60e6 net -> uneven epoch split
        _deliverRedeemReturn(1, RequestKind.Redeem, returnedAmount);
        rex.settleRedeemBatch(1);

        vm.prank(bob);
        rex.claim(encodeId(CLASS_RED_EPOCH, 1), 20e6); // epoch 1's own 20e6 slice of the 60e6 batch
        vm.prank(r2);
        rex.claim(encodeId(CLASS_RED_EPOCH, 2), 40e6); // epoch 2's own 40e6 slice

        uint256 bobPaid = usdc.balanceOf(bob);
        uint256 r2Paid = usdc.balanceOf(r2);
        assertEq(bobPaid, 20_333_333, "epoch 1's slice: floor(20e6 * 61e6 / 60e6)");
        assertEq(r2Paid, 40_666_666, "epoch 2's slice: floor(40e6 * 61e6 / 60e6)");
        assertEq(bobPaid + r2Paid, returnedAmount - 1, "slices sum to returnedAmount less 1 unit of dust");
        assertEq(rex.settledRedeemUSDC(), 1, "the floor dust stays reserved, unclaimed");
    }

    /// @dev RS11 (pro-rata uniformity, spec 8/14): two holders of the SAME RED_EPOCH id --
    /// entering at opposite ends of the still-open epoch -- settle at an identical rate.
    /// Unequal amounts (55e6 vs 65e6) plus a returnedAmount that does not divide evenly force
    /// real floor dust, so equality is asserted as a RATE (cross-multiplied), not an exact split.
    function test_redeemClaim_twoHolders_sameRate() public {
        uint256 id1 = _requestRedeem(bob, 55e6); // enters early in the epoch
        vm.warp(block.timestamp + 12 hours);
        address r2 = makeAddr("r2");
        uint256 id2 = _requestRedeem(r2, 65e6); // enters late, same still-open epoch
        assertEq(id1, id2, "same RED_EPOCH id");

        rex.initiateSubEpoch(); // 120e6 total >= MIN_REDEEM -> bridges as one batch, one epoch
        _deliverRedeemReturn(1, RequestKind.Redeem, 121_000_001); // uneven nav1 forces real dust
        rex.settleRedeemBatch(1);

        vm.prank(bob);
        rex.claim(id1, 55e6);
        vm.prank(r2);
        rex.claim(id2, 65e6);

        uint256 payoutBob = usdc.balanceOf(bob);
        uint256 payoutR2 = usdc.balanceOf(r2);
        assertGt(payoutBob, 0);
        assertGt(payoutR2, 0);
        assertApproxEqAbs(
            payoutBob * 65e6, payoutR2 * 55e6, 55e6 + 65e6, "two holders of one id settle at the same rate"
        );
    }

    /// @dev Redeem round trip, happy path (spec 7.3-7.6), proving the ledger-level conservation
    /// invariant (spec 14): nothing paid out, fee'd, or left as floor dust can exceed what was
    /// actually delivered by the fulfilled return. Two holders sharing one batch force real
    /// floor dust so the equation is not vacuously true; a nonzero redemptionFeeBps makes the
    /// blended claim's fee leg part of the same conserved total.
    function test_redeemRoundTrip_happy_conservesValue() public {
        rex = _deployFee(50); // 0.5% redemption fee
        address carol = makeAddr("carol");
        _requestRedeem(bob, 61e6);
        _requestRedeem(carol, 39e6); // same epoch, same batch (>= MIN_REDEEM once summed)
        rex.initiateSubEpoch();

        uint256 usdcDelivered = 62_500_001; // uneven nav1 so the per-holder split floors for real
        _deliverRedeemReturn(1, RequestKind.Redeem, usdcDelivered);
        rex.settleRedeemBatch(1);

        uint256 id = encodeId(CLASS_RED_EPOCH, 1);
        vm.prank(bob);
        rex.claim(id, 61e6);
        vm.prank(carol);
        rex.claim(id, 39e6);

        uint256 totalPaidOut = usdc.balanceOf(bob) + usdc.balanceOf(carol);
        uint256 totalFees = usdc.balanceOf(address(0xFEE));
        uint256 dust = rex.settledRedeemUSDC(); // floor remainder never assigned to a holder
        assertEq(dust, 1, "one holder-split floor: the n-1 dust bound, 1 for 2 holders");
        assertEq(totalPaidOut + totalFees + dust, usdcDelivered, "paid + fees + dust == vault-funded USDC");
        assertGt(totalFees, 0, "the fee leg is genuinely part of the conserved total");
    }
}
