// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice A single fee component returned by `quoteTransferRemote`.
/// Per `docs/references/hyperlane-bridge.md` §"Send a token + paired instruction":
/// `[0]` = interchain gas in **native** (`token == address(0)`), `[1]` = amount +
/// feeRecipient fee, `[2]` = external fee (0 for plain routes).
struct Quote {
    address token;
    uint256 amount;
}

/// @notice Minimal Hyperlane warp-route surface BridgeAdapter needs.
/// @dev The fork is **quote-and-pay**: quote first, then attach the quoted native
/// gas as `msg.value` (`hyperlane-bridge.md` §"Gas / IGP"; `config-values.md`
/// "Interchain gas payment on the fork" — confirmed live on testnet).
interface IWarpRoute {
    function quoteTransferRemote(uint32 dst, bytes32 recipient, uint256 amount)
        external
        view
        returns (Quote[] memory);

    function transferRemote(uint32 dst, bytes32 recipient, uint256 amount) external payable returns (bytes32);

    /// @dev **Collateral routes only.** A synthetic route (`HypERC20`) IS the ERC20 —
    /// it wraps nothing and does not implement this. Never call it on a synthetic side.
    function wrappedToken() external view returns (address);
}

/// @notice Minimal Hyperlane mailbox surface BridgeAdapter needs: quote + dispatch an
/// outbound message and check delivery. `process` is the relayer's entry
/// point, not the adapter's — intentionally omitted here.
interface IMailbox {
    function quoteDispatch(uint32 dst, bytes32 recipient, bytes calldata body) external view returns (uint256);

    function dispatch(uint32 dst, bytes32 recipient, bytes calldata body) external payable returns (bytes32);

    function delivered(bytes32 id) external view returns (bool);
}

/// @notice Inbound handler surface a Hyperlane mailbox calls on message delivery.
interface IMessageRecipient {
    function handle(uint32 origin, bytes32 sender, bytes calldata body) external payable;
}
