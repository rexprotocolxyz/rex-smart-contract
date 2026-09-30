// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @notice Exposes the governance delay that an order book uses for controller-replacement scheduling.
/// @dev Kept separate from IOrderBookFeeController so fee quoting remains independent of controller governance.
interface IFeeControllerTimelock {
    function getMinDelay() external view returns (uint256);
}
