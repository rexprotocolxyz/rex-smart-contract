// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IGovernedOrderBookFeeController} from "../../contracts/interfaces/IGovernedOrderBookFeeController.sol";
import {FeeQuote} from "../../contracts/interfaces/FeeQuote.sol";
import {FeeRole} from "../../contracts/interfaces/FeeRole.sol";
import {Side} from "../../contracts/interfaces/Side.sol";

/// @dev Configurable fee controller for order-book tests.
contract MockOrderBookFeeController is IGovernedOrderBookFeeController {
    uint256 private _minimumDelay;
    bool private _minimumDelayUnavailable;

    mapping(FeeRole feeRole => FeeQuote[] quotes) private _quotes;

    constructor(uint256 minimumDelay_) {
        _minimumDelay = minimumDelay_;
    }

    function getMinDelay() external view override returns (uint256) {
        require(!_minimumDelayUnavailable, "minimum delay unavailable");
        return _minimumDelay;
    }

    function setMinimumDelay(uint256 minimumDelay_) external {
        _minimumDelay = minimumDelay_;
    }

    function setMinimumDelayUnavailable(bool unavailable) external {
        _minimumDelayUnavailable = unavailable;
    }

    function maximumMakerFeeBps() external pure returns (uint16) {
        return 100;
    }

    function maximumTakerFeeBps() external pure returns (uint16) {
        return 100;
    }

    function setQuotes(FeeRole feeRole, FeeQuote[] calldata quotes) external {
        delete _quotes[feeRole];
        for (uint256 i; i < quotes.length; ++i) {
            _quotes[feeRole].push(quotes[i]);
        }
    }

    function quoteOrderFee(address, address, address, Side, FeeRole feeRole, address, uint256, address, uint256)
        external
        view
        override
        returns (FeeQuote[] memory quotes)
    {
        FeeQuote[] storage storedQuotes = _quotes[feeRole];
        quotes = new FeeQuote[](storedQuotes.length);
        for (uint256 i; i < storedQuotes.length; ++i) {
            quotes[i] = storedQuotes[i];
        }
    }
}
