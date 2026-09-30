// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Administrative, lifecycle, and emergency-control API for an order-book implementation.
/// @dev Scheduling legacy mode does not restrict operations and may be cancelled before execution. Executed legacy mode
///      permanently blocks creation and amendment but leaves fills available. Pausing additionally blocks fills, while
///      cancellation, expiry sweeping, and excess-token recovery remain available in both states. Ownership is exposed
///      separately by the implementation's access-control module.
interface IOrderBookAdministration {
    /// @notice Thrown when a pause request comes from neither the owner nor the pause guardian.
    /// @param caller The unauthorized caller.
    error UnauthorizedPauseCaller(address caller);

    /// @notice Thrown when an order book's token balance is below its recorded escrow liability.
    /// @param token The insolvent token.
    /// @param balance The order book's observed token balance.
    /// @param liability The token amount reserved for open orders.
    error EscrowInsolvent(address token, uint256 balance, uint256 liability);

    /// @notice Thrown when token recovery is requested but no balance exists above escrow liability.
    /// @param token The token without a recoverable excess balance.
    error NoExcessBalance(address token);

    /// @notice Thrown when an operation that creates or amends an order is attempted in legacy mode.
    error OrderBookInLegacyMode();

    /// @notice Thrown when the order book is already in legacy mode.
    error LegacyModeAlreadyEnabled();

    /// @notice Thrown when legacy-mode activation has already been scheduled.
    /// @param executeAfter The earliest timestamp at which legacy mode can be activated.
    error LegacyModeAlreadyScheduled(uint48 executeAfter);

    /// @notice Thrown when the requested legacy-mode activation time does not satisfy the minimum notice period.
    /// @param requestedActivationTime The activation timestamp requested by the owner.
    /// @param earliestActivationTime The earliest timestamp permitted by the minimum delay.
    error LegacyModeActivationTooEarly(uint48 requestedActivationTime, uint48 earliestActivationTime);

    /// @notice Thrown when no legacy-mode activation is scheduled.
    error NoLegacyModeScheduled();

    /// @notice Thrown when legacy-mode activation is attempted before its scheduled time.
    /// @param executeAfter The earliest timestamp at which legacy mode can be activated.
    /// @param currentTime The current block timestamp.
    error LegacyModeNotReady(uint48 executeAfter, uint256 currentTime);

    /// @notice Thrown when an account other than the owner or pause guardian attempts to cancel activation.
    /// @param caller The unauthorized caller.
    error UnauthorizedLegacyModeCancellation(address caller);

    /// @notice Emitted when the account authorized to pause the order book changes.
    event PauseGuardianUpdated(address indexed previousPauseGuardian, address indexed newPauseGuardian);

    /// @notice Emitted when an owner recovers a token balance not reserved for open orders.
    event ExcessTokenRecovered(address indexed token, address indexed recipient, uint256 amount);

    /// @notice Emitted when the owner schedules the irreversible transition into legacy mode.
    /// @param caller The owner that scheduled the transition.
    /// @param executeAfter The earliest timestamp at which the transition can be executed.
    event LegacyModeScheduled(address indexed caller, uint48 executeAfter);

    /// @notice Emitted when the owner or pause guardian cancels a scheduled transition.
    /// @param caller The account that cancelled the transition.
    /// @param executeAfter The cancelled transition's activation timestamp.
    event LegacyModeScheduleCancelled(address indexed caller, uint48 executeAfter);

    /// @notice Emitted when the order book irreversibly enters legacy mode.
    /// @param caller The account that executed the scheduled transition.
    event LegacyModeEntered(address indexed caller);

    /// @notice Returns the account authorized to pause alongside the owner.
    function pauseGuardian() external view returns (address);

    /// @notice Replaces the pause guardian.
    /// @dev Only the owner may call this function.
    function setPauseGuardian(address newPauseGuardian) external;

    /// @notice Pauses order creation, amendment, and fills.
    /// @dev Callable by either the owner or the pause guardian.
    function pause() external;

    /// @notice Ends the emergency pause and restores operations allowed by the current lifecycle state.
    /// @dev Only the owner may call this function. This does not exit legacy mode.
    function unpause() external;

    /// @notice Returns whether order creation, amendment, and fills are paused.
    function paused() external view returns (bool);

    /// @notice Schedules the irreversible transition into legacy mode at an exact timestamp.
    /// @dev Only the owner may call this function. The timestamp must be at least `minimumLegacyModeDelay()` in the
    ///      future. Scheduling does not restrict order-book operations.
    /// @param activationTime The timestamp at which anyone may execute the transition.
    function scheduleLegacyMode(uint48 activationTime) external;

    /// @notice Cancels a pending legacy-mode transition.
    /// @dev Callable by either the owner or the pause guardian before execution.
    function cancelLegacyModeSchedule() external;

    /// @notice Executes a scheduled legacy-mode transition after its mandatory delay.
    /// @dev Callable by anyone. Once executed, the transition cannot be reversed.
    function executeLegacyMode() external;

    /// @notice Returns the minimum delay between scheduling and executing legacy mode.
    function minimumLegacyModeDelay() external view returns (uint256);

    /// @notice Returns the earliest activation timestamp, or zero when no transition is scheduled.
    function legacyModeActivationTime() external view returns (uint48);

    /// @notice Returns whether the order book has irreversibly entered legacy mode.
    function legacyMode() external view returns (bool);

    /// @notice Transfers the full token balance above recorded escrow liability to recipient.
    /// @dev Only the owner may call this function. It cannot withdraw escrow reserved for open orders.
    function recoverExcessToken(address token, address recipient) external;
}
