// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./helpers/World.sol";
import {EpochSchedule} from "../src/EpochSchedule.sol";

/// @notice SC13 R13 -- ADR-029: a close is admissible only inside its period's window.
contract REXPrimaryWindowTest is World, DefaultConfig {
    address internal alice = makeAddr("alice");

    function test_R13_trigger_only_inside_the_window() public {
        uint64 start = uint64(vm.getBlockTimestamp()) + 1 days;
        EpochSchedule w = new EpochSchedule(start, 1 days, 1 hours);
        rex.setSchedule(IEpochSchedule(address(w)));
        vm.warp(vm.getBlockTimestamp() + rex.CONFIG_TIMELOCK());
        rex.applySchedule();

        _subscribe(alice, _usd(10));
        vm.warp(w.dueAt(3) + 1 hours); // just after period 3's window
        vm.expectRevert(TooEarly.selector);
        rex.initiateSubEpoch();

        vm.warp(w.dueAt(4) + 30 minutes); // inside period 4's window; period 3 was skipped
        rex.initiateSubEpoch();
        assertEq(rex.lastClosedPeriod(), 4);

        _subscribe(alice, _usd(10));
        vm.expectRevert(TooEarly.selector);
        rex.initiateSubEpoch(); // one close per period
    }
}
