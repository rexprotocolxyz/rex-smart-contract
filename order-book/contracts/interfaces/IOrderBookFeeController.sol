// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FeeRole} from "./FeeRole.sol";
import {FeeQuote} from "./FeeQuote.sol";
import {Side} from "./Side.sol";

/// @notice Quotes live order fees and their recipients using the settlement context supplied by an order book.
interface IOrderBookFeeController {
    /// @dev Each quote binds an amount to its recipient so fee configuration and routing update atomically.
    ///      Implementations may price taker fees by settlementRecipient. Changing the output destination can
    ///      therefore change the fee even when maker, taker, side, and traded amounts remain unchanged.
    /// @param maker Account whose order is being filled.
    /// @param taker Account paying to fill the order.
    /// @param settlementRecipient Account receiving the taker's output; may differ from taker.
    function quoteOrderFee(
        address maker,
        address taker,
        address settlementRecipient,
        Side side,
        FeeRole feeRole,
        address baseToken,
        uint256 baseTokenAmount,
        address quoteToken,
        uint256 quoteTokenAmount
    ) external view returns (FeeQuote[] memory quotes);
}
