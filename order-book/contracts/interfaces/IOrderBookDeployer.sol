// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IGovernedOrderBookFeeController} from "./IGovernedOrderBookFeeController.sol";

/// @notice Stateless deployment boundary used to keep factory runtime bytecode below EVM size limits.
interface IOrderBookDeployer {
    function deployOrderBook(
        address baseToken,
        address quoteToken,
        address owner,
        IGovernedOrderBookFeeController feeController,
        uint16 maximumMakerFeeBps,
        uint16 maximumTakerFeeBps
    ) external returns (address orderBook);
}
