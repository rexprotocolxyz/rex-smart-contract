// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMessageRecipient} from "@rex-shared/IHyperlane.sol";

// Deferred-delivery single-EVM stand-in for a Hyperlane mailbox: one instance
// hosts each "chain". dispatch() only records the message; handle() is called
// later, in a separate process() call — never nested inside dispatch(). This
// models real async Hyperlane delivery and avoids a self-reentrancy revert
// when the same contract's outbound trigger and inbound handle are both
// nonReentrant. No peer/setRecipient wiring — the recipient address is
// carried in the dispatch call itself.
//
// Honest fee model: the real Mailbox.dispatch is payable and requires the
// caller to have quoted + paid the IGP fee first (quoteDispatch). This mock
// mirrors that — quoteFee defaults non-zero (configurable via setQuoteFee)
// so a caller that never quotes/pays (see BridgeAdapter._sendPair, C1) reverts.
contract MockMailbox {
    struct Msg {
        bytes32 recipient;
        uint32 origin;
        bytes32 sender;
        bytes body;
        bool delivered;
        bool exists;
    }

    error MessageNotFound();
    error AlreadyDelivered();
    error InsufficientGasPayment();

    /// @notice Additive, tooling-only signal (SC8a Task 7 local devnet relayer) -- the real
    /// Hyperlane mailbox has no such event; a real relayer watches its own mempool/indexer,
    /// not a contract event. Emitted at the end of `dispatch` purely so a TS relayer can
    /// `watchContractEvent` for it instead of polling `delivered()` blindly. Additive only:
    /// changes no existing behavior, return value, or revert condition.
    event Dispatch(bytes32 indexed id, uint32 indexed destination, bytes32 recipient);

    uint256 private constant DEFAULT_QUOTE_FEE = 1e14; // 0.0001 native, non-zero by default

    uint32 public immutable localDomain;
    uint256 public quoteFee;
    uint256 private nonce;
    mapping(bytes32 => Msg) private messages;

    constructor(uint32 _localDomain) {
        localDomain = _localDomain;
        quoteFee = DEFAULT_QUOTE_FEE;
    }

    /// @notice Test-only configuration hook — real Hyperlane fee is whatever the
    /// IGP quotes; tests that want to isolate a scenario from the fee-quoting
    /// defect (C1) can zero this out explicitly.
    function setQuoteFee(uint256 fee) external {
        quoteFee = fee;
    }

    function quoteDispatch(uint32, bytes32, bytes calldata) external view returns (uint256) {
        return quoteFee;
    }

    function dispatch(uint32 dst, bytes32 recipient, bytes calldata body) external payable returns (bytes32 id) {
        if (msg.value < quoteFee) revert InsufficientGasPayment();
        id = keccak256(abi.encode(nonce++, dst, recipient, body));
        messages[id] = Msg({
            recipient: recipient,
            origin: localDomain,
            sender: bytes32(uint256(uint160(msg.sender))),
            body: body,
            delivered: false,
            exists: true
        });
        emit Dispatch(id, dst, recipient);
    }

    function process(bytes32 id) external payable {
        Msg storage m = messages[id];
        if (!m.exists) revert MessageNotFound();
        if (m.delivered) revert AlreadyDelivered();
        m.delivered = true;
        IMessageRecipient(address(uint160(uint256(m.recipient)))).handle{value: msg.value}(m.origin, m.sender, m.body);
    }

    function delivered(bytes32 id) external view returns (bool) {
        return messages[id].delivered;
    }

    /// @notice Relayer read-side (SC8c-1): expose a stored message so a TS relayer can move it
    /// to the other mailbox instance. The real Hyperlane relayer reads the origin chain's
    /// dispatched message the same way (from the origin mailbox / indexer) before submitting it
    /// to the destination mailbox. Additive; `messages` stays private.
    function messageOf(bytes32 id)
        external
        view
        returns (bytes32 recipient, uint32 origin, bytes32 sender, bytes memory body, bool delivered_, bool exists)
    {
        Msg storage m = messages[id];
        return (m.recipient, m.origin, m.sender, m.body, m.delivered, m.exists);
    }

    /// @notice Relayer write-side (SC8c-1): submit a message that originated on ANOTHER mailbox
    /// instance to THIS (destination) mailbox and deliver it. Models a real relayer moving a
    /// message across chains: `msg.sender` of the recipient's `handle` is THIS mailbox and
    /// `origin` is the SOURCE domain, so the recipient's origin+sender rendezvous check passes.
    /// Mirrors `process`: mark delivered THEN call `handle`, so a recipient revert rolls the
    /// whole delivery back and the same `id` can be relayed again (paired-message rendezvous).
    function deliverInbound(bytes32 id, uint32 origin, bytes32 sender, bytes32 recipient, bytes calldata body)
        external
        payable
    {
        Msg storage m = messages[id];
        if (m.delivered) revert AlreadyDelivered();
        messages[id] =
            Msg({recipient: recipient, origin: origin, sender: sender, body: body, delivered: true, exists: true});
        IMessageRecipient(address(uint160(uint256(recipient)))).handle{value: msg.value}(origin, sender, body);
    }
}
