// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IFeeControllerFeeCaps} from "./IFeeControllerFeeCaps.sol";
import {IFeeControllerTimelock} from "./IFeeControllerTimelock.sol";
import {IOrderBookFeeController} from "./IOrderBookFeeController.sol";

/// @notice Governed fee-controller capability set required by OrderBookWithFeeController.
/// @dev Runtime validation remains necessary because Solidity interface types do not prove that an address correctly
///      implements every function or returns values within the order book's accepted bounds.
// The interface intentionally composes capabilities without adding another function.
// solhint-disable-next-line no-empty-blocks
interface IGovernedOrderBookFeeController is IOrderBookFeeController, IFeeControllerTimelock, IFeeControllerFeeCaps {}
