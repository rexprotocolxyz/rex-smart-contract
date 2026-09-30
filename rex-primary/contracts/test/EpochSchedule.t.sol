// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Test} from "forge-std/Test.sol";
import {EpochSchedule} from "../src/EpochSchedule.sol";

contract EpochScheduleTest is Test {
    uint64 constant START = 1_800_000_000;
    uint64 constant DURATION = 30 days;
    EpochSchedule schedule;

    function setUp() public {
        schedule = new EpochSchedule(START, DURATION, DURATION);
    }

    function test_periodIsZeroBeforeStart() public view {
        assertEq(schedule.periodOf(START - 1), 0);
    }

    function test_periodOneAtStartAndThroughTheFirstWindow() public view {
        assertEq(schedule.periodOf(START), 1);
        assertEq(schedule.periodOf(START + DURATION - 1), 1);
    }

    function test_periodAdvancesOnTheGrid() public view {
        assertEq(schedule.periodOf(START + DURATION), 2);
        assertEq(schedule.periodOf(START + 11 * DURATION), 12);
    }

    function test_dueAtIsTheInverseOfPeriodOf() public view {
        assertEq(schedule.dueAt(1), START);
        assertEq(schedule.dueAt(12), START + 11 * DURATION);
        assertEq(schedule.periodOf(schedule.dueAt(7)), 7);
    }

    function test_dueAtZeroIsZero() public view {
        assertEq(schedule.dueAt(0), 0);
    }

    function test_constructorRejectsZeroStart() public {
        vm.expectRevert(EpochSchedule.InvalidSchedule.selector);
        new EpochSchedule(0, DURATION, DURATION);
    }

    function test_constructorRejectsZeroDuration() public {
        vm.expectRevert(EpochSchedule.InvalidSchedule.selector);
        new EpochSchedule(START, 0, 0);
    }

    /// A period is a half-open window [dueAt(p), dueAt(p+1)) for every p -- the property the
    /// REXPrimary gate relies on to close exactly once per period.
    function testFuzz_periodOfIsMonotonicAndHalfOpen(uint64 t) public view {
        vm.assume(t >= START && t < START + 4000 * DURATION);
        uint64 p = schedule.periodOf(t);
        assertGe(t, schedule.dueAt(p));
        assertLt(t, schedule.dueAt(p + 1));
    }

    function test_periodIfOpen_is_zero_outside_the_window() public {
        EpochSchedule w = new EpochSchedule(START, DURATION, 1 hours);
        assertEq(w.periodIfOpen(START - 1), 0);
        assertEq(w.periodIfOpen(START), 1);
        assertEq(w.periodIfOpen(START + 1 hours - 1), 1);
        assertEq(w.periodIfOpen(START + 1 hours), 0);
        assertEq(w.periodIfOpen(START + DURATION), 2);
    }

    function test_window_equal_to_duration_reproduces_periodOf() public view {
        for (uint64 t = START; t < START + 3 * DURATION; t += DURATION / 7) {
            assertEq(schedule.periodIfOpen(t), schedule.periodOf(t));
        }
    }

    function test_window_bounds() public {
        vm.expectRevert(EpochSchedule.InvalidSchedule.selector);
        new EpochSchedule(START, DURATION, 0);
        vm.expectRevert(EpochSchedule.InvalidSchedule.selector);
        new EpochSchedule(START, DURATION, DURATION + 1);
    }
}
