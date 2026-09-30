// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Shared custom-error vocabulary (constitution Art 12). FROZEN — selectors are ABI;
// adding an error is additive, changing or removing one is a breaking change.
error ZeroAmount();
error InvalidState();
error EpochInFlight();
error UnauthorizedSender();
error NotReadyToExecute();
error NothingToSettle();
error NotKeeper();
error UnenrolledRemote();
error FeeRouteUnsupported();
/// @dev The contract does not hold enough native to pay the quoted interchain gas
/// for both legs (`hyperlane-bridge.md` §"Gas / IGP" — quote-and-pay).
error InsufficientGasPayment();
/// @dev Refund of unspent interchain-gas value back to the caller failed.
error RefundFailed();
/// @dev Cancel attempted after the epoch consumed this side (spec §7.2).
error EpochLocked();
/// @dev Claim attempted before the epoch's batch settled or was released (spec §7.6).
error NotSettled();
/// @dev Constructor got launch config that cannot define a valid window (spec §7.1).
error InvalidLaunchpadConfig();
/// @dev Deposit or cancel attempted outside the launch window (spec §7.1).
error LaunchpadNotOpen();
/// @dev Close attempted before the launch deadline (spec §7.1).
error LaunchpadNotClosed();
/// @dev Close attempted after the launchpad already closed — idempotent guard (spec §7.1).
error AlreadyClosed();
/// @dev Action needs a lifecycle state the pool is not in (e.g. subscribe before EpochBased).
error WrongLifecycleState();
/// @dev Zone invariant (spec §8): a matched redeem side must never carry a sub-minimum net
/// residual — initiateSubEpoch reverts rather than open a batch that can never bridge (H-3).
error BelowMinTicket();
/// @dev nav() read while older than STALENESS_WINDOW (spec §9).
error StalePrice();
/// @dev A relayed NAV moved more than MAX_NAV_MOVE_BPS from the last accepted value (spec §9).
error NavSanityBound();
/// @dev seedNav called after the one-shot seed already ran (spec §3.3).
error AlreadySeeded();
/// @dev abortDeposit called before the batch's fulfillment deadline elapsed — only past the
/// deadline may a stuck leg be aborted (spec §7.5).
error AbortBeforeDeadline();
/// @dev abortDeposit called on a leg already executed or aborted (or never recorded) — each
/// subscribe leg resolves exactly once (spec §7.5). executeDeposit reverts InvalidState.
error BatchAlreadyResolved();
/// @dev Retained for ABI compatibility only; no longer raised (ADR-030 D11 replaced the balance
/// forecast with an attempt-then-abort). Previously: abortRedeem refused because the vault could
/// already pay this batch (usdc.balanceOf(rwaToken) >= grossAssets) -- a payable redeem was
/// executed, never cancelled (ADR-012, spec §7.5).
error BatchExecutable();
/// @dev executeRedeem got a vault fill below the initiate->execute slippage floor (spec §7.5).
/// Distinct from the deposit's swallowed SlippageFloorBreached: a redeem breach reverts loudly.
error SlippageExceeded();
error FeeCapExceeded(); // a fee bps or the cap breaches the current feeCapBps (SC6)
error WindDownNotComplete(); // triggerShutDown before the window elapses / batches still hold funds (SC6)
error RenounceDisabled(); // renounceOwnership is overridden to revert (SC6)
error NotGuardian(); // guardian-only call by a non-guardian (SC6)
error TimelockNotElapsed(); // applyFees/applyFeeCap before effectiveAt (SC6)
error TooEarly(); // initiateSubEpoch before the scheduled moment (ADR-025, SC11)
/// @dev A local IRWAConversion read returned 0 (ADR-026). Distinct from InvalidState: an
/// uninitialised or mis-pointed NAV source is an operator-diagnosable condition, not a generic
/// constructor/state guard, and on the redeem path it would otherwise fail OPEN (a 0 floor accepts
/// any fill) rather than safe.
error ZeroNav();
// applySchedule: the proposed calendar's `dueAt(lastClosedPeriod + 1)` lies beyond
// `SCHEDULE_SWAP_HORIZON`, i.e. the stored position would be unreachable for longer than any real
// calendar change needs -- a permanent brick of initiateSubEpoch, since nothing can rebase the
// counter. NOTE the predicate is a HORIZON on `dueAt`, not `periodOf(now) <= lastClosedPeriod`: that
// simpler test also refuses the legitimate case of a grid that has not started yet but catches up
// shortly (SC11).
error ScheduleWouldStrand();
error AmountNotQuantized(); // an amount is not a whole micro-unit of its asset (ADR-028 D5, SC13)
