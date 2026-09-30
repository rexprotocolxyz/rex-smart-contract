// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IEpochSchedule} from "@rex-shared/IEpochSchedule.sol";

/// @notice The epoch calendar (ADR-025). Immutable, stateless, no owner -- versioned by
/// redeployment like everything else here (ADR-011). It answers WHEN, never HOW MUCH: a wrong or
/// hostile schedule can make epochs trigger early, late or never, but cannot misprice and cannot move funds -- the SAFETY half of that framing is exact. But the
/// "can do no worse than stall" half is NOT: a swap to a coarser grid can leave
/// `lastClosedPeriod` (an index into the OLD grid) unreachable on the NEW one, which is a
/// PERMANENT, unrecoverable stall of the only path funds take to Pruv -- a different risk
/// class from a stall. `applySchedule` refuses exactly those swaps (`ScheduleWouldStrand`).
/// That, plus the timelock, is why REXPrimary may hold it behind a mutable address.
///
/// The grid is ABSOLUTE: `epochStart + n * epochDuration`. A period in which nobody calls
/// `initiateSubEpoch` is simply SKIPPED -- REXPrimary's `lastClosedPeriod` jumps to the period it
/// did close in, so skipped periods never accumulate into a burst of back-to-back closes.
///
/// ADR-029: a close is admissible only in the first `windowLength` seconds of a period --
/// `periodIfOpen` is the trigger's real gate, returning 0 for a timestamp outside that window.
/// `windowLength == epochDuration` reproduces the pre-ADR-029 behaviour (the window never closes).
contract EpochSchedule is IEpochSchedule {
    uint64 public immutable epochStart;
    uint64 public immutable epochDuration;
    uint64 public immutable windowLength;

    error InvalidSchedule();

    constructor(uint64 epochStart_, uint64 epochDuration_, uint64 windowLength_) {
        if (epochStart_ == 0 || epochDuration_ == 0 || windowLength_ == 0 || windowLength_ > epochDuration_) {
            revert InvalidSchedule();
        }
        epochStart = epochStart_;
        epochDuration = epochDuration_;
        windowLength = windowLength_;
    }

    /// @inheritdoc IEpochSchedule
    function periodOf(uint64 timestamp) external view returns (uint64) {
        if (timestamp < epochStart) return 0;
        return (timestamp - epochStart) / epochDuration + 1;
    }

    /// @inheritdoc IEpochSchedule
    function periodIfOpen(uint64 timestamp) external view returns (uint64) {
        if (timestamp < epochStart) return 0;
        uint64 offset = timestamp - epochStart;
        if (offset % epochDuration >= windowLength) return 0;
        return offset / epochDuration + 1;
    }

    /// @inheritdoc IEpochSchedule
    /// @dev Checked arithmetic on a view: an absurd `period` reverts on overflow rather than
    /// wrapping into a moment in the past. Correct for a getter and free on the money path,
    /// which never calls this.
    function dueAt(uint64 period) external view returns (uint64) {
        if (period == 0) return 0;
        return epochStart + (period - 1) * epochDuration;
    }
}
