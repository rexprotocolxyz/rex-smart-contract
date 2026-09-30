// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The epoch calendar (ADR-025). FROZEN. Both members are PURE VIEWS by design: a mutating
/// advance would have to be REXPrimary-only, which needs the schedule to know REXPrimary's address
/// while REXPrimary needs the schedule's -- an unresolvable deploy cycle -- and it would add an
/// access-control surface to grief. The "where are we" counter therefore lives in REXPrimary
/// (`lastClosedPeriod`).
///
/// A swap changes the calendar's SHAPE, and it CAN invalidate our POSITION -- that is the hazard, not
/// a guarantee against it. `lastClosedPeriod` is an absolute index into the grid you are permitted to
/// replace, so a coarser new grid can put `dueAt(lastClosedPeriod + 1)` decades away and stall the
/// trigger with no way to rebase the counter. `REXPrimary.applySchedule` refuses exactly those swaps
/// (`ScheduleWouldStrand`, bounded by `SCHEDULE_SWAP_HORIZON`); the consequence for operators is that
/// a coarsening swap must anchor its `epochStart` far enough in the PAST that the new grid's current
/// period already exceeds `lastClosedPeriod`.
interface IEpochSchedule {
    /// @notice The period index containing `timestamp`; 0 before the schedule starts.
    function periodOf(uint64 timestamp) external view returns (uint64);

    /// @notice The period containing `timestamp` if `timestamp` is inside that period's window
    /// (`dueAt(p) <= timestamp < dueAt(p) + windowLength`), else 0 (ADR-029). The epoch trigger uses this.
    function periodIfOpen(uint64 timestamp) external view returns (uint64);

    /// @notice The moment period `period` opens. `dueAt(1) == epochStart`. Used by BE/ops for the
    /// next-close display AND on chain by `REXPrimary.applySchedule`, which compares
    /// `dueAt(lastClosedPeriod + 1)` against `SCHEDULE_SWAP_HORIZON` to refuse a stranding swap. The
    /// epoch trigger itself uses `periodIfOpen` only.
    function dueAt(uint64 period) external view returns (uint64);
}
