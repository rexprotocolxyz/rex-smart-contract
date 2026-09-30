// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IGovernedOrderBookFeeController} from "../../contracts/interfaces/IGovernedOrderBookFeeController.sol";

/// @dev Exposes the factory-validated getters without implementing any order-book behavior.
contract MockCounterfeitOrderBook {
    address public immutable baseToken;
    address public immutable quoteToken;
    address public immutable owner;
    IGovernedOrderBookFeeController public immutable feeController;
    uint16 public immutable maximumMakerFeeBps;
    uint16 public immutable maximumTakerFeeBps;

    constructor(
        address baseToken_,
        address quoteToken_,
        address owner_,
        IGovernedOrderBookFeeController feeController_,
        uint16 maximumMakerFeeBps_,
        uint16 maximumTakerFeeBps_
    ) {
        baseToken = baseToken_;
        quoteToken = quoteToken_;
        owner = owner_;
        feeController = feeController_;
        maximumMakerFeeBps = maximumMakerFeeBps_;
        maximumTakerFeeBps = maximumTakerFeeBps_;
    }
}
