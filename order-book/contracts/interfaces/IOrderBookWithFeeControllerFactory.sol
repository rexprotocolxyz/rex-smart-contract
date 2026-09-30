// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IGovernedOrderBookFeeController} from "./IGovernedOrderBookFeeController.sol";
import {IOrderBookDeployer} from "./IOrderBookDeployer.sol";
import {IOrderBookFactory} from "./IOrderBookFactory.sol";

/// @title IOrderBookWithFeeControllerFactory
/// @notice Deployment configuration for governed fee-controller order books.
/// @dev Extends the generic canonical registry with the deployment policy used by
///      OrderBookWithFeeController instances.
interface IOrderBookWithFeeControllerFactory is IOrderBookFactory {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when the factory maker-fee cap is not below the basis-point denominator.
    /// @param maximumMakerFeeBps The rejected maker-fee cap in basis points.
    error InvalidMaximumMakerFeeBps(uint16 maximumMakerFeeBps);

    /// @notice Thrown when the factory taker-fee cap is not below the basis-point denominator.
    /// @param maximumTakerFeeBps The rejected taker-fee cap in basis points.
    error InvalidMaximumTakerFeeBps(uint16 maximumTakerFeeBps);

    /// @notice Thrown when a fee controller does not expose a usable nonzero governance delay.
    /// @param feeController The controller that failed timelock validation.
    error FeeControllerHasNoTimelock(address feeController);

    /// @notice Thrown when a fee controller's governance delay is outside the accepted range.
    /// @param feeController The controller whose delay was rejected.
    /// @param delay The delay reported by the controller.
    /// @param minimumDelay The smallest accepted delay.
    /// @param maximumDelay The largest accepted delay.
    error FeeControllerDelayOutOfBounds(
        address feeController, uint256 delay, uint256 minimumDelay, uint256 maximumDelay
    );

    /// @notice Thrown when a fee controller does not expose the required maker and taker fee caps.
    /// @param feeController The controller that failed fee-cap validation.
    error FeeControllerHasNoFeeCaps(address feeController);

    /// @notice Thrown when a controller could quote fees above the caps assigned to deployed order books.
    /// @param feeController The controller whose caps were rejected.
    /// @param controllerMaximumMakerFeeBps The controller's maker-fee cap.
    /// @param controllerMaximumTakerFeeBps The controller's taker-fee cap.
    /// @param orderBookMaximumMakerFeeBps The factory's immutable maker-fee cap for deployed books.
    /// @param orderBookMaximumTakerFeeBps The factory's immutable taker-fee cap for deployed books.
    error FeeControllerFeeCapsExceedOrderBookMaximum(
        address feeController,
        uint16 controllerMaximumMakerFeeBps,
        uint16 controllerMaximumTakerFeeBps,
        uint16 orderBookMaximumMakerFeeBps,
        uint16 orderBookMaximumTakerFeeBps
    );

    /// @notice Thrown when the configured deployer returns an invalid or incorrectly configured order book.
    /// @param orderBook The invalid order-book address returned by the deployer.
    error InvalidOrderBookDeployment(address orderBook);

    /// @notice Thrown because factory ownership cannot be renounced.
    error OwnershipRenunciationDisabled();

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted with the specialized configuration assigned to a newly created order book.
    event OrderBookDeploymentConfigured(
        address indexed orderBook,
        address indexed owner,
        address indexed feeController,
        uint16 maximumMakerFeeBps,
        uint16 maximumTakerFeeBps
    );

    /// @notice Emitted when governance changes the owner assigned to subsequently deployed order books.
    event DefaultOrderBookOwnerUpdated(address indexed previousOwner, address indexed newOwner);

    /// @notice Emitted when governance changes the fee controller assigned to subsequently deployed order books.
    event DefaultFeeControllerUpdated(address indexed previousController, address indexed newController);

    // -------------------------------------------------------------------------
    // Configuration mutations
    // -------------------------------------------------------------------------

    /// @notice Changes the owner assigned to subsequently deployed order books.
    /// @dev Existing books retain their current owner. Restricted to factory ownership.
    function setDefaultOrderBookOwner(address newDefaultOrderBookOwner) external;

    /// @notice Changes the fee controller assigned to subsequently deployed order books.
    /// @dev Existing books retain their current controller. Restricted to factory ownership.
    function setDefaultFeeController(IGovernedOrderBookFeeController newDefaultFeeController) external;

    // -------------------------------------------------------------------------
    // Configuration views
    // -------------------------------------------------------------------------

    /// @notice Returns the owner assigned to subsequently deployed order books.
    function defaultOrderBookOwner() external view returns (address);

    /// @notice Returns the dedicated immutable deployer created by this factory's constructor.
    function orderBookDeployer() external view returns (IOrderBookDeployer);

    /// @notice Returns the fee controller assigned to subsequently deployed order books.
    function defaultFeeController() external view returns (IGovernedOrderBookFeeController);

    /// @notice Returns the immutable maker-fee cap assigned to every order book deployed by this factory.
    function maximumMakerFeeBps() external view returns (uint16);

    /// @notice Returns the immutable taker-fee cap assigned to every order book deployed by this factory.
    function maximumTakerFeeBps() external view returns (uint16);
}
