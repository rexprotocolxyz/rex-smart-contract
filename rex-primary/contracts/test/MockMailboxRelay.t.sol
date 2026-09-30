// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import {IMessageRecipient} from "@rex-shared/IHyperlane.sol";

/// @notice Records the exact (origin, sender, body) its mailbox delivered, so the relay
/// primitives can be asserted against what a real recipient's `handle` would observe.
contract RecordingRecipient is IMessageRecipient {
    uint32 public lastOrigin;
    bytes32 public lastSender;
    bytes public lastBody;
    address public lastCaller;
    bool public revertNext;

    error Rejected();

    function setRevertNext(bool v) external {
        revertNext = v;
    }

    function handle(uint32 origin, bytes32 sender, bytes calldata body) external payable {
        if (revertNext) revert Rejected();
        lastCaller = msg.sender;
        lastOrigin = origin;
        lastSender = sender;
        lastBody = body;
    }
}

contract MockMailboxRelayTest is Test {
    uint32 constant HOME_DOMAIN = 11155111;
    uint32 constant PRUV_DOMAIN = 7336;

    MockMailbox home;
    MockMailbox fund;
    RecordingRecipient recipient;

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function setUp() public {
        home = new MockMailbox(HOME_DOMAIN);
        fund = new MockMailbox(PRUV_DOMAIN);
        home.setQuoteFee(0);
        fund.setQuoteFee(0);
        recipient = new RecordingRecipient();
    }

    /// A message dispatched on `home` is readable via `messageOf` and can be relayed onto
    /// `fund` with the SOURCE origin/sender, delivered to the recipient by the DEST mailbox.
    function test_relay_moves_message_across_instances() public {
        bytes memory body = hex"c0ffee";
        bytes32 id = home.dispatch(PRUV_DOMAIN, _b32(address(recipient)), body);

        (bytes32 rcpt, uint32 origin, bytes32 sender, bytes memory outBody, bool delivered, bool exists) =
            home.messageOf(id);
        assertEq(rcpt, _b32(address(recipient)));
        assertEq(origin, HOME_DOMAIN, "origin is the SOURCE mailbox domain");
        assertEq(sender, _b32(address(this)));
        assertEq(outBody, body);
        assertFalse(delivered);
        assertTrue(exists);

        fund.deliverInbound(id, origin, sender, rcpt, outBody);

        assertTrue(fund.delivered(id), "dest mailbox marks it delivered");
        assertEq(recipient.lastCaller(), address(fund), "recipient sees the DEST mailbox as caller");
        assertEq(recipient.lastOrigin(), HOME_DOMAIN);
        assertEq(recipient.lastSender(), _b32(address(this)));
        assertEq(recipient.lastBody(), body);
    }

    /// A recipient revert rolls back the delivered mark, so the same id can be relayed again
    /// (models the paired-message rendezvous: instruction-before-tokens reverts, retried after).
    function test_deliverInbound_revert_rolls_back() public {
        bytes memory body = hex"01";
        bytes32 id = home.dispatch(PRUV_DOMAIN, _b32(address(recipient)), body);
        (, uint32 origin, bytes32 sender,,,) = home.messageOf(id);

        recipient.setRevertNext(true);
        vm.expectRevert(RecordingRecipient.Rejected.selector);
        fund.deliverInbound(id, origin, sender, _b32(address(recipient)), body);
        assertFalse(fund.delivered(id), "a reverted delivery leaves it undelivered");

        recipient.setRevertNext(false);
        fund.deliverInbound(id, origin, sender, _b32(address(recipient)), body);
        assertTrue(fund.delivered(id), "retried successfully");
    }

    /// Re-delivering an already-delivered id reverts, mirroring `process`.
    function test_deliverInbound_double_delivery_reverts() public {
        bytes memory body = hex"02";
        bytes32 id = home.dispatch(PRUV_DOMAIN, _b32(address(recipient)), body);
        (, uint32 origin, bytes32 sender,,,) = home.messageOf(id);
        fund.deliverInbound(id, origin, sender, _b32(address(recipient)), body);
        vm.expectRevert(MockMailbox.AlreadyDelivered.selector);
        fund.deliverInbound(id, origin, sender, _b32(address(recipient)), body);
    }
}
