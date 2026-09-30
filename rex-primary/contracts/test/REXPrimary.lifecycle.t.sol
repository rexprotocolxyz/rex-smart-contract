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

contract REXPrimaryLifecycleTest is Test {
    MockMailbox mailbox;
    MockERC20 usdc;
    MockCollateralWarpRoute usdcRoute;
    MockSyntheticWarpRoute wrwaRoute;
    MockNavOracle navOracle;
    REXPrimary rex;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address executor = makeAddr("executor");
    uint32 constant PRUV_DOMAIN = 7336;
    uint64 START = uint64(block.timestamp + 1);

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
            START,
            1 days,
            0,
            0,
            makeAddr("fee"),
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
    }

    function test_subscribe_reverts_before_epoch_based() public {
        usdc.mint(alice, 10e6);
        vm.startPrank(alice);
        usdc.approve(address(rex), 10e6);
        vm.expectRevert(WrongLifecycleState.selector);
        rex.requestDeposit(10e6);
        vm.stopPrank();
    }

    function test_windDownWindow_configured() public view {
        assertEq(rex.windDownWindow(), 9 days); // setUp passes windDownWindow: 9 days
    }

    // ------------------------------------------------------------------------------------------
    // SC6b Task 2 -- per-leg outstanding batch counters.
    // ------------------------------------------------------------------------------------------

    /// @dev Reach EpochBased via a zero-raise vacuous launchpad close (launchpadMinimum == 0 in
    /// setUp), so no bridge plumbing / msg.value is needed. Mirrors REXPrimaryAccessTest.
    function _toEpochBased() internal {
        vm.warp(rex.launchpadStart() + rex.launchpadPeriod());
        rex.closeLaunchpad();
    }

    /// @dev Helper: request + initiateSubEpoch (minSub 0 in setUp -> bridges immediately).
    function _subscribeAndInitiate(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(rex), amount);
        rex.requestDeposit(amount);
        vm.stopPrank();
        rex.initiateSubEpoch();
    }

    /// @dev Helper: deliver a subscribe batch's covering wRWA + return instruction, then settle.
    function _settleSubBatch(uint64 batchId) internal {
        (, uint256 netIn,) = rex.subBatch(batchId);
        wrwaRoute.deliverTokens(_b32(address(rex)), netIn);
        bytes memory body = Codec.encode(
            Instruction({legId: batchId, kind: RequestKind.Subscribe, amount: netIn, navAtInitiate: 1e18})
        );
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
        rex.settleSubBatch(batchId);
    }

    /// @dev Helper: fund the returned USDC collateral, then deliver a SubAborted return (settles
    /// the batch to Aborted INLINE -- no separate settleSubBatch step, mirrors REXPrimaryAbortTest).
    function _abortSubBatch(uint64 batchId, uint256 amount) internal {
        usdc.mint(address(rex), amount); // simulate the unlocked USDC collateral arriving back
        bytes memory body = Codec.encode(
            Instruction({legId: batchId, kind: RequestKind.SubAborted, amount: amount, navAtInitiate: 1e18})
        );
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
    }

    function test_outstanding_tracks_nonterminal_batches() public {
        _toEpochBased();
        // one subscribe batch bridged (minSub 0 -> bridges immediately)
        _subscribeAndInitiate(alice, 100e6); // helper: request + initiateSubEpoch
        assertEq(rex.outstandingSubBatches(), 1);
        _settleSubBatch(1); // deliver return + settleSubBatch
        assertEq(rex.outstandingSubBatches(), 0); // Settled -> terminated
    }

    /// @dev Subscribe's abort IS its terminal (Bridged -> Aborted inline, no later settle step),
    /// so the counter must bump right there, at the SubAborted branch -- not anywhere else.
    function test_outstanding_subscribeAborted_countsAtAbortNotSettle() public {
        _toEpochBased();
        _subscribeAndInitiate(alice, 100e6);
        assertEq(rex.outstandingSubBatches(), 1);

        _abortSubBatch(1, 100e6);
        (uint8 status,,) = rex.subBatch(1);
        assertEq(status, uint8(BatchStatus.Aborted));
        assertEq(rex.outstandingSubBatches(), 0, "Aborted is terminal -- counted immediately");
    }

    /// @dev THE asymmetric case (constitution of this task): a redeem abort return only RECORDS
    /// (retKind = RedeemAborted, status stays Bridged) -- the batch is NOT terminal until the
    /// separate settleRedeemBatch call flips it to Settled. If the increment ever migrated to the
    /// record branch, this batch would be double-counted (once at record, once at settle) and a
    /// later shut-down gate would under-count outstanding batches.
    function test_outstanding_redeemAborted_staysOutstandingUntilSettle() public {
        _toEpochBased();
        wrwaRoute.deliverTokens(_b32(alice), 60e6);
        vm.startPrank(alice);
        IERC20(address(wrwaRoute)).approve(address(rex), 60e6);
        rex.requestRedeem(60e6); // minRedeem 0 in setUp -> bridges immediately
        vm.stopPrank();
        rex.initiateSubEpoch();
        assertEq(rex.outstandingRedeemBatches(), 1);

        // record the wRWA-refund (RedeemAborted) return: status stays Bridged, NOT terminal yet
        wrwaRoute.deliverTokens(_b32(address(rex)), 60e6);
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.RedeemAborted, amount: 60e6, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
        (uint8 statusAfterRecord,,,) = rex.redeemBatch(1);
        assertEq(statusAfterRecord, uint8(BatchStatus.Bridged), "record-only: not yet terminal");
        assertEq(rex.outstandingRedeemBatches(), 1, "must NOT decrement at record time");

        // settleRedeemBatch is the actual terminal write for BOTH retKinds (Redeem/RedeemAborted)
        rex.settleRedeemBatch(1);
        (uint8 statusAfterSettle,,,) = rex.redeemBatch(1);
        assertEq(statusAfterSettle, uint8(BatchStatus.Settled));
        assertEq(rex.outstandingRedeemBatches(), 0, "now terminated, exactly once");
    }

    /// @dev T1: settleRedeemBatch is permissionless once the return has recorded -- same
    /// rationale as settleSubBatch (no privileged decision; a dead keeper must not block it,
    /// including the shut-down gate that depends on outstandingRedeemBatches reaching 0).
    function test_settleRedeemBatch_by_non_keeper_succeeds() public {
        _toEpochBased();
        wrwaRoute.deliverTokens(_b32(alice), 60e6);
        vm.startPrank(alice);
        IERC20(address(wrwaRoute)).approve(address(rex), 60e6);
        rex.requestRedeem(60e6); // minRedeem 0 -> bridges immediately
        vm.stopPrank();
        rex.initiateSubEpoch();

        usdc.mint(address(rex), 60e6); // simulate the returned USDC collateral arriving
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Redeem, amount: 60e6, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);

        vm.prank(makeAddr("stranger"));
        rex.settleRedeemBatch(1);
        (uint8 status,,,) = rex.redeemBatch(1);
        assertEq(status, uint8(BatchStatus.Settled));
    }

    /// @dev Redeem's release path (below minRedeem, wind-down window elapsed -> Released, never
    /// bridged). Needs its own pool: setUp's shared `rex` has minRedeem == 0, so any redeem
    /// amount clears the minimum and bridges immediately, never accruing. ADR-027 left wind-down
    /// as the single trigger; what this test is about -- the counter moving at Released, not at
    /// creation -- is unchanged by which trigger got it there.
    function test_outstanding_redeemReleased_countsAtRelease() public {
        REXPrimary r = new REXPrimary(
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
            makeAddr("fee2"),
            SC3Params({
                navOracle: INavOracle(address(navOracle)),
                minRedeem: 50e6,
                redeemCancelFeeBps: 0,
                subFulfillTimeout: 10 days,
                redemptionFeeBps: 0,
                redeemFulfillTimeout: 10 days,
                windDownWindow: 9 days,
                schedule: perSecondSchedule()
            })
        );
        r.enrollRemote(PRUV_DOMAIN, _b32(executor));
        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad(); // vacuous close (minimum 0) -> EpochBased, no batch

        wrwaRoute.deliverTokens(_b32(alice), 20e6);
        vm.startPrank(alice);
        IERC20(address(wrwaRoute)).approve(address(r), 20e6);
        r.requestRedeem(20e6); // < minRedeem 50e6 -> accrues
        vm.stopPrank();
        r.initiateSubEpoch();
        assertEq(r.outstandingRedeemBatches(), 1, "batch created, still Accumulating -- outstanding");

        r.triggerWindDown();
        vm.warp(block.timestamp + r.windDownWindow() + 1);
        r.releaseStaleRedeemBatch(1);

        (uint8 status,,,) = r.redeemBatch(1);
        assertEq(status, uint8(BatchStatus.Released));
        assertEq(r.outstandingRedeemBatches(), 0, "1 created, 1 terminated (Released)");
    }

    /// @dev Subscribe's release path (below minSub, wind-down entered -> Released, never
    /// bridged). Needs its own pool with minSub > 0: the ctor requires launchpadMinimum >=
    /// minSub, so reaching EpochBased needs a REAL launchpad raise (not the vacuous zero-raise
    /// close), which itself bridges + settles as batch 1 -- the accrual/release under test then
    /// happens on batch 2.
    function test_outstanding_subscribeReleased_countsAtRelease() public {
        REXPrimary r = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            1000e6,
            uint64(block.timestamp + 1),
            1 days,
            1000e6,
            0,
            makeAddr("fee3"),
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
        r.enrollRemote(PRUV_DOMAIN, _b32(executor));

        // real launchpad raise -> bridges + settles as batch 1 (occupies it, out of the way)
        address seeder = makeAddr("lpSeeder");
        usdc.mint(seeder, 1000e6);
        vm.warp(r.launchpadStart());
        vm.startPrank(seeder);
        usdc.approve(address(r), 1000e6);
        r.depositToLaunchpad(1000e6);
        vm.stopPrank();
        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad();
        wrwaRoute.deliverTokens(_b32(address(r)), 1000e6);
        bytes memory body1 =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 1000e6, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        r.handle(PRUV_DOMAIN, _b32(executor), body1);
        r.settleSubBatch(1);
        assertEq(r.outstandingSubBatches(), 0, "batch 1 created and immediately settled");

        // epoch: alice deposits below minSub -> batch 2 stays Accumulating
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(r), 100e6);
        r.requestDeposit(100e6);
        vm.stopPrank();
        r.initiateSubEpoch();
        (uint8 status1,,) = r.subBatch(2);
        assertEq(status1, uint8(BatchStatus.Accumulating));
        assertEq(r.outstandingSubBatches(), 1, "batch 2 created, not yet terminal");

        // ADR-027: nothing expires on a clock, so wind-down is what releases this batch.
        r.triggerWindDown();
        (uint8 status2,,) = r.subBatch(2);
        assertEq(status2, uint8(BatchStatus.Released));
        assertEq(r.outstandingSubBatches(), 0, "2 created (batch 1 + 2), 2 terminated -> 0 outstanding");
    }

    // ------------------------------------------------------------------------------------------
    // The subscribe leg has no permissionless drain (ADR-027 removed it) -- `triggerWindDown` is
    // what clears this leg, and that is what keeps the shut-down gate reachable.
    // ------------------------------------------------------------------------------------------

    /// @dev A pool whose launchpad raise is already settled as batch 1, so the batch under test is
    /// batch 2. `minSub` is 1000e6 and the ctor requires `launchpadMinimum >= minSub`, so reaching
    /// `EpochBased` needs a real raise rather than the vacuous zero close.
    function _subPool(address feeRecipient_) internal returns (REXPrimary r) {
        r = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            1000e6,
            uint64(block.timestamp + 1),
            1 days,
            1000e6,
            0,
            feeRecipient_,
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
        r.enrollRemote(PRUV_DOMAIN, _b32(executor));

        address seeder = makeAddr("subPoolSeeder");
        usdc.mint(seeder, 1000e6);
        vm.warp(r.launchpadStart());
        vm.startPrank(seeder);
        usdc.approve(address(r), 1000e6);
        r.depositToLaunchpad(1000e6);
        vm.stopPrank();
        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad();
        wrwaRoute.deliverTokens(_b32(address(r)), 1000e6);
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 1000e6, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        r.handle(PRUV_DOMAIN, _b32(executor), body);
        r.settleSubBatch(1);
    }

    /// @dev Accrue `amount` from `who` into the open subscribe batch and close the epoch.
    function _depositAndClose(REXPrimary r, address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(r), amount);
        r.requestDeposit(amount);
        vm.stopPrank();
        warpToNextPeriod(r);
        r.initiateSubEpoch();
    }

    /// @dev Load-bearing for ADR-027. With the accrual caps gone, a subscribe batch below `minSub`
    /// accrues indefinitely -- so the ONLY thing that can still leave `outstandingSubBatches`
    /// stuck above 0 is wind-down finding one open. `triggerWindDown` releases it at entry, which
    /// is why this leg needs no drain of its own and why `triggerShutDown` stays reachable.
    /// Asserted here rather than assumed.
    function test_windDown_leaves_no_accumulating_subBatch() public {
        REXPrimary r = _subPool(makeAddr("fee-wd-sub"));
        _depositAndClose(r, alice, 100e6);
        assertEq(r.openSubBatchId(), 2);

        r.triggerWindDown();

        (uint8 status,,) = r.subBatch(2);
        assertEq(status, uint8(BatchStatus.Released), "wind-down entry already drained it");
        assertEq(r.openSubBatchId(), 0);
    }

    // ------------------------------------------------------------------------------------------
    // SC6b Task 3 -- widen the lifecycle gate (WindDown) + permissionless stale-redeem drain.
    // ------------------------------------------------------------------------------------------

    /// @dev Fresh pool reaching EpochBased via the vacuous zero-raise close, parameterized so
    /// tests can control minRedeem/windDownWindow independently of setUp's shared
    /// `rex` (which has minRedeem 0 -> every redeem bridges immediately, never accruing).
    /// @param minRedeem_ In **wRWA** (ADR-026 D2), compared against the batch's accrued wRWA with no
    /// price. This fixture's NAV is a fixed 1e18 and both mocks are 6-decimal, so every threshold
    /// here reads the same as it did under the old USDC-value gate.
    function _redeemPool(uint256 minRedeem_, uint64 windDownWindow_, address feeRecipient_)
        internal
        returns (REXPrimary r)
    {
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
                subFulfillTimeout: 10 days,
                redemptionFeeBps: 0,
                redeemFulfillTimeout: 10 days,
                windDownWindow: windDownWindow_,
                schedule: perSecondSchedule()
            })
        );
        r.enrollRemote(PRUV_DOMAIN, _b32(executor));
        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad(); // vacuous close (minimum 0) -> EpochBased, no batch
    }

    /// @dev Helper: mint wRWA to `who`, approve, requestRedeem on `r`.
    function _requestRedeem(REXPrimary r, address who, uint256 amount) internal {
        wrwaRoute.deliverTokens(_b32(who), amount);
        vm.startPrank(who);
        IERC20(address(wrwaRoute)).approve(address(r), amount);
        r.requestRedeem(amount);
        vm.stopPrank();
    }

    /// @dev BLOCKING-1 scenario: a stale below-min redeem batch drains with zero further inflow
    /// once wind-down's own grace window elapses -- without this, shut-down deadlocks forever.
    function test_staleRedeemBatch_releases_in_winddown_no_inflow() public {
        REXPrimary r = _redeemPool(100e6, 9 days, makeAddr("fee-stale"));

        _requestRedeem(r, bob, 40e6); // below minRedeem 100e6
        r.initiateSubEpoch(); // batch 1 created, Accumulating (below min, not bridged)
        assertEq(r.outstandingRedeemBatches(), 1);

        r.triggerWindDown();
        // no further inflow; without the fix this batch never releases and shut-down deadlocks
        vm.warp(block.timestamp + r.windDownWindow() + 1);
        r.releaseStaleRedeemBatch(1); // permissionless, window elapsed -> stale
        assertEq(r.outstandingRedeemBatches(), 0);
        (uint8 status,,,) = r.redeemBatch(1);
        assertEq(status, uint8(BatchStatus.Released));
    }

    /// @dev Finding 1 anti-grief: below-min redeem batch in wind-down, but the window
    /// NOR windDownWindow elapsed -> release must revert (redeem stays open, can still fill).
    function test_releaseStaleRedeemBatch_rejected_midWindow() public {
        REXPrimary r = _redeemPool(100e6, 9 days, makeAddr("fee-midwindow"));

        _requestRedeem(r, bob, 40e6); // below minRedeem 100e6
        r.initiateSubEpoch(); // batch 1 Accumulating, below min
        r.triggerWindDown(); // no warp: nothing stale yet
        vm.expectRevert(InvalidState.selector);
        r.releaseStaleRedeemBatch(1);
    }

    /// @dev The OTHER half of that gate, and the half nothing tested. ADR-027 left
    /// `releaseStaleRedeemBatch` with two clauses ANDed -- in wind-down, AND past the window -- but
    /// the second alone is vacuous outside wind-down, because `windDownStart` is 0 until
    /// `triggerWindDown` and any real chain clock is past `0 + windDownWindow`. So deleting the
    /// state clause turns a decommissioning valve into a permissionless "end anyone's accruing
    /// redeem position" button, and the suite could not see it: every fixture starts near t=1 and
    /// warps by days, never past the 9-day window, so the vacuous clause still held.
    ///
    /// Asserted at a REALISTIC timestamp, which is the whole point of the test.
    function test_releaseStaleRedeemBatch_rejected_outsideWindDown() public {
        REXPrimary r = _redeemPool(100e6, 9 days, makeAddr("fee-epochbased"));
        _requestRedeem(r, bob, 40e6);
        r.initiateSubEpoch(); // batch 1 Accumulating, below min, pool still EpochBased

        vm.warp(1_800_000_000); // ~2027 — far past windDownWindow, which is 0 + 9 days here
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(InvalidState.selector);
        r.releaseStaleRedeemBatch(1);

        (uint8 status,,,) = r.redeemBatch(1);
        assertEq(status, uint8(BatchStatus.Accumulating), "a live accruing batch was drained");
    }

    /// @dev The guard widens to accept EpochBased + WindDown. ShutDown itself is Task 5 (RS9),
    /// so the reject half here proves the guard still rejects a state outside that pair --
    /// Initialized (pre-launchpad-close) is the only such state reachable this early.
    function test_requestRedeem_allowed_in_winddown_rejected_in_shutdown() public {
        _toEpochBased();
        rex.triggerWindDown();
        wrwaRoute.deliverTokens(_b32(alice), 10e6);
        vm.startPrank(alice);
        IERC20(address(wrwaRoute)).approve(address(rex), 10e6);
        rex.requestRedeem(10e6); // succeeds in WindDown
        vm.stopPrank();
        uint256 id = encodeId(CLASS_RED_EPOCH, rex.currentEpochId());
        assertEq(rex.balanceOf(alice, id), 10e6, "redeem receipt minted in WindDown");

        // Task 5: RS9 adds the ShutDown-specific reject. `rex` is already past Initialized (and
        // now in WindDown), so prove the reject half on a brand-new, still-Initialized instance.
        REXPrimary notLaunched = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            0,
            uint64(block.timestamp + 1 days),
            1 days,
            0,
            0,
            makeAddr("fee-notlaunched"),
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
        vm.expectRevert(WrongLifecycleState.selector);
        notLaunched.requestRedeem(1e6);
    }

    /// @dev Spec §7.7 step 3: subscribe is OFF in wind-down. A deposit made in an epoch BEFORE
    /// triggerWindDown, still unbridged when initiateSubEpoch next runs, must NOT open a
    /// subscribe batch -- while the redeem side (unaffected) still processes normally.
    function test_initiateSubEpoch_windDown_forces_subscribe_side_zero() public {
        _toEpochBased();
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(rex), 100e6);
        rex.requestDeposit(100e6); // deposited into the CURRENT epoch, not yet initiated
        vm.stopPrank();

        rex.triggerWindDown(); // wind-down triggers before this epoch's initiateSubEpoch

        wrwaRoute.deliverTokens(_b32(bob), 60e6);
        vm.startPrank(bob);
        IERC20(address(wrwaRoute)).approve(address(rex), 60e6);
        rex.requestRedeem(60e6); // redeem side still accepted in WindDown
        vm.stopPrank();

        uint64 subBatchesBefore = rex.nextSubBatchId();
        uint64 redeemBatchesBefore = rex.nextRedeemBatchId();
        rex.initiateSubEpoch();
        assertEq(rex.nextSubBatchId(), subBatchesBefore, "no subscribe batch opened in WindDown");
        assertEq(rex.outstandingSubBatches(), 0, "S forced to 0 -> subscribe side untouched");
        // redeem side (minRedeem 0 in setUp) is unaffected by the S=0 force -- it still opens and
        // bridges its own batch normally (Bridged is non-terminal, so it stays "outstanding").
        assertEq(rex.nextRedeemBatchId(), redeemBatchesBefore + 1, "redeem side still processed");
        assertEq(rex.outstandingRedeemBatches(), 1, "bridged redeem batch is outstanding until settled");
    }

    // ------------------------------------------------------------------------------------------
    // SC6b Task 4 -- triggerWindDown release of the open below-min sub batch + 100% subscriber
    // refund on cancel.
    // ------------------------------------------------------------------------------------------

    function test_triggerWindDown_disables_subscribe_keeps_redeem() public {
        _toEpochBased();
        rex.triggerWindDown();
        assertEq(uint8(rex.state()), uint8(REXPrimary.LifecycleState.WindDown));

        usdc.mint(address(this), 1e6);
        usdc.approve(address(rex), 1e6);
        vm.expectRevert(WrongLifecycleState.selector);
        rex.requestDeposit(1e6); // subscribe off

        _requestRedeem(rex, bob, 10e6); // redeem still on
    }

    function test_unlocked_subscriber_refunded_100pct_in_winddown() public {
        _toEpochBased();
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(rex), 100e6);
        uint256 id = rex.requestDeposit(100e6); // unlocked SUB_EPOCH position
        vm.stopPrank();

        rex.triggerWindDown();

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        rex.cancelRequest(id, 100e6);
        assertEq(usdc.balanceOf(alice) - before, 100e6); // no cancel fee
    }

    /// @dev Finding 2: a below-MIN_SUB subscribe batch open (Accumulating, locked) at wind-down
    /// is released at entry -> it no longer blocks the shut-down gate, and its holder reclaims
    /// USDC via the Released branch of `claim`. Needs its own pool with minSub > the deposit
    /// (setUp's shared `rex` has minSub 0, where every deposit bridges immediately) -- mirrors
    /// `test_outstanding_subscribeReleased_countsAtRelease`.
    function test_belowMinSubBatch_released_at_windDown_entry() public {
        REXPrimary r = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            1000e6,
            uint64(block.timestamp + 1),
            1 days,
            1000e6,
            0,
            makeAddr("fee-windDownRelease"),
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
        r.enrollRemote(PRUV_DOMAIN, _b32(executor));

        // real launchpad raise -> bridges + settles as batch 1 (occupies it, out of the way)
        address seeder = makeAddr("lpSeeder-windDownRelease");
        usdc.mint(seeder, 1000e6);
        vm.warp(r.launchpadStart());
        vm.startPrank(seeder);
        usdc.approve(address(r), 1000e6);
        r.depositToLaunchpad(1000e6);
        vm.stopPrank();
        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad();
        wrwaRoute.deliverTokens(_b32(address(r)), 1000e6);
        bytes memory body1 =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 1000e6, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        r.handle(PRUV_DOMAIN, _b32(executor), body1);
        r.settleSubBatch(1);
        assertEq(r.outstandingSubBatches(), 0, "batch 1 created and immediately settled");

        // alice deposits below minSub -> batch 2 stays Accumulating (locked once initiated)
        usdc.mint(alice, 40e6);
        vm.startPrank(alice);
        usdc.approve(address(r), 40e6);
        uint256 id = r.requestDeposit(40e6);
        vm.stopPrank();
        r.initiateSubEpoch();
        assertEq(r.outstandingSubBatches(), 1, "batch 2 created, not yet terminal");

        r.triggerWindDown(); // releases the below-min sub batch at entry
        assertEq(r.outstandingSubBatches(), 0, "no longer blocks the shut-down gate");

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        r.claim(id, 40e6); // Released branch of _claim refunds USDC
        assertEq(usdc.balanceOf(alice) - before, 40e6);
    }

    // ------------------------------------------------------------------------------------------
    // SC6b Task 5 -- triggerShutDown + the parallel-aware gate.
    // ------------------------------------------------------------------------------------------

    /// @dev Helper: deliver a redeem batch's covering USDC return (fulfilled, retKind Redeem),
    /// then settle. Mirrors `_settleSubBatch`'s subscribe twin; the redeem-only e2e
    /// (`RedeemRoundTrip.t.sol`) seeds `usdcRoute` with `deal` since it never subscribes first --
    /// here `usdc.mint` does the same job, consistent with this file's minting style.
    function _fulfillRedeemBatch(uint64 batchId, uint256 amount) internal {
        usdc.mint(address(usdcRoute), amount); // simulate the issuer-sold USDC arriving back
        usdcRoute.deliverTokens(_b32(address(rex)), amount);
        bytes memory body =
            Codec.encode(Instruction({legId: batchId, kind: RequestKind.Redeem, amount: amount, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
        rex.settleRedeemBatch(batchId);
    }

    function test_triggerShutDown_refused_before_window() public {
        _toEpochBased();
        rex.triggerWindDown();
        vm.expectRevert(WindDownNotComplete.selector);
        rex.triggerShutDown();
    }

    function test_triggerShutDown_refused_while_batch_outstanding() public {
        _toEpochBased();
        _subscribeAndInitiate(alice, 100e6); // batch 1 Bridged (outstanding)

        vm.expectRevert(WrongLifecycleState.selector);
        rex.triggerShutDown(); // not even in WindDown yet

        rex.triggerWindDown();
        vm.warp(block.timestamp + rex.windDownWindow() + 1);
        vm.expectRevert(WindDownNotComplete.selector); // window elapsed BUT batch 1 still Bridged
        rex.triggerShutDown();

        _settleSubBatch(1); // now terminal
        rex.triggerShutDown();
        assertEq(uint8(rex.state()), uint8(REXPrimary.LifecycleState.ShutDown));
    }

    /// @dev RS9 acceptance: subscribe round-trip -> wind-down -> an unlocked subscriber refunds
    /// 100% -> redeem stays open through the window and drains to terminal -> window elapses ->
    /// shut-down -> a settled-but-unclaimed holder still claims in ShutDown.
    function test_RS9_full_lifecycle_to_shutdown() public {
        address carol = makeAddr("carol");
        address dave = makeAddr("dave");
        _toEpochBased();

        // Subscribe round-trip: alice's deposit (epoch 1) bridges + settles, but she does NOT
        // claim yet -- proving claim still works post-ShutDown is the whole point below.
        uint256 idAliceSub = encodeId(CLASS_SUB_EPOCH, rex.currentEpochId());
        _subscribeAndInitiate(alice, 100e6); // batch 1 sub Bridged, epoch -> 2
        _settleSubBatch(1); // Settled, terminal

        // Bob redeems in epoch 2, drains to terminal before wind-down even starts.
        _requestRedeem(rex, bob, 60e6);
        warpToNextPeriod(rex); // ADR-025: one close per period
        rex.initiateSubEpoch(); // redeem batch 1 Bridged (minRedeem 0), epoch -> 3
        _fulfillRedeemBatch(1, 60e6);

        // Carol deposits (unlocked, epoch 3) -- never initiated -- then wind-down turns subscribe
        // off and she reclaims 100%, no cancel fee (Task 4).
        uint256 idCarolSub = encodeId(CLASS_SUB_EPOCH, rex.currentEpochId());
        usdc.mint(carol, 40e6);
        vm.startPrank(carol);
        usdc.approve(address(rex), 40e6);
        rex.requestDeposit(40e6);
        vm.stopPrank();

        rex.triggerWindDown();
        assertEq(uint8(rex.state()), uint8(REXPrimary.LifecycleState.WindDown));

        uint256 carolBefore = usdc.balanceOf(carol);
        vm.prank(carol);
        rex.cancelRequest(idCarolSub, 40e6);
        assertEq(usdc.balanceOf(carol) - carolBefore, 40e6, "unlocked subscriber refunded 100%");

        // RS9: redeem stays open through the window -- dave redeems mid-wind-down and it must
        // drain to terminal before shut-down is reachable.
        _requestRedeem(rex, dave, 25e6);
        warpToNextPeriod(rex); // ADR-025: one close per period
        rex.initiateSubEpoch(); // redeem batch 2 Bridged (minRedeem 0 -> bridges immediately)
        assertEq(rex.outstandingRedeemBatches(), 1);

        vm.warp(block.timestamp + rex.windDownWindow() + 1);
        vm.expectRevert(WindDownNotComplete.selector); // window elapsed BUT dave's batch still Bridged
        rex.triggerShutDown();

        _fulfillRedeemBatch(2, 25e6);
        assertEq(rex.outstandingRedeemBatches(), 0);
        assertEq(rex.outstandingSubBatches(), 0);

        rex.triggerShutDown();
        assertEq(uint8(rex.state()), uint8(REXPrimary.LifecycleState.ShutDown));

        // A SETTLED-but-unclaimed subscribe position from before shut-down still claims now.
        uint256 aliceBefore = IERC20(address(wrwaRoute)).balanceOf(alice);
        vm.prank(alice);
        rex.claim(idAliceSub, 100e6);
        assertEq(IERC20(address(wrwaRoute)).balanceOf(alice) - aliceBefore, 100e6, "claim still works in ShutDown");
    }
}
