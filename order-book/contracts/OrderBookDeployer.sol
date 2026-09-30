// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {OrderBookWithFeeController} from "./OrderBookWithFeeController.sol";
import {IOrderBookDeployer} from "./interfaces/IOrderBookDeployer.sol";
import {IGovernedOrderBookFeeController} from "./interfaces/IGovernedOrderBookFeeController.sol";

/// @notice Stateless creation-code carrier for order books deployed by a canonical factory.
/// @dev Anyone can call this contract, just as anyone can deploy OrderBookWithFeeController directly. Only books
///      registered by the factory are canonical markets.
contract OrderBookDeployer is IOrderBookDeployer {
    function deployOrderBook(
        address baseToken,
        address quoteToken,
        address owner,
        IGovernedOrderBookFeeController feeController,
        uint16 maximumMakerFeeBps,
        uint16 maximumTakerFeeBps
    ) external returns (address orderBook) {
        orderBook = address(
            new OrderBookWithFeeController(
                baseToken, quoteToken, owner, feeController, maximumMakerFeeBps, maximumTakerFeeBps
            )
        );
    }
}
