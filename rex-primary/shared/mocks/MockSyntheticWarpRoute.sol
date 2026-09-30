// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Synthetic-side Hyperlane warp-route mock (topology: `HypERC20` —
/// the router itself IS the ERC20 retail hold; there is no separate wrapped
/// token, so `wrappedToken()` is intentionally NOT implemented). Delivery
/// mints; outbound `transferRemote` burns from the sender. Both require the
/// quoted native gas fee as `msg.value`.
///
/// `deliverTokens` is decoupled from any paired origin-side `transferRemote`
/// call (real Hyperlane token delivery never calls back the recipient, and
/// carries no linkage to REX's separate instruction message) — a test drives
/// it directly with the amount it already knows was locked on the origin
/// side, so token delivery and instruction delivery can be ordered
/// independently, in either order.
contract MockSyntheticWarpRoute is ERC20 {
    using SafeERC20 for IERC20;

    struct Quote {
        address token;
        uint256 amount;
    }

    error InsufficientGasPayment();
    error SendsDisabled();

    uint256 private constant DEFAULT_GAS_QUOTE = 1e15; // non-zero by default

    uint8 private immutable _decimals;
    uint256 public gasQuote;
    /// @notice Hyperlane `TokenRouter.scale()`: outbound message amount = local amount * scale,
    /// inbound local amount = message amount / scale. Descriptive in the mock (default 1); deploy
    /// checks read it to prove a route pair's scales match the two ends' decimals (ADR-028 D7).
    uint256 public scale = 1;
    /// @notice Test knob: make every `transferRemote` revert (a paused route, a blacklisted sender,
    /// a proxy upgrade that breaks the send -- F-B4-1's trigger).
    bool public revertSends;
    IERC20 public feeToken;
    uint256 public feeAmount;
    address public feeCollector;
    uint256 private nonce;

    constructor(string memory name_, uint8 decimals_) ERC20(name_, name_) {
        _decimals = decimals_;
        gasQuote = DEFAULT_GAS_QUOTE;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
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

    /// @notice Test knob (default feeAmount 0 = unchanged): the route pulls `feeAmount`
    /// of `feeToken` from the sender on transferRemote, modelling a WithFee warp route
    /// (live PRUV routes charge 0.75 USDC). `feeToken` may differ from the routed token.
    function setFee(IERC20 token, uint256 amount, address collector) external {
        feeToken = token;
        feeAmount = amount;
        feeCollector = collector;
    }

    function quoteTransferRemote(uint32, bytes32, uint256) external view returns (Quote[] memory quotes) {
        uint256 extra = (feeAmount > 0) ? 1 : 0;
        quotes = new Quote[](1 + extra);
        quotes[0] = Quote({token: address(0), amount: gasQuote});
        if (extra == 1) quotes[1] = Quote({token: address(feeToken), amount: feeAmount});
    }

    function transferRemote(uint32 dst, bytes32 recipient, uint256 amount)
        external
        payable
        virtual
        returns (bytes32 id)
    {
        if (revertSends) revert SendsDisabled();
        if (msg.value < gasQuote) revert InsufficientGasPayment();
        _burn(msg.sender, amount);
        if (feeAmount > 0) IERC20(feeToken).safeTransferFrom(msg.sender, feeCollector, feeAmount);
        id = keccak256(abi.encode(nonce++, dst, recipient, amount));
    }

    /// @notice Relayer-driven credit on the destination chain — call independently
    /// of the paired instruction's mailbox delivery, in either order.
    function deliverTokens(bytes32 recipient, uint256 amount) external {
        _mint(address(uint160(uint256(recipient))), amount);
    }
}
