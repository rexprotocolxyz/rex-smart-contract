// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IGovernedOrderBookFeeController} from "./IGovernedOrderBookFeeController.sol";
import {IOrderBookWithFee} from "./IOrderBookWithFee.sol";
import {FeeRole} from "./FeeRole.sol";

/// @notice Extends a fee-aware order book with replaceable external fee-controller governance.
interface IOrderBookWithFeeController is IOrderBookWithFee {
    /// @notice Thrown when an address required to be a fee controller contains no runtime code.
    /// @param feeController The address that is not a deployed fee-controller contract.
    error FeeControllerIsNotContract(address feeController);

    /// @notice Thrown when a controller delay cannot be added to block time and represented as a uint48 timestamp.
    /// @param delay The fee-controller governance delay that cannot be scheduled safely.
    error FeeControllerDelayOverflow(uint256 delay);

    /// @notice Thrown when the fee controller quotes a token other than the order book's base or quote token.
    /// @param token The unsupported fee token.
    error UnsupportedFeeToken(address token);

    /// @notice Thrown when the fee controller returns too many fee components for one role.
    /// @param feeRole Whether the excessive quote applies to the maker or taker.
    /// @param quoted The number of fee components returned by the controller.
    /// @param maximum The largest number of fee components accepted for the role.
    error TooManyFeeQuotes(FeeRole feeRole, uint256 quoted, uint256 maximum);

    /// @notice Thrown when a maker fee is not denominated in the maker's proceeds token.
    /// @param expectedToken The maker proceeds token required for the fee.
    /// @param actualToken The fee token returned by the controller.
    error InvalidMakerFeeToken(address expectedToken, address actualToken);

    /// @notice Thrown when fee components for one role are denominated in more than one token.
    /// @param feeRole Whether the mixed fees apply to the maker or taker.
    /// @param firstToken The token established by the first nonempty fee component.
    /// @param nextToken A different token returned by a subsequent fee component.
    error MixedFeeTokens(FeeRole feeRole, address firstToken, address nextToken);

    /// @notice Thrown when a controller fee recipient is zero or is the order book itself.
    /// @param recipient The invalid fee recipient.
    error InvalidFeeRecipient(address recipient);

    /// @notice Thrown when a fee controller does not expose a readable, nonzero governance delay.
    /// @param feeController The incompatible fee controller.
    error FeeControllerHasNoTimelock(address feeController);

    /// @notice Thrown when a fee controller's governance delay is outside the order book's accepted bounds.
    /// @param feeController The incompatible fee controller.
    /// @param delay The delay reported by the controller.
    /// @param minimumDelay The shortest accepted delay.
    /// @param maximumDelay The longest accepted delay.
    error FeeControllerDelayOutOfBounds(
        address feeController, uint256 delay, uint256 minimumDelay, uint256 maximumDelay
    );

    /// @notice Thrown when a fee controller does not expose readable maker and taker fee caps.
    /// @param feeController The incompatible fee controller.
    error FeeControllerHasNoFeeCaps(address feeController);

    /// @notice Thrown when a controller's fee cap exceeds the corresponding immutable order-book cap.
    /// @param feeController The incompatible fee controller.
    /// @param controllerMaximumMakerFeeBps The controller's maximum maker fee in basis points.
    /// @param controllerMaximumTakerFeeBps The controller's maximum taker fee in basis points.
    /// @param orderBookMaximumMakerFeeBps The order book's immutable maximum maker fee in basis points.
    /// @param orderBookMaximumTakerFeeBps The order book's immutable maximum taker fee in basis points.
    error FeeControllerFeeCapsExceedOrderBookMaximum(
        address feeController,
        uint16 controllerMaximumMakerFeeBps,
        uint16 controllerMaximumTakerFeeBps,
        uint16 orderBookMaximumMakerFeeBps,
        uint16 orderBookMaximumTakerFeeBps
    );

    /// @notice Thrown when a controller update is scheduled while another update remains pending.
    /// @param pendingFeeController The controller already awaiting activation.
    error FeeControllerUpdateAlreadyScheduled(address pendingFeeController);

    /// @notice Thrown when execution or cancellation is requested without a pending controller update.
    error NoFeeControllerUpdateScheduled();

    /// @notice Thrown when execution is requested before a pending controller update matures.
    /// @param executeAfter The earliest timestamp at which the update can execute.
    /// @param currentTime The block timestamp at the attempted execution.
    error FeeControllerUpdateNotReady(uint48 executeAfter, uint256 currentTime);

    /// @notice Emitted when the live fee controller is replaced.
    event FeeControllerUpdated(address indexed previousFeeController, address indexed newFeeController);

    /// @notice Emitted when a replacement controller's validated delay becomes the active cached delay.
    event FeeControllerDelayUpdated(address indexed feeController, uint256 previousDelay, uint256 newDelay);

    /// @notice Emitted when a fee-controller replacement is scheduled after the active controller's delay.
    event FeeControllerUpdateScheduled(
        address indexed currentFeeController, address indexed pendingFeeController, uint48 executeAfter
    );

    /// @notice Emitted when a pending fee-controller replacement is cancelled.
    event FeeControllerUpdateCancelled(address indexed pendingFeeController);

    /// @notice Schedules a replacement for the controller used for live fee quotes.
    /// @dev Only the owner may schedule. Existing orders remain live while the update is pending.
    function scheduleFeeControllerUpdate(IGovernedOrderBookFeeController newFeeController) external;

    /// @notice Executes a matured fee-controller replacement.
    /// @dev Callable by anyone once executeAfter is reached.
    function executeFeeControllerUpdate() external;

    /// @notice Cancels the pending fee-controller replacement.
    function cancelFeeControllerUpdate() external;

    /// @notice Returns the controller used for live maker and taker fee quotes.
    function feeController() external view returns (IGovernedOrderBookFeeController);

    /// @notice Returns the cached nonzero delay used to schedule a replacement for the active controller.
    /// @dev Cached during controller activation so a broken controller cannot block its own replacement.
    function feeControllerDelay() external view returns (uint256);

    /// @notice Returns the controller scheduled to replace feeController, or address(0) if none is pending.
    function pendingFeeController() external view returns (IGovernedOrderBookFeeController);

    /// @notice Returns the timestamp after which the pending controller can be activated, or zero if none is pending.
    function feeControllerUpdateTime() external view returns (uint48);

    /// @notice Returns the shortest controller governance delay accepted by this order book.
    function minimumFeeControllerDelay() external view returns (uint256);

    /// @notice Returns the longest controller governance delay accepted by this order book.
    function maximumFeeControllerDelay() external view returns (uint256);

    /// @notice Returns the largest fee-quote array accepted from the controller for each fee role.
    function maximumFeeQuotesPerRole() external view returns (uint256);
}
