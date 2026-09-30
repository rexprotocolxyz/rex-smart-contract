// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/Wire.sol";
import {Codec} from "@rex-shared/Codec.sol";
import "@rex-shared/Errors.sol";
import "./libraries/State.sol";

/// @notice Shared cross-chain plumbing extended by REXPrimary (home chain) and
/// PruvExecutor (PRUV): enrolls a peer router per remote domain, sends a
/// paired token-leg + instruction-leg to that peer, and rendezvous-checks
/// inbound deliveries against the enrolled (origin, sender) pair before
/// dispatching to the subclass's settlement logic.
/// @dev Inbound messages are dispatched to the virtual _onInstruction, which
/// each subclass implements.
abstract contract BridgeAdapter is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    IMailbox public immutable mailbox;
    mapping(uint32 => bytes32) public remoteRouter;

    event RemoteEnrolled(uint32 indexed domain, bytes32 indexed router);

    constructor(IMailbox _mailbox) Ownable(msg.sender) {
        mailbox = _mailbox;
    }

    /// @dev ADR-011 is redeploy-only: a renounce would permanently brick every onlyOwner
    /// governance/recovery power (unpause, lifecycle, sweep, setSchedule) with no path back.
    /// Drop the inherited `onlyOwner` so EVERY caller gets `RenounceDisabled` (not a mix of
    /// `OwnableUnauthorizedAccount`/`RenounceDisabled`). Marked `pure`: it only reverts, touching
    /// no state, and CI's `--deny warnings` gate promotes solc's mutability-restriction hint
    /// (2018) to a hard error.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Register the trusted router address for a remote domain.
    function enrollRemote(uint32 domain, bytes32 router) external onlyOwner {
        remoteRouter[domain] = router;
        emit RemoteEnrolled(domain, router);
    }

    /// @dev Send the paired token-leg (warp route transfer) + instruction-leg
    /// (mailbox dispatch) to the enrolled router on `dst`.
    ///
    /// The fork is **quote-and-pay** (`hyperlane-bridge.md` §"Send a token + paired
    /// instruction" steps 1,3,4): quote both legs, then attach the quoted native gas
    /// as `msg.value`. The native must already be held by this contract — the caller
    /// funds it (see `REXPrimary.initiateSubEpoch`, which is `payable` and refunds the
    /// remainder).
    ///
    /// `approveToken` is the ERC20 the route pulls via `transferFrom` — pass it for a
    /// **collateral** route, or `address(0)` for a **synthetic** route, which burns from
    /// this contract and needs no approval (`hyperlane-bridge.md:50` — "approve the
    /// collateral router ... collateral side only").
    function _sendPair(uint32 dst, IWarpRoute route, IERC20 approveToken, uint256 amount, Instruction memory instr)
        internal
        returns (Leg memory)
    {
        bytes32 to = remoteRouter[dst];
        if (to == bytes32(0)) revert UnenrolledRemote();

        bytes memory body = Codec.encode(instr);
        Quote[] memory quotes = route.quoteTransferRemote(dst, to, amount);
        uint256 tokenGas = quotes.length > 0 ? quotes[0].amount : 0;
        uint256 msgGas = mailbox.quoteDispatch(dst, to, body);
        if (address(this).balance < tokenGas + msgGas) revert InsufficientGasPayment();

        _approveForRoute(route, quotes, approveToken, amount);

        bytes32 tId = route.transferRemote{value: tokenGas}(dst, to, amount);
        bytes32 iId = mailbox.dispatch{value: msgGas}(dst, to, body);
        return Leg({tokenMsgId: tId, instrMsgId: iId, returnedAmount: 0, returnReceived: false, retKind: instr.kind});
    }

    /// @notice Inbound Hyperlane delivery entry point. Only the local mailbox
    /// may call this, and only for a sender enrolled as the router for `origin`.
    function handle(uint32 origin, bytes32 sender, bytes calldata body) external payable nonReentrant {
        if (msg.sender != address(mailbox) || remoteRouter[origin] != sender) revert UnauthorizedSender();
        Instruction memory instr = Codec.decode(body);
        _onInstruction(origin, instr);
    }

    /// @dev Subclass hook: react to a rendezvous-verified inbound instruction.
    function _onInstruction(uint32 origin, Instruction memory instr) internal virtual;

    /// @dev Approve every token `route` will pull for this transfer. Base default covers the
    /// fee-free collateral/synthetic case REXPrimary uses; PruvExecutor overrides to also fund
    /// WithFee-route fees (AT-190). `quotes` is unused by the default but drives the override.
    function _approveForRoute(IWarpRoute route, Quote[] memory, IERC20 approveToken, uint256 amount) internal virtual {
        if (address(approveToken) != address(0)) approveToken.forceApprove(address(route), amount);
    }
}
