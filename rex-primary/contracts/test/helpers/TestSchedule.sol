// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Vm} from "forge-std/Vm.sol";
import {IEpochSchedule} from "@rex-shared/IEpochSchedule.sol";
import {EpochSchedule} from "../../src/EpochSchedule.sol";
import {REXPrimary} from "../../src/REXPrimary.sol";

/// @dev Cheatcode handle for the free functions below (they are not inside a `Test` contract, so
/// they cannot use its `vm`). Named `hevm` so importing them never shadows a suite's own `vm`.
Vm constant hevm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

/// @notice A one-second epoch grid for the suites that predate ADR-025's schedule gate.
/// `periodOf(t) == t`, so exactly one `initiateSubEpoch` per timestamp is admitted -- which is the
/// behaviour those suites were written against, and it keeps each of them on its own subject
/// (bridging, settlement, aborts, fees, lifecycle) instead of re-testing the calendar.
/// The gate's real discrimination -- the floor, one close per period, and a skipped period not
/// producing a burst -- is proven against a realistic calendar in `REXPrimary.schedule.t.sol`.
function perSecondSchedule() returns (IEpochSchedule) {
    return IEpochSchedule(address(new EpochSchedule(1, 1, 1)));
}

/// @notice Step the clock to the moment `r`'s next epoch close is due, if it is not due already.
/// @dev Two deliberate details. (1) The moment is DERIVED from the contract (`schedule`,
/// `lastClosedPeriod`), so this stays correct whatever grid a fixture deploys. (2) The clock is
/// read with `vm.getBlockTimestamp()` and never as `block.timestamp`: under `via_ir` + the
/// optimizer solc treats `TIMESTAMP` as common-subexpression-eliminable across external calls
/// (true on a real chain, false for `vm.warp`), so a plain `vm.warp(block.timestamp + 1)` can
/// silently reuse a read taken BEFORE an earlier warp. That is not hypothetical -- it is what
/// made four suites revert `TooEarly` while their source looked right.
function warpToNextPeriod(REXPrimary r) {
    uint64 due = r.schedule().dueAt(r.lastClosedPeriod() + 1);
    if (hevm.getBlockTimestamp() < due) hevm.warp(due);
}

/// @notice Advance the clock by `delta`, read through the cheatcode (see `warpToNextPeriod`).
function warpBy(uint256 delta) {
    hevm.warp(hevm.getBlockTimestamp() + delta);
}
