// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {REXPrimaryTestBase} from "./REXPrimary.redeem.t.sol";
import {EpochSchedule} from "../src/EpochSchedule.sol";
import {IEpochSchedule} from "@rex-shared/IEpochSchedule.sol";
import {TooEarly, InvalidState, TimelockNotElapsed, ScheduleWouldStrand} from "@rex-shared/Errors.sol";
import {warpToNextPeriod, warpBy} from "./helpers/TestSchedule.sol";

/// @notice ADR-025: the epoch trigger is permissionless and gated on a schedule contract instead
/// of a keeper address. The base fixture's calendar is a real grid (`EPOCH_DURATION`, first moment
/// one period after the launchpad closes), so every assertion here can be made from BOTH sides of
/// the gate -- a suite that only ever called at an admitted moment would prove nothing.
contract REXPrimaryScheduleTest is REXPrimaryTestBase {
    address executor = makeAddr("scheduleExecutor");

    receive() external payable {}

    /// @dev The gated calls below reach the bridge (`minSub` is 0 in this fixture, and the
    /// wind-down test redeems above `minRedeem`), so the mocks need a zero fee quote and an
    /// enrolled remote. Nothing here touches the gate itself.
    function setUp() public override {
        super.setUp();
        mailbox.setQuoteFee(0);
        usdcRoute.setGasQuote(0);
        wrwaRoute.setGasQuote(0);
        rex.enrollRemote(PRUV_DOMAIN, bytes32(uint256(uint160(executor))));
    }

    function test_revertsBeforeTheScheduledMoment() public {
        _requestDeposit(alice, 100e6);
        vm.warp(schedule.dueAt(1) - 1);
        vm.expectRevert(TooEarly.selector);
        rex.initiateSubEpoch();
    }

    function test_succeedsAtTheScheduledMoment() public {
        _requestDeposit(alice, 100e6);
        vm.warp(schedule.dueAt(1));
        rex.initiateSubEpoch();
        assertEq(rex.lastClosedPeriod(), 1);
    }

    function test_theGateIsAFloorAndStaysOpenIndefinitely() public {
        // ADR-025 D2. Built as a WINDOW, one hour of stale NAV or a stuck bridge would cost a whole
        // period; as a FLOOR the trigger can wait out the problem.
        _requestDeposit(alice, 100e6);
        vm.warp(schedule.dueAt(1) + 900 days);
        rex.initiateSubEpoch();
        assertGt(rex.lastClosedPeriod(), 1);
    }

    function test_exactlyOneClosePerPeriod() public {
        _requestDeposit(alice, 100e6);
        vm.warp(schedule.dueAt(2));
        rex.initiateSubEpoch();
        // Fresh inflow, so the second call fails on the GATE and not on `NothingToSettle` -- the
        // whole point of the assertion is that it is the period floor that rejects it.
        _requestDeposit(bob, 100e6);
        vm.expectRevert(TooEarly.selector);
        rex.initiateSubEpoch();
    }

    /// @dev The gate is a FLOOR, so this must hold anywhere inside the closed period, not just at
    /// its opening moment: one second before the NEXT moment is still the same period.
    function test_exactlyOneClosePerPeriod_anywhereInsideIt() public {
        _requestDeposit(alice, 100e6);
        vm.warp(schedule.dueAt(2));
        rex.initiateSubEpoch();
        _requestDeposit(bob, 100e6);
        vm.warp(schedule.dueAt(3) - 1);
        vm.expectRevert(TooEarly.selector);
        rex.initiateSubEpoch();
    }

    function test_aSkippedPeriodDoesNotProduceABurst() public {
        // The failure mode this design exists to avoid: if the floor were keyed on epoch id, a
        // skipped period would leave every later epoch's moment already in the past and epochs
        // 6, 7 and 8 could close back-to-back in one afternoon.
        _requestDeposit(alice, 100e6);
        vm.warp(schedule.dueAt(11)); // periods 1-10 skipped
        rex.initiateSubEpoch();
        assertEq(rex.lastClosedPeriod(), 11);

        _requestDeposit(bob, 100e6);
        vm.warp(schedule.dueAt(12) - 1);
        vm.expectRevert(TooEarly.selector);
        rex.initiateSubEpoch();

        vm.warp(schedule.dueAt(12));
        rex.initiateSubEpoch();
        assertEq(rex.lastClosedPeriod(), 12);
    }

    /// @dev The counter records the period we are IN, never the epoch we just closed: the epoch id
    /// advanced 1 -> 2 while the period jumped straight to 11. Keyed on epoch id instead, every
    /// later epoch's moment would already be in the past and the burst above would be admitted.
    function test_thePeriodCounterIsTimeDerivedNotEpochDerived() public {
        _requestDeposit(alice, 100e6);
        vm.warp(schedule.dueAt(11));
        rex.initiateSubEpoch();
        assertEq(rex.currentEpochId(), 2, "epoch id advances by one");
        assertEq(rex.lastClosedPeriod(), 11, "the period comes from the clock, not the epoch id");
    }

    function test_theGateIsSkippedInWindDown() public {
        // Spec section 7.7 step 3 keeps redemption OPEN while subscribe is off, so in wind-down
        // initiateSubEpoch has one job: move redeem flow toward the exit. A 30-day gate would
        // stretch a wind-down across months for no benefit -- the calendar batches INFLOW, and in
        // wind-down there is none.
        _requestRedeem(alice, 10e18);
        vm.prank(owner);
        rex.triggerWindDown();
        vm.warp(schedule.dueAt(1) - 1); // before the first scheduled moment
        rex.initiateSubEpoch();
    }

    /// @dev The carve-out is a SKIP, not a reset: it must leave `lastClosedPeriod` alone (so a
    /// wind-down cannot silently arm an extra close) and it must be repeatable within one period,
    /// which is exactly what "the calendar has nothing left to do here" means.
    function test_theWindDownCarveOutNeitherAdvancesNorConsumesThePeriod() public {
        _requestDeposit(alice, 100e6);
        vm.warp(schedule.dueAt(1));
        rex.initiateSubEpoch();
        assertEq(rex.lastClosedPeriod(), 1);

        vm.prank(owner);
        rex.triggerWindDown();

        _requestRedeem(alice, 10e18);
        rex.initiateSubEpoch(); // same period as the close above -- gated, this would be TooEarly
        _requestRedeem(bob, 10e18);
        rex.initiateSubEpoch(); // and again, still the same period
        assertEq(rex.lastClosedPeriod(), 1, "the carve-out must not touch the counter");
    }

    function test_initiateIsPermissionless() public {
        _requestDeposit(alice, 100e6);
        vm.warp(schedule.dueAt(1));
        vm.prank(address(0xBEEF)); // nobody in particular
        rex.initiateSubEpoch();
        assertEq(rex.lastClosedPeriod(), 1);
    }

    function test_setScheduleIsTimelockedAndTakesEffectOnlyOnApply() public {
        EpochSchedule next = new EpochSchedule(uint64(block.timestamp + 1 days), 7 days, 7 days);
        vm.prank(owner);
        rex.setSchedule(IEpochSchedule(address(next)));
        assertEq(address(rex.schedule()), address(schedule), "took effect before applySchedule");

        vm.prank(owner);
        vm.expectRevert(TimelockNotElapsed.selector);
        rex.applySchedule();

        vm.warp(block.timestamp + rex.CONFIG_TIMELOCK());
        vm.prank(owner);
        rex.applySchedule();
        assertEq(address(rex.schedule()), address(next));
    }

    /// @dev ADR-025 decision 4: a swap changes the calendar's SHAPE and never our POSITION in it.
    /// The counter therefore survives `applySchedule` untouched, and the next close is judged by
    /// the NEW grid against that same floor.
    function test_swappingTheScheduleKeepsOurPositionInIt() public {
        _requestDeposit(alice, 100e6);
        vm.warp(schedule.dueAt(3));
        rex.initiateSubEpoch();
        assertEq(rex.lastClosedPeriod(), 3);

        // A grid whose period 3 is still in the future: the floor must keep rejecting until the
        // NEW calendar has moved past period 3, rather than re-opening because the shape changed.
        EpochSchedule next = new EpochSchedule(uint64(block.timestamp) + 10 days, 10 days, 10 days);
        vm.prank(owner);
        rex.setSchedule(IEpochSchedule(address(next)));
        vm.warp(block.timestamp + rex.CONFIG_TIMELOCK());
        vm.prank(owner);
        rex.applySchedule();
        assertEq(rex.lastClosedPeriod(), 3, "a swap must not move the counter");

        _requestDeposit(bob, 100e6);
        vm.warp(next.dueAt(3));
        vm.expectRevert(TooEarly.selector); // period 3 again -- already closed
        rex.initiateSubEpoch();

        vm.warp(next.dueAt(4));
        rex.initiateSubEpoch();
        assertEq(rex.lastClosedPeriod(), 4);
    }

    /// C1 (whole-branch review): a swap to a COARSER grid used to brick initiateSubEpoch forever.
    /// `lastClosedPeriod` indexes the OLD grid; the gate compares it against the NEW grid's index,
    /// and those are not the same scale. Closing in period N on a fine grid then swapping to a
    /// coarse one left the stored index unreachable, with no setter and no later swap able to
    /// recover it -- only triggerWindDown (terminate the fund) or a redeploy that strands receipts.
    function test_applyScheduleRefusesACoarseningSwapThatWouldStrandUs() public {
        // Close at a HIGH index on the fine grid, which is what makes the swap unrecoverable: a
        // small index coarsens harmlessly (30 days out is well inside the horizon), so the hazard
        // needs many fine periods already behind us. This is the reviewer's own 1-day/period-400 case.
        _requestDeposit(alice, 100e6);
        vm.warp(schedule.dueAt(400));
        rex.initiateSubEpoch();
        uint64 closed = rex.lastClosedPeriod();
        assertEq(closed, 400, "premise: a high fine-grained index");

        // The same origin on a 30-day grid puts period 401 roughly 32 years out.
        EpochSchedule coarse = new EpochSchedule(schedule.epochStart(), 30 days, 30 days);
        assertGt(
            coarse.dueAt(closed + 1),
            uint64(vm.getBlockTimestamp()) + rex.SCHEDULE_SWAP_HORIZON(),
            "premise: the next close is beyond the horizon"
        );

        vm.prank(owner);
        rex.setSchedule(IEpochSchedule(address(coarse)));
        warpBy(rex.CONFIG_TIMELOCK());
        vm.prank(owner);
        vm.expectRevert(ScheduleWouldStrand.selector);
        rex.applySchedule();

        // The old calendar is still in force, so the trigger still works.
        assertEq(address(rex.schedule()), address(schedule));
    }

    /// The degenerate EpochSchedule(1, 1) shape is the sharp case: its first close stores
    /// block.timestamp, after which only a one-second grid could ever advance the counter again.
    /// "Set the duration to 1 to unblock the gate" is an obvious operational reflex, so refuse it.
    function test_applyScheduleRefusesTheDegenerateOneSecondGridAfterAClose() public {
        _requestDeposit(alice, 100e6);
        warpToNextPeriod(rex);
        rex.initiateSubEpoch();

        EpochSchedule perSecond = new EpochSchedule(1, 1, 1);
        // periodOf here is ~block.timestamp, which is ABOVE lastClosedPeriod, so this direction is
        // allowed -- it is the swap BACK to any coarser grid that is then permanently refused.
        vm.prank(owner);
        rex.setSchedule(IEpochSchedule(address(perSecond)));
        warpBy(rex.CONFIG_TIMELOCK());
        vm.prank(owner);
        rex.applySchedule();
        _requestDeposit(bob, 100e6);
        rex.initiateSubEpoch();
        assertEq(rex.lastClosedPeriod(), uint64(vm.getBlockTimestamp()), "counter is now timestamp-scaled");

        EpochSchedule coarse = new EpochSchedule(1, 30 days, 30 days);
        assertGt(
            coarse.dueAt(rex.lastClosedPeriod() + 1),
            uint64(vm.getBlockTimestamp()) + rex.SCHEDULE_SWAP_HORIZON(),
            "premise: a timestamp-scaled counter puts any coarse grid astronomically far out"
        );
        vm.prank(owner);
        rex.setSchedule(IEpochSchedule(address(coarse)));
        warpBy(rex.CONFIG_TIMELOCK());
        vm.prank(owner);
        vm.expectRevert(ScheduleWouldStrand.selector);
        rex.applySchedule();
    }

    function test_setScheduleRejectsZero() public {
        vm.prank(owner);
        vm.expectRevert(InvalidState.selector);
        rex.setSchedule(IEpochSchedule(address(0)));
    }

    function test_applyWithNothingPendingReverts() public {
        vm.prank(owner);
        vm.expectRevert(InvalidState.selector);
        rex.applySchedule();
    }

    function test_onlyOwnerMayProposeOrApply() public {
        vm.prank(alice);
        vm.expectRevert();
        rex.setSchedule(IEpochSchedule(address(schedule)));
        vm.prank(alice);
        vm.expectRevert();
        rex.applySchedule();
    }
}
