// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Collateral-side Hyperlane warp-route mock (topology: the real
/// token locked on its home chain — `HypERC20Collateral`). Models: `wrappedToken()`
/// exposes the locked token; `transferRemote` pulls `amount` via
/// `safeTransferFrom` (locks it here) and requires the quoted native gas fee
/// as `msg.value`, mirroring the real fork's quote-then-pay flow.
///
/// Delivery is deliberately decoupled from `transferRemote` — the real
/// TokenRouter never calls back the recipient on token delivery, and the
/// paired instruction message travels independently over the mailbox. In
/// REX's topology this endpoint is usually the *sending* (origin) side of
/// its route — the corresponding receiving endpoint on the other chain is a
/// `MockSyntheticWarpRoute` — but a return leg (e.g. an aborted subscribe)
/// makes THIS side the receiver too, unlocking the token it originally
/// locked; `deliverTokens` below models that.
contract MockCollateralWarpRoute {
    using SafeERC20 for IERC20;

    struct Quote {
        address token;
        uint256 amount;
    }

    error InsufficientGasPayment();
    error SendsDisabled();

    uint256 private constant DEFAULT_GAS_QUOTE = 1e15; // non-zero by default

    IERC20 public immutable lockedToken;
    uint256 public gasQuote;
    /// @notice Hyperlane `TokenRouter.scale()`: outbound message amount = local amount * scale,
    /// inbound local amount = message amount / scale. Descriptive in the mock (default 1); deploy
    /// checks read it to prove a route pair's scales match the two ends' decimals (ADR-028 D7).
    uint256 public scale = 1;
    /// @notice Test knob: make every `transferRemote` revert (a paused route, a blacklisted sender,
    /// a proxy upgrade that breaks the send -- F-B4-1's trigger).
    bool public revertSends;
    uint256 public tokenCharge;
    uint256 public externalCharge;
    IERC20 public feeToken;
    uint256 public feeAmount;
    address public feeCollector;
    uint256 private nonce;

    constructor(IERC20 _lockedToken) {
        lockedToken = _lockedToken;
        gasQuote = DEFAULT_GAS_QUOTE;
    }

    /// @notice Test-only configuration hook to isolate a scenario from the
    /// fee-quoting defect (C1) when the test's target is something else.
    function setGasQuote(uint256 quote) external {
        gasQuote = quote;
    }

    function setScale(uint256 s) external {
        scale = s;
    }

    function setRevertSends(bool on) external {
        revertSends = on;
    }

    /// @notice Test-only knob (default 0 = zero-fee, unchanged behaviour) that
    /// makes `quoteTransferRemote` return a real-shaped length-2 quote array
    /// (`quotes[1].amount == amount + extra`, TokenRouter.sol:140) so tests can
    /// exercise BridgeAdapter's fail-closed `FeeRouteUnsupported` guard. This is
    /// not full fee support — `transferRemote` still only pulls `amount`.
    function setTokenCharge(uint256 extra) external {
        tokenCharge = extra;
    }

    /// @notice Test-only knob (default 0 = unchanged behaviour) that makes
    /// `quoteTransferRemote` append a real-shaped `quotes[2]` external-fee
    /// entry (`TokenRouter.sol:140-141`: `quotes[2] = Quote({token: token(),
    /// amount: _externalFeeAmount(...)})`), independent of the warp-route
    /// `feeAmount` modelled by `tokenCharge`. Lets tests exercise a route
    /// whose warp fee is zero but whose external fee alone exceeds `amount`.
    function setExternalCharge(uint256 extra) external {
        externalCharge = extra;
    }

    /// @notice Test knob (default feeAmount 0 = unchanged): the route pulls `feeAmount`
    /// of `feeToken` from the sender on transferRemote, modelling a WithFee warp route
    /// (live PRUV routes charge 0.75 USDC). `feeToken` may differ from the locked token.
    function setFee(IERC20 token, uint256 amount, address collector) external {
        feeToken = token;
        feeAmount = amount;
        feeCollector = collector;
    }

    function wrappedToken() external view returns (address) {
        return address(lockedToken);
    }

    function quoteTransferRemote(uint32, bytes32, uint256 amount) external view returns (Quote[] memory quotes) {
        uint256 extra = (feeAmount > 0) ? 1 : 0;
        if (tokenCharge > 0 || externalCharge > 0) {
            quotes = new Quote[](3 + extra);
            quotes[0] = Quote({token: address(0), amount: gasQuote});
            quotes[1] = Quote({token: address(lockedToken), amount: amount + tokenCharge});
            quotes[2] = Quote({token: address(lockedToken), amount: externalCharge});
        } else {
            quotes = new Quote[](2 + extra);
            quotes[0] = Quote({token: address(0), amount: gasQuote});
            quotes[1] = Quote({token: address(lockedToken), amount: amount});
        }
        if (extra == 1) quotes[quotes.length - 1] = Quote({token: address(feeToken), amount: feeAmount});
    }

    function transferRemote(uint32 dst, bytes32 recipient, uint256 amount) external payable returns (bytes32 id) {
        if (revertSends) revert SendsDisabled();
        if (msg.value < gasQuote) revert InsufficientGasPayment();
        lockedToken.safeTransferFrom(msg.sender, address(this), amount);
        if (feeAmount > 0) IERC20(feeToken).safeTransferFrom(msg.sender, feeCollector, feeAmount);
        id = keccak256(abi.encode(nonce++, dst, recipient, amount));
    }

    /// @notice Relayer-driven UNLOCK on the receiving side: releases `amount` of the locked token
    /// to `recipient`, modelling a collateral route that receives an inbound transfer (the abort
    /// return unlocks the Sepolia USDC to REXPrimary). Symmetric with
    /// MockSyntheticWarpRoute.deliverTokens; call independently of the paired instruction, either order.
    function deliverTokens(bytes32 recipient, uint256 amount) external {
        lockedToken.safeTransfer(address(uint160(uint256(recipient))), amount);
    }
}
