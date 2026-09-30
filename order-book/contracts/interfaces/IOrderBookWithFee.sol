// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IBaseOrderBook} from "./IBaseOrderBook.sol";
import {FeeRole} from "./FeeRole.sol";
import {Quote} from "./Quote.sol";
import {SettlementQuote} from "./SettlementQuote.sol";

/// @notice Extends the core order book with fee-aware approval and settlement quotes.
/// @dev Does not prescribe whether fees are baked in, externally configured, fixed, or otherwise calculated.
interface IOrderBookWithFee is IBaseOrderBook {
    /// @notice Thrown when the configured immutable maker-fee cap is 100% or greater.
    /// @param maximumMakerFeeBps The rejected maker-fee cap in basis points.
    error InvalidMaximumMakerFeeBps(uint16 maximumMakerFeeBps);

    /// @notice Thrown when the configured immutable taker-fee cap is 100% or greater.
    /// @param maximumTakerFeeBps The rejected taker-fee cap in basis points.
    error InvalidMaximumTakerFeeBps(uint16 maximumTakerFeeBps);

    /// @notice Thrown when the aggregate fee for one role exceeds the order book's immutable fee cap.
    /// @param feeRole Whether the rejected fee applies to the maker or taker.
    /// @param token The token in which the fee is charged.
    /// @param feeAmount The aggregate fee amount requested for the role.
    /// @param maximumFeeAmount The largest fee amount allowed for the role and settlement amount.
    error FeeExceedsMaximum(FeeRole feeRole, address token, uint256 feeAmount, uint256 maximumFeeAmount);

    /// @notice Emitted when a fee is realized during order settlement.
    /// @dev Emitted once for each realized fee component, including zero-amount components when reported.
    event OrderFeePaid(
        uint256 indexed orderId,
        address indexed payer,
        address indexed recipient,
        FeeRole feeRole,
        address token,
        uint256 amount
    );

    /// @notice Returns the immutable maximum maker fee in basis points of the fee token amount.
    function maximumMakerFeeBps() external view returns (uint16);

    /// @notice Returns the immutable maximum taker fee in basis points of the fee token amount.
    function maximumTakerFeeBps() external view returns (uint16);

    /// @notice Returns the maker approval and indicative settlement using current default maker and taker fees.
    /// @dev The taker is not yet known, so address-specific pricing can differ when the order is filled.
    function quoteMakeOrder(MakeOrderParams calldata params)
        external
        view
        returns (Quote[] memory approvals, SettlementQuote memory settlement);

    /// @notice Returns the net additional approval or refund and indicative settlement for an atomic replacement.
    /// @dev At most one of approvals and refunds contains an item. Settlement uses current default fees.
    function quoteAmendOrder(AmendOrderParams calldata params)
        external
        view
        returns (Quote[] memory approvals, Quote[] memory refunds, SettlementQuote memory settlement);

    /// @notice Returns the approval and settlement when the caller also receives the taker's output.
    /// @dev Callers should pass fresh quote-derived input and output bounds to takeOrder as slippage protection.
    function quoteTakeOrder(uint256 orderId, uint256 baseAmount)
        external
        view
        returns (Quote[] memory approvals, SettlementQuote memory settlement);

    /// @notice Returns the approval and settlement for the caller and the specified taker-output recipient.
    /// @dev Use this overload when the caller pays for a fill but a different account receives the output token.
    function quoteTakeOrder(uint256 orderId, uint256 baseAmount, address settlementRecipient)
        external
        view
        returns (Quote[] memory approvals, SettlementQuote memory settlement);
}
