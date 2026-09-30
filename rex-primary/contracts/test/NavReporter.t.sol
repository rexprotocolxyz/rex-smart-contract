// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {ZeroNav} from "@rex-shared/Errors.sol";
import {NavReporter, IRWAConversion} from "../src/NavReporter.sol";
import {MockRWAConversion} from "./mocks/MockRWAConversion.sol";
import {IMailbox} from "@rex-shared/IHyperlane.sol";
import "@rex-shared-mocks/MockMailbox.sol";

contract NavReporterTest is Test {
    uint32 constant HOME_DOMAIN = 11155111;
    uint32 constant PRUV_DOMAIN = 7336;
    bytes32 constant CONSUMER = bytes32(uint256(0xCAFE));
    uint256 constant HEARTBEAT = 1800;
    uint256 constant NAV0 = 1e18;

    MockMailbox internal mailbox;
    MockRWAConversion internal source;
    NavReporter internal reporter;

    function setUp() public {
        vm.warp(1_000_000); // sane, non-zero starting timestamp
        mailbox = new MockMailbox(PRUV_DOMAIN);
        mailbox.setQuoteFee(0); // PRUV gas = 0
        source = new MockRWAConversion(NAV0);
        reporter = new NavReporter(
            IMailbox(address(mailbox)), HOME_DOMAIN, CONSUMER, IRWAConversion(address(source)), HEARTBEAT
        );
    }

    function test_firstPoke_dispatches() public {
        reporter.poke();
        assertEq(reporter.lastValue(), NAV0);
        assertEq(uint256(reporter.lastSrcTimestamp()), block.timestamp);
    }

    function test_unchangedWithinHeartbeat_noDispatch() public {
        reporter.poke();
        uint64 firstTs = reporter.lastSrcTimestamp();
        vm.warp(block.timestamp + (HEARTBEAT - 1)); // still inside the heartbeat window
        reporter.poke(); // same NAV, gate closed
        assertEq(reporter.lastSrcTimestamp(), firstTs); // no new dispatch
        assertEq(reporter.lastValue(), NAV0);
    }

    function test_changedValue_dispatchesWithinHeartbeat() public {
        reporter.poke();
        vm.warp(block.timestamp + 10); // well inside the heartbeat window
        source.setValue(NAV0 + 1);
        reporter.poke();
        assertEq(reporter.lastValue(), NAV0 + 1);
        assertEq(uint256(reporter.lastSrcTimestamp()), block.timestamp);
    }

    function test_heartbeatDue_dispatchesSameValue() public {
        reporter.poke();
        vm.warp(block.timestamp + HEARTBEAT); // heartbeat elapsed, value unchanged
        reporter.poke();
        assertEq(reporter.lastValue(), NAV0);
        assertEq(uint256(reporter.lastSrcTimestamp()), block.timestamp);
    }

    function test_sameBlockDoublePoke_secondIsNoop() public {
        reporter.poke();
        uint64 firstTs = reporter.lastSrcTimestamp();
        source.setValue(NAV0 + 5); // changed, so the gate opens...
        reporter.poke(); // ...but same block as the first dispatch -> monotonic guard returns
        assertEq(reporter.lastSrcTimestamp(), firstTs);
        assertEq(reporter.lastValue(), NAV0); // never updated
    }

    function test_zeroNav_reverts() public {
        source.setValue(0);
        vm.expectRevert(ZeroNav.selector);
        reporter.poke();
    }

    function test_underfunded_reverts() public {
        mailbox.setQuoteFee(1e14); // non-zero IGP
        vm.expectRevert(NavReporter.InsufficientGasPayment.selector);
        reporter.poke{value: 1e14 - 1}();
    }

    function test_refundsExcess() public {
        mailbox.setQuoteFee(1e14);
        address caller = address(0xBEEF);
        vm.deal(caller, 1 ether);
        uint256 before = caller.balance;
        vm.prank(caller);
        reporter.poke{value: 5e14}(); // fee 1e14, expect 4e14 back
        assertEq(caller.balance, before - 1e14);
        assertEq(reporter.lastValue(), NAV0);
    }

    function test_dispatchedBody_decodesToValueAndSrcTs() public {
        vm.recordLogs();
        reporter.poke();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 messageId;
        bool found;
        bytes32 sig = keccak256("NavDispatched(uint256,uint64,bytes32)");
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter == address(reporter) && logs[i].topics[0] == sig) {
                (,, messageId) = abi.decode(logs[i].data, (uint256, uint64, bytes32));
                found = true;
            }
        }
        assertTrue(found, "NavDispatched not emitted");

        (bytes32 recipient,,, bytes memory body,,) = mailbox.messageOf(messageId);
        assertEq(recipient, CONSUMER);
        (uint256 v, uint64 srcTs) = abi.decode(body, (uint256, uint64));
        assertEq(v, NAV0);
        assertEq(uint256(srcTs), block.timestamp);
    }

    function test_dueForDispatch_mirrorsGate() public {
        assertTrue(reporter.dueForDispatch()); // first poke pending (changed vs 0)
        reporter.poke();
        assertFalse(reporter.dueForDispatch()); // same value, same block, within heartbeat
        source.setValue(NAV0 + 1);
        vm.warp(block.timestamp + 1); // advance so the monotonic guard also passes
        assertTrue(reporter.dueForDispatch()); // changed
        source.setValue(0);
        assertFalse(reporter.dueForDispatch()); // zero source never dispatches
    }

    function test_srcTimestamp_strictlyIncreasingAcrossDispatches() public {
        uint64 prev = 0;
        // Track the warp target in a local instead of re-reading block.timestamp: under this
        // repo's default build (via_ir + optimizer_runs=1), the compiler CSEs block.timestamp
        // across loop iterations even past external calls, so vm.warp(block.timestamp + x) in a
        // loop stalls on the first value (verified with a minimal non-NavReporter repro) -- a
        // build-profile artifact, not a NavReporter.poke() bug.
        uint256 nextTs = block.timestamp;
        for (uint256 i = 0; i < 5; i++) {
            nextTs += HEARTBEAT; // force a heartbeat dispatch each round
            vm.warp(nextTs);
            source.setValue(NAV0 + i); // and change the value
            reporter.poke();
            uint64 ts = reporter.lastSrcTimestamp();
            assertGt(uint256(ts), uint256(prev));
            prev = ts;
        }
    }

    function test_constructor_rejectsZeroMailbox() public {
        vm.expectRevert(NavReporter.ZeroAddress.selector);
        new NavReporter(IMailbox(address(0)), HOME_DOMAIN, CONSUMER, IRWAConversion(address(source)), HEARTBEAT);
    }

    function test_constructor_rejectsZeroSource() public {
        vm.expectRevert(NavReporter.ZeroAddress.selector);
        new NavReporter(IMailbox(address(mailbox)), HOME_DOMAIN, CONSUMER, IRWAConversion(address(0)), HEARTBEAT);
    }

    function test_constructor_rejectsZeroConsumer() public {
        vm.expectRevert(NavReporter.ZeroAddress.selector);
        new NavReporter(IMailbox(address(mailbox)), HOME_DOMAIN, bytes32(0), IRWAConversion(address(source)), HEARTBEAT);
    }

    function test_constructor_rejectsZeroHeartbeat() public {
        vm.expectRevert(NavReporter.ZeroHeartbeat.selector);
        new NavReporter(IMailbox(address(mailbox)), HOME_DOMAIN, CONSUMER, IRWAConversion(address(source)), 0);
    }
}
