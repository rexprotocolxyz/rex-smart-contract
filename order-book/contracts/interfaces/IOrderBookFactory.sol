// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

/// @title IOrderBookFactory
/// @notice Deploys and manages the active registry of escrow-backed order books.
/// @dev
/// `(tokenA, tokenB)` and `(tokenB, tokenA)` identify the same market and must resolve to the
/// same registered order book. The factory derives a canonical pair key by sorting the token
/// addresses. A book retains the base/quote orientation selected when it is created; that
/// orientation defines its price ratio and BUY/SELL semantics.
///
/// Removing a book only unregisters it. It does not destroy, pause, or otherwise modify the
/// deployed order-book contract, and it cannot move funds held by that contract. A removed
/// pair may be registered again through a later deployment.
interface IOrderBookFactory {
    // -------------------------------------------------------------------------
    // Errors
    // -------------------------------------------------------------------------

    /// @notice Thrown when a required address is zero or is a forbidden factory self-reference.
    error ZeroAddress();

    /// @notice Thrown when the same token is supplied for both sides of a market.
    /// @param token The address supplied as both tokens in the pair.
    error IdenticalTokens(address token);

    /// @notice Thrown when an address required to contain deployed contract code has no runtime code.
    /// @param token The address that does not contain deployed contract code.
    error TokenIsNotContract(address token);

    /// @notice Thrown when a market is already registered in either token orientation.
    /// @param tokenA One token from the requested pair.
    /// @param tokenB The other token from the requested pair.
    /// @param orderBook The currently registered order book.
    error OrderBookAlreadyExists(address tokenA, address tokenB, address orderBook);

    /// @notice Thrown when a deployment address is already registered as another canonical order book.
    /// @param orderBook The order-book address that is already registered.
    error OrderBookAlreadyRegistered(address orderBook);

    /// @notice Thrown when removal is requested for a pair without an active registry entry.
    /// @param tokenA One token from the requested pair.
    /// @param tokenB The other token from the requested pair.
    error OrderBookNotRegistered(address tokenA, address tokenB);

    /// @notice Thrown when a pagination limit is zero or exceeds the supported maximum.
    /// @param requested The requested page size.
    /// @param maximum The largest supported page size.
    error InvalidPageSize(uint256 requested, uint256 maximum);

    // -------------------------------------------------------------------------
    // Events
    // -------------------------------------------------------------------------

    /// @notice Emitted after a newly deployed order book is fully configured and registered.
    event OrderBookCreated(address indexed baseToken, address indexed quoteToken, address indexed orderBook);

    /// @notice Emitted when a book is removed from the active registry.
    /// @dev The order-book contract remains deployed and operational after this event.
    event OrderBookRemoved(address indexed baseToken, address indexed quoteToken, address indexed orderBook);

    // -------------------------------------------------------------------------
    // Registry mutations
    // -------------------------------------------------------------------------

    /// @notice Creates and registers an order book for a token pair using the factory configuration.
    /// @dev Reverts if a book is already registered in either orientation. The implementation must
    ///      fully configure the deployed book before registering it or emitting OrderBookCreated.
    function createOrderBook(address baseToken, address quoteToken) external returns (address orderBook);

    /// @notice Removes the active order-book registration for a token pair.
    /// @dev This is a registry-only operation. It must not destroy or call the removed book, and it
    ///      must make both pair orientations resolve to zero, make isOrderBook return false, and
    ///      exclude the address from active enumeration. Implementations should restrict this
    ///      function to factory administration.
    /// @return orderBook Address that was removed from the active registry.
    function removeOrderBook(address tokenA, address tokenB) external returns (address orderBook);

    // -------------------------------------------------------------------------
    // Registry views
    // -------------------------------------------------------------------------

    /// @notice Returns the active order book for a pair in either orientation, or zero if none exists.
    /// @dev `orderBookFor(A, B)` must equal `orderBookFor(B, A)`.
    function orderBookFor(address tokenA, address tokenB) external view returns (address orderBook);

    /// @notice Returns the order-independent key used to identify a token pair.
    /// @dev The key is `keccak256(abi.encodePacked(token0, token1))`, where token0 is the numerically
    ///      smaller address. Reverts when either address is zero or both addresses are identical.
    function pairKey(address tokenA, address tokenB) external pure returns (bytes32 key);

    /// @notice Returns whether candidate is currently registered by this factory.
    function isOrderBook(address candidate) external view returns (bool);

    /// @notice Returns the number of currently registered order books.
    function orderBookCount() external view returns (uint256);

    /// @notice Returns the currently registered order book at index.
    /// @dev Registry mutations may change the address associated with an index.
    function orderBookAt(uint256 index) external view returns (address orderBook);

    /// @notice Returns the largest limit accepted by getOrderBooks.
    function maximumPageSize() external view returns (uint256);

    /// @notice Returns a bounded page from the active order-book registry.
    /// @dev Callers should restart pagination if the registry changes between page requests. Indexers
    ///      should use OrderBookCreated and OrderBookRemoved as the authoritative registry history.
    /// @param cursor Zero-based index of the first book to return.
    /// @param limit Maximum number of books to return.
    /// @return orderBooks Requested page of currently registered books.
    /// @return nextCursor Zero when there are no more books.
    function getOrderBooks(uint256 cursor, uint256 limit)
        external
        view
        returns (address[] memory orderBooks, uint256 nextCursor);
}
