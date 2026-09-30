// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "../src/NavOracleConsumer.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/Errors.sol";
import "@rex-shared-mocks/MockMailbox.sol";

contract NavOracleConsumerTest is Test {
    MockMailbox mailbox;
    NavOracleConsumer oracle;
    uint32 constant PRUV_DOMAIN = 7336;
    uint256 constant STALENESS = 1 hours;
    uint256 constant MAX_MOVE_BPS = 1000; // 10%
    address reporter = makeAddr("reporter");
    address owner = address(this);
    address newOwner = makeAddr("newOwner");

    function setUp() public {
        vm.warp(1_000_000);
        mailbox = new MockMailbox(PRUV_DOMAIN);
        oracle = new NavOracleConsumer(IMailbox(address(mailbox)), PRUV_DOMAIN, STALENESS, MAX_MOVE_BPS);
        oracle.enrollReporter(bytes32(uint256(uint160(reporter))));
    }

    function test_M5_renounce_reverts() public {
        vm.prank(owner);
        vm.expectRevert(RenounceDisabled.selector);
        oracle.renounceOwnership();
    }

    function test_M5_transfer_is_two_step() public {
        vm.prank(owner);
        oracle.transferOwnership(newOwner);
        assertEq(oracle.owner(), owner, "still old owner until accept");
        vm.prank(newOwner);
        oracle.acceptOwnership();
        assertEq(oracle.owner(), newOwner);
    }

    function test_seed_sets_nav_and_lastUpdated() public {
        oracle.seedNav(1e18);
        assertEq(oracle.nav(), 1e18);
        assertEq(oracle.lastUpdated(), uint64(block.timestamp));
    }

    function test_seed_twice_reverts() public {
        oracle.seedNav(1e18);
        vm.expectRevert(AlreadySeeded.selector);
        oracle.seedNav(2e18);
    }

    function test_nav_reverts_stale_after_window() public {
        oracle.seedNav(1e18);
        vm.warp(block.timestamp + STALENESS + 1);
        vm.expectRevert(StalePrice.selector);
        oracle.nav();
    }

    // deliver a NAV message as the enrolled reporter, in the mailbox's process step
    function _deliverNav(uint256 value, uint64 srcTimestamp) internal {
        mailbox.setQuoteFee(0);
        vm.prank(reporter);
        bytes32 id =
            mailbox.dispatch(PRUV_DOMAIN, bytes32(uint256(uint160(address(oracle)))), abi.encode(value, srcTimestamp));
        mailbox.process(id);
    }

    function test_bridged_setNav_accepts_newer() public {
        oracle.seedNav(1e18);
        _deliverNav(1.05e18, uint64(block.timestamp + 10));
        assertEq(oracle.nav(), 1.05e18);
        assertEq(oracle.lastUpdated(), uint64(block.timestamp + 10));
    }

    function test_bridged_setNav_drops_stale_timestamp() public {
        oracle.seedNav(1e18);
        _deliverNav(1.05e18, uint64(block.timestamp + 10));
        _deliverNav(1.09e18, uint64(block.timestamp + 5)); // older srcTimestamp -> dropped
        assertEq(oracle.nav(), 1.05e18, "out-of-order NAV must not regress");
    }

    function test_bridged_setNav_sanity_bound_reverts() public {
        oracle.seedNav(1e18);
        mailbox.setQuoteFee(0);
        vm.prank(reporter);
        bytes32 id = mailbox.dispatch(
            PRUV_DOMAIN,
            bytes32(uint256(uint160(address(oracle)))),
            abi.encode(uint256(1.2e18), uint64(block.timestamp + 10))
        ); // +20% > 10% cap
        vm.expectRevert(NavSanityBound.selector);
        mailbox.process(id);
    }

    function test_M4_staleness_fails_closed_on_forward_skew() public {
        oracle.seedNav(1e18);
        // reporter clock skewed forward, but within SKEW_TOLERANCE so it is accepted: after
        // stalenessWindow of REAL (home) time with no further update, nav() must revert
        // StalePrice keyed off the home-clock receive time, not the source stamp.
        _deliverNav(1e18, uint64(block.timestamp + 30 minutes));
        vm.warp(block.timestamp + STALENESS + 1);
        vm.expectRevert(StalePrice.selector);
        oracle.nav();
    }

    function test_M4_rejects_future_srcTimestamp() public {
        oracle.seedNav(1e18);
        mailbox.setQuoteFee(0);
        vm.prank(reporter);
        bytes32 id = mailbox.dispatch(
            PRUV_DOMAIN,
            bytes32(uint256(uint160(address(oracle)))),
            abi.encode(uint256(1.01e18), uint64(block.timestamp + 2 days))
        );
        vm.expectRevert(StalePrice.selector); // future beyond tolerance rejected
        mailbox.process(id);
        assertEq(oracle.nav(), 1e18, "nav must not mutate on rejected future timestamp");
    }

    function test_M4_fresh_nav_reads_without_revert() public {
        oracle.seedNav(1e18);
        _deliverNav(1.02e18, uint64(block.timestamp + 10));
        assertEq(oracle.nav(), 1.02e18);
    }

    function test_handle_from_stranger_reverts() public {
        oracle.seedNav(1e18);
        mailbox.setQuoteFee(0);
        vm.prank(makeAddr("stranger"));
        bytes32 id = mailbox.dispatch(
            PRUV_DOMAIN,
            bytes32(uint256(uint160(address(oracle)))),
            abi.encode(uint256(1.05e18), uint64(block.timestamp + 10))
        );
        vm.expectRevert(UnauthorizedSender.selector);
        mailbox.process(id);
    }
}
