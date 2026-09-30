// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Side} from "./Side.sol";

/// @notice Core escrow-backed limit-order API for one immutable base/quote token pair.
/// @dev Base and quote amounts together define an order's limit price. All amounts use their token's native decimals.
interface IBaseOrderBook {
    /// @notice The lifecycle state of an order ID.
    enum OrderStatus {
        /// @dev No order exists for the ID.
        NONE,
        OPEN,
        FILLED,
        CANCELLED,
        EXPIRED
    }

    /// @notice Thrown when a required external address is zero or is the order book itself.
    error ZeroAddress();

    /// @notice Thrown when the same token is configured as both base and quote token.
    /// @param token The address supplied for both sides of the pair.
    error IdenticalTokens(address token);

    /// @notice Thrown when an address required to be an ERC-20 token contains no runtime code.
    /// @param token The address that is not a deployed token contract.
    error TokenIsNotContract(address token);

    /// @notice Thrown when an incoming token transfer does not increase the order book's balance by the exact amount.
    /// @param token The token whose transfer behavior is unsupported.
    /// @param expectedAmount The amount the order book expected to receive.
    /// @param receivedAmount The balance increase observed by the order book.
    error UnsupportedTokenBehavior(address token, uint256 expectedAmount, uint256 receivedAmount);

    /// @notice Thrown when an outgoing transfer does not debit and credit exactly the requested amount.
    /// @param token The token whose transfer behavior is unsupported.
    /// @param recipient The intended token recipient.
    /// @param expectedAmount The amount the order book attempted to transfer.
    /// @param debitedAmount The balance decrease observed on the order book.
    /// @param receivedAmount The balance increase observed for the recipient.
    error UnsupportedOutgoingTokenBehavior(
        address token, address recipient, uint256 expectedAmount, uint256 debitedAmount, uint256 receivedAmount
    );

    /// @notice Thrown when either the base amount or quote amount of an order is zero.
    error InvalidOrderAmount();

    /// @notice Thrown when an order expiry is not later than the current block timestamp.
    /// @param expiry The rejected expiry timestamp.
    error InvalidExpiry(uint48 expiry);

    /// @notice Thrown when an order ID has never been allocated.
    /// @param orderId The unknown order ID.
    error OrderNotFound(uint256 orderId);

    /// @notice Thrown when an operation requires an open order but the order has another status.
    /// @param orderId The order that cannot be operated on.
    /// @param status The order's reported status.
    error OrderNotOpen(uint256 orderId, OrderStatus status);

    /// @notice Thrown when an operation cannot continue because the order has reached its expiry.
    /// @param orderId The expired order ID.
    error OrderExpired(uint256 orderId);

    /// @notice Thrown when expiry finalization is requested before an order reaches its expiry.
    /// @param orderId The order that is not yet expired.
    error OrderNotExpired(uint256 orderId);

    /// @notice Thrown when an operation reserved for the maker is called by another account.
    /// @param orderId The affected order ID.
    /// @param caller The unauthorized caller.
    error NotOrderMaker(uint256 orderId, address caller);

    /// @notice Thrown when an amendment's expected base remainder no longer matches current order state.
    /// @param orderId The order whose remainder changed.
    /// @param expectedAmount The remainder supplied by the maker.
    /// @param actualAmount The remainder stored by the order book.
    error RemainingBaseAmountChanged(uint256 orderId, uint256 expectedAmount, uint256 actualAmount);

    /// @notice Thrown when a maker attempts to take their own order.
    /// @param orderId The maker's order ID.
    error MakerCannotTakeOwnOrder(uint256 orderId);

    /// @notice Thrown when a fill amount is zero or exceeds the remaining base amount.
    /// @param requested The requested base-token fill amount.
    /// @param remaining The base-token amount remaining on the order.
    error InvalidTakeAmount(uint256 requested, uint256 remaining);

    /// @notice Thrown when a partial fill is smaller than the maker's minimum fulfillment amount.
    /// @param requested The requested base-token fill amount.
    /// @param minimum The order's minimum base-token fulfillment amount.
    error TakeAmountBelowMinimum(uint256 requested, uint256 minimum);

    /// @notice Thrown when a minimum fulfillment exceeds the order's full base amount.
    /// @param minimumFillBaseAmount The rejected minimum base-token fulfillment amount.
    /// @param totalBaseAmount The order's full base-token amount.
    error InvalidMinimumFillAmount(uint256 minimumFillBaseAmount, uint256 totalBaseAmount);

    /// @notice Thrown when a minimum base-token fulfillment can round to zero quote-token principal.
    /// @param minimumFillBaseAmount The configured minimum base-token fulfillment amount.
    /// @param totalBaseAmount The order's full base-token amount.
    /// @param totalQuoteAmount The order's full quote-token amount.
    error MinimumFillCannotProduceQuoteAmount(
        uint256 minimumFillBaseAmount, uint256 totalBaseAmount, uint256 totalQuoteAmount
    );

    /// @notice Thrown when proportional fill calculation rounds the quote-token amount down to zero.
    error ZeroQuoteAmount();

    /// @notice Thrown when a partial fill would leave base principal without any quote principal.
    /// @param remainingBaseAmount The base-token principal that would remain.
    /// @param remainingQuoteAmount The quote-token principal that would remain.
    error UnfillableRemainder(uint256 remainingBaseAmount, uint256 remainingQuoteAmount);

    /// @notice Thrown when a pagination limit is zero or exceeds the supported maximum.
    /// @param requested The requested page size.
    /// @param maximum The largest supported page size.
    error InvalidPageSize(uint256 requested, uint256 maximum);

    /// @notice Thrown when an expiry-sweep batch exceeds the supported maximum.
    /// @param requested The number of supplied order IDs.
    /// @param maximum The largest supported batch size.
    error SweepBatchTooLarge(uint256 requested, uint256 maximum);

    /// @notice Thrown when an account has no failed-refund credit for a token.
    error NoRefundAvailable(address account, address token);

    /// @notice Thrown when the refund-transfer helper is called by an account other than the order book itself.
    error UnauthorizedRefundExecutor(address caller);

    /// @notice Thrown when the total base-token amount debited exceeds the taker's bound.
    /// @param baseAmount The total base-token amount required from the taker.
    /// @param maximumBaseAmount The maximum base-token amount the taker accepts being debited.
    error BaseInExceedsMaximum(uint256 baseAmount, uint256 maximumBaseAmount);

    /// @notice Thrown when the total quote-token amount debited exceeds the taker's bound.
    /// @param quoteAmount The total quote-token amount required from the taker.
    /// @param maximumQuoteAmount The maximum quote-token amount the taker accepts being debited.
    error QuoteInExceedsMaximum(uint256 quoteAmount, uint256 maximumQuoteAmount);

    /// @notice Thrown when the net base-token amount credited is below the taker's bound.
    /// @param baseAmount The net base-token amount credited to the taker's recipient.
    /// @param minimumBaseAmount The minimum base-token amount the taker requires being credited.
    error BaseOutBelowMinimum(uint256 baseAmount, uint256 minimumBaseAmount);

    /// @notice Thrown when the net quote-token amount credited is below the taker's bound.
    /// @param quoteAmount The net quote-token amount credited to the taker's recipient.
    /// @param minimumQuoteAmount The minimum quote-token amount the taker requires being credited.
    error QuoteOutBelowMinimum(uint256 quoteAmount, uint256 minimumQuoteAmount);

    /// @notice Parameters for a new order.
    struct MakeOrderParams {
        Side side;
        /// @dev Full base-token quantity offered or requested.
        uint256 totalBaseAmount;
        /// @dev Full quote-token principal used with totalBaseAmount to define the price.
        uint256 totalQuoteAmount;
        /// @dev Smallest partial fill accepted, denominated in native base-token units. Zero disables the minimum.
        ///      A full remaining fill is always accepted.
        uint256 minimumFillBaseAmount;
        /// @dev Unix timestamp after which the order can no longer be filled.
        uint48 expiry;
    }

    /// @notice Parameters for taking part or all of an open order.
    struct TakeOrderParams {
        uint256 orderId;
        /// @dev Base-token quantity to fill.
        uint256 baseAmount;
        /// @dev Account that receives the taker's output token.
        address recipient;
        /// @dev Maximum total base-token amount the taker accepts being debited when taking a BUY order.
        uint256 maxBaseIn;
        /// @dev Maximum total quote-token amount the taker accepts being debited when taking a SELL order.
        uint256 maxQuoteIn;
        /// @dev Minimum net base-token amount the taker's recipient requires being credited when taking a SELL order.
        uint256 minBaseOut;
        /// @dev Minimum net quote-token amount the taker's recipient requires being credited when taking a BUY order.
        uint256 minQuoteOut;
    }

    /// @notice Parameters for atomically cancelling an order and creating its replacement.
    struct AmendOrderParams {
        /// @dev The open order to cancel and replace.
        uint256 orderId;
        /// @dev Reverts if a fill changes the remaining base amount before this transaction executes.
        uint256 expectedRemainingBaseAmount;
        /// @dev The replacement order's full amount, not an adjustment to the previous order.
        uint256 newBaseAmount;
        /// @dev The replacement order's full quote amount, not an adjustment to the previous order.
        uint256 newQuoteAmount;
        /// @dev The replacement order's smallest partial fill, denominated in native base-token units. Zero disables it.
        uint256 newMinimumFillBaseAmount;
        /// @dev Unix timestamp after which the replacement can no longer be filled.
        uint48 newExpiry;
    }

    /// @notice An order's original terms, current base remainder, and lifecycle state.
    /// @dev totalQuoteAmount remains the original principal; fills report realized quote amounts through OrderTaken.
    struct Order {
        uint256 id;
        address maker;
        Side side;
        OrderStatus status;
        uint48 expiry;
        uint256 totalBaseAmount;
        uint256 remainingBaseAmount;
        uint256 totalQuoteAmount;
        uint256 minimumFillBaseAmount;
    }

    /// @notice Emitted when a maker creates a new order ID, including through amendment.
    event OrderMade(
        uint256 indexed orderId,
        address indexed maker,
        Side indexed side,
        uint256 totalBaseAmount,
        uint256 totalQuoteAmount,
        uint256 minimumFillBaseAmount,
        uint48 expiry
    );

    /// @notice Emitted for each partial or full fill.
    /// @dev remainingBaseAmount records the unfilled principal immediately after this fill; it can be below the
    ///      minimum fulfillment when the order is subsequently cancelled in the same transaction.
    event OrderTaken(
        uint256 indexed orderId,
        address indexed taker,
        address indexed recipient,
        uint256 takenBaseAmount,
        uint256 takenQuoteAmount,
        uint256 remainingBaseAmount
    );

    /// @notice Emitted when an order becomes cancelled through maker cancellation, amendment, or dust finalization.
    /// @dev maker identifies the order owner and is not necessarily the account that triggered cancellation.
    event OrderCancelled(uint256 indexed orderId, address indexed maker);

    /// @notice Emitted when an accepted partial fill leaves a remainder smaller than the maker's minimum fulfillment.
    /// @dev The remaining escrow is credited to maker and automatically delivered when the token permits it.
    ///      OrderCancelled is emitted immediately before this event.
    event OrderRemainderCancelled(
        uint256 indexed orderId,
        address indexed triggeredBy,
        address indexed maker,
        uint256 cancelledBaseAmount,
        uint256 cancelledQuoteAmount
    );

    /// @notice Links an amended order ID to the newly created replacement ID.
    /// @dev Indexers should also process OrderCancelled for previousOrderId and OrderMade for newOrderId.
    event OrderAmended(uint256 indexed previousOrderId, uint256 indexed newOrderId, address indexed maker);

    /// @notice Emitted when an account finalizes an expired order and releases its remaining escrow.
    event ExpiredOrderSwept(uint256 indexed orderId, address indexed triggeredBy, address indexed maker);

    /// @notice Emitted when escrow is made withdrawable before an automatic refund is attempted.
    event RefundCredited(uint256 indexed orderId, address indexed maker, address indexed token, uint256 amount);

    /// @notice Emitted when refund credit is delivered to a maker-selected recipient.
    event RefundWithdrawn(address indexed maker, address indexed token, address indexed recipient, uint256 amount);

    /// @notice Creates an order and escrows base tokens for SELL or quote tokens for BUY.
    function makeOrder(MakeOrderParams calldata params) external returns (uint256 orderId);

    /// @notice Atomically cancels the caller's open order and creates a same-side replacement with a new ID.
    /// @dev Reuses remaining escrow and transfers only the difference required by the replacement.
    function amendOrder(AmendOrderParams calldata params) external returns (uint256 newOrderId);

    /// @notice Fills baseAmount against an open order subject to the caller's settlement bound.
    function takeOrder(TakeOrderParams calldata params) external;

    /// @notice Closes the caller's open order and credits its remaining escrow for automatic refund.
    /// @dev Before expiry the order becomes CANCELLED and emits OrderCancelled. At or after expiry it instead becomes
    ///      EXPIRED and emits ExpiredOrderSwept, matching the effective status already exposed by read functions.
    function cancelOrder(uint256 orderId) external;

    /// @notice Permissionlessly finalizes one expired order and credits its maker for automatic refund.
    function sweepExpiredOrder(uint256 orderId) external;

    /// @notice Permissionlessly finalizes eligible IDs, skipping IDs that are not open and expired.
    /// @dev Reverts when orderIds contains more than maximumSweepBatchSize entries.
    function sweepExpiredOrders(uint256[] calldata orderIds) external;

    /// @notice Withdraws all of the caller's failed-refund credit for token to recipient.
    /// @dev recipient may differ from the maker so transfer-restricted maker addresses do not strand escrow.
    function withdrawRefund(address token, address recipient) external returns (uint256 amount);

    /// @notice Returns the highest allocated order ID, not the number of currently open orders.
    function orderCount() external view returns (uint256);

    /// @notice Returns the token whose quantity is filled through baseAmount.
    function baseToken() external view returns (address);

    /// @notice Returns the token used to express order prices and quote-token principal.
    function quoteToken() external view returns (address);

    /// @notice Returns the largest limit accepted by getOrders.
    function maximumPageSize() external view returns (uint256);

    /// @notice Returns the largest batch accepted by sweepExpiredOrders.
    function maximumSweepBatchSize() external view returns (uint256);

    /// @notice Returns one order or reverts when the ID was never allocated.
    /// @dev An open order past its expiry is returned with the effective EXPIRED status.
    function getOrder(uint256 orderId) external view returns (Order memory order);

    /// @notice Returns the exact unfilled quote-token principal tracked for an order.
    /// @dev Reverts for an unknown ID and returns zero after the order is filled, cancelled, or swept.
    function remainingQuoteAmountOf(uint256 orderId) external view returns (uint256);

    /// @notice Returns the amount of token reserved to back open orders and failed-refund credits.
    /// @dev Monitoring can compare this liability with the order book's actual token balance.
    function escrowLiability(address token) external view returns (uint256);

    /// @notice Returns failed automatic refunds that account can withdraw for token.
    function claimableRefund(address account, address token) external view returns (uint256);

    /// @notice Returns orders in ascending ID order beginning at cursor.
    /// @dev cursor = 0 starts at ID 1; nextCursor = 0 indicates the end of the collection.
    function getOrders(uint256 cursor, uint256 limit) external view returns (Order[] memory orders, uint256 nextCursor);

    /// @notice Returns NONE for an unknown ID and the effective EXPIRED status after an open order's expiry.
    function statusOf(uint256 orderId) external view returns (OrderStatus status);
}
