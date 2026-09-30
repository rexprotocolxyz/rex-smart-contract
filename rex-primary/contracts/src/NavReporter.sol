// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IMailbox} from "@rex-shared/IHyperlane.sol";
import {ZeroNav} from "@rex-shared/Errors.sol";

/// @notice Minimal PRUV NAV source surface (RWAConversion / RWAFixedConversion, pruv-interface.md).
interface IRWAConversion {
    function value() external view returns (uint256); // NAV, 18-dec, parity 1e18
}

/// @notice PRUV-side NAV feed (ADR-004 A1, spec section 9). Reads RWAConversion.value() and dispatches
/// (value, srcTimestamp) over the Hyperlane mailbox to the home NavOracleConsumer -- but only when the
/// value changed or a heartbeat is due (Option B, on-chain dispatch gate). Immutable, permissionless,
/// no owner (ADR-011: versioned by redeployment). A poke can never inject a price: the value always
/// comes from the source, so poke() only triggers a relay of the source's own number.
contract NavReporter is ReentrancyGuard {
    IMailbox public immutable mailbox;
    uint32 public immutable homeDomain;
    bytes32 public immutable consumer;
    IRWAConversion public immutable source;
    uint256 public immutable heartbeat;

    uint256 public lastValue;
    uint64 public lastSrcTimestamp; // also serves as lastDispatchedAt

    event NavDispatched(uint256 value, uint64 srcTimestamp, bytes32 messageId);

    error InsufficientGasPayment();
    error RefundFailed();
    error ZeroAddress();
    error ZeroHeartbeat();

    constructor(IMailbox mailbox_, uint32 homeDomain_, bytes32 consumer_, IRWAConversion source_, uint256 heartbeat_) {
        // Live deploy is a raw `cast send --create` that bypasses the deploy script's sanity-asserts,
        // and the contract is immutable (ADR-011) -- a mis-wired arg can only be fixed by redeploy, so
        // fail loud at construction (matches the SC6a setter zero-addr guards). heartbeat_ == 0 would
        // make heartbeatDue always true, dispatching every new-block poke (IGP waste where fee > 0).
        if (address(mailbox_) == address(0) || address(source_) == address(0) || consumer_ == bytes32(0)) {
            revert ZeroAddress();
        }
        if (heartbeat_ == 0) revert ZeroHeartbeat();
        mailbox = mailbox_;
        homeDomain = homeDomain_;
        consumer = consumer_;
        source = source_;
        heartbeat = heartbeat_;
    }

    /// @notice Relay the current source NAV to the home consumer when the dispatch gate opens.
    /// Permissionless: the on-chain gate + the consumer's accept-only-newer dedup + the PRUV mailbox
    /// sender whitelist make a redundant poke a no-op, not an attack surface. Payable: the caller
    /// attaches the quoted IGP fee (0 on PRUV); any excess is refunded.
    function poke() external payable nonReentrant {
        uint256 v = source.value();
        if (v == 0) revert ZeroNav();

        bool changed = v != lastValue;
        bool heartbeatDue = block.timestamp - lastSrcTimestamp >= heartbeat;
        if (!changed && !heartbeatDue) return; // gate closed: no dispatch, no IGP spent

        // Consumer accepts only a strictly-newer srcTimestamp; never pay IGP for a same-block dispatch
        // it would drop. First poke: lastSrcTimestamp == 0, so this passes.
        if (block.timestamp <= lastSrcTimestamp) return;

        uint64 srcTs = uint64(block.timestamp);
        bytes memory body = abi.encode(v, srcTs);
        uint256 fee = mailbox.quoteDispatch(homeDomain, consumer, body);
        if (msg.value < fee) revert InsufficientGasPayment();

        // Effects before interaction.
        lastValue = v;
        lastSrcTimestamp = srcTs;

        bytes32 messageId = mailbox.dispatch{value: fee}(homeDomain, consumer, body);
        emit NavDispatched(v, srcTs, messageId);

        uint256 refund = msg.value - fee;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @notice True if a poke() right now would dispatch. Pure read for the Relay to skip no-op txs.
    function dueForDispatch() external view returns (bool) {
        uint256 v = source.value();
        if (v == 0) return false;
        bool gate = v != lastValue || block.timestamp - lastSrcTimestamp >= heartbeat;
        return gate && block.timestamp > lastSrcTimestamp;
    }
}
