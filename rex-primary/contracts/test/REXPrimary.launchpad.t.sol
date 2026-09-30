// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {Codec} from "@rex-shared/Codec.sol";
import "../src/REXPrimary.sol";
import "@rex-shared/Receipt.sol";
import "@rex-shared/IHyperlane.sol";
import "./mocks/MockERC20.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import "@rex-shared-mocks/MockNavOracle.sol";
import "@rex-shared/INavOracle.sol";
import "../src/NavOracleConsumer.sol";
import {perSecondSchedule} from "./helpers/TestSchedule.sol";
import {IEpochSchedule} from "@rex-shared/IEpochSchedule.sol";

contract REXPrimaryLaunchpadTest is Test {
    MockMailbox mailbox;
    MockERC20 usdc;
    MockCollateralWarpRoute usdcRoute;
    MockSyntheticWarpRoute wrwaRoute;
    MockNavOracle navOracle;
    REXPrimary rex;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address feeRecipient = makeAddr("feeRecipient");
    uint32 constant PRUV_DOMAIN = 7336;
    uint64 START = uint64(block.timestamp + 1 days);
    uint64 constant PERIOD = 7 days;
    uint256 constant MIN = 100e6;
    uint16 constant FEE_BPS = 100; // 1%

    receive() external payable {}

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _deploy() internal returns (REXPrimary r) {
        r = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            0,
            START,
            PERIOD,
            MIN,
            FEE_BPS,
            feeRecipient,
            SC3Params({
                navOracle: INavOracle(address(navOracle)),
                minRedeem: 0,
                redeemCancelFeeBps: 0,
                subFulfillTimeout: 10 days,
                redemptionFeeBps: 0,
                redeemFulfillTimeout: 10 days,
                windDownWindow: 9 days,
                schedule: perSecondSchedule()
            })
        );
        r.enrollRemote(PRUV_DOMAIN, _b32(makeAddr("executor")));
    }

    function _newPool(INavOracle oracle, uint256 minimum) internal returns (REXPrimary r) {
        r = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            0,
            START,
            PERIOD,
            minimum,
            FEE_BPS,
            feeRecipient,
            SC3Params({
                navOracle: oracle,
                minRedeem: 0,
                redeemCancelFeeBps: 0,
                subFulfillTimeout: 10 days,
                redemptionFeeBps: 0,
                redeemFulfillTimeout: 10 days,
                windDownWindow: 9 days,
                schedule: perSecondSchedule()
            })
        );
        r.enrollRemote(PRUV_DOMAIN, _b32(makeAddr("executor")));
    }

    function setUp() public {
        mailbox = new MockMailbox(PRUV_DOMAIN);
        mailbox.setQuoteFee(0);
        usdc = new MockERC20("USDC", 6);
        usdcRoute = new MockCollateralWarpRoute(usdc);
        usdcRoute.setGasQuote(0);
        wrwaRoute = new MockSyntheticWarpRoute("wRWA", 6);
        navOracle = new MockNavOracle(1e18);
        rex = _deploy();
    }

    function test_deploys_in_initialized_with_config() public view {
        assertEq(uint8(rex.state()), uint8(REXPrimary.LifecycleState.Initialized));
        assertEq(rex.launchpadStart(), START);
        assertEq(rex.launchpadMinimum(), MIN);
        assertEq(rex.cancelFeeBps(), FEE_BPS);
    }

    function test_constructor_rejects_bad_config() public {
        // Hoisted out of the `new REXPrimary` argument list on purpose: creating the
        // schedule is itself a CALL, and inline it would be the call `vm.expectRevert`
        // consumes (and, below, a nonce bump that breaks the predicted address).
        IEpochSchedule sched = perSecondSchedule();
        vm.expectRevert(InvalidLaunchpadConfig.selector);
        new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            0,
            START,
            0, // period == 0
            MIN,
            FEE_BPS,
            feeRecipient,
            SC3Params({
                navOracle: INavOracle(address(navOracle)),
                minRedeem: 0,
                redeemCancelFeeBps: 0,
                subFulfillTimeout: 10 days,
                redemptionFeeBps: 0,
                redeemFulfillTimeout: 10 days,
                windDownWindow: 9 days,
                schedule: sched
            })
        );
    }

    function _fund(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.prank(who);
        usdc.approve(address(rex), amount);
    }

    function test_deposit_in_window_mints_launchpad_receipts() public {
        _fund(alice, 60e6);
        vm.warp(START);
        vm.prank(alice);
        uint256 id = rex.depositToLaunchpad(60e6);
        assertEq(id, encodeId(CLASS_LAUNCHPAD, LAUNCHPAD_ID));
        assertEq(rex.balanceOf(alice, id), 60e6);
        (uint256 totalIn,,,,) = rex.epochSide(LAUNCHPAD_ID, CLASS_LAUNCHPAD);
        assertEq(totalIn, 60e6);
    }

    function test_deposit_before_start_reverts() public {
        _fund(alice, 60e6);
        vm.prank(alice);
        vm.expectRevert(LaunchpadNotOpen.selector);
        rex.depositToLaunchpad(60e6);
    }

    function test_deposit_after_window_reverts() public {
        _fund(alice, 60e6);
        vm.warp(START + PERIOD);
        vm.prank(alice);
        vm.expectRevert(LaunchpadNotOpen.selector);
        rex.depositToLaunchpad(60e6);
    }

    function test_cancelRequest_cannot_bypass_launchpad_fee() public {
        _fund(alice, 60e6);
        vm.warp(START);
        vm.prank(alice);
        rex.depositToLaunchpad(60e6);

        // A launchpad depositor must NOT be able to dodge the cancel fee by calling the
        // subscribe-path cancelRequest on the LAUNCHPAD id. This should revert.
        uint256 id = encodeId(CLASS_LAUNCHPAD, LAUNCHPAD_ID);
        vm.prank(alice);
        vm.expectRevert(InvalidState.selector);
        rex.cancelRequest(id, 60e6);
    }

    function test_cancel_in_window_refunds_minus_fee() public {
        _fund(alice, 60e6);
        vm.warp(START);
        vm.prank(alice);
        rex.depositToLaunchpad(60e6);

        vm.prank(alice);
        rex.cancelLaunchpad(60e6); // 1% fee = 0.6e6
        assertEq(usdc.balanceOf(alice), 59_400_000);
        assertEq(usdc.balanceOf(feeRecipient), 600_000);
        (uint256 totalIn,,,,) = rex.epochSide(LAUNCHPAD_ID, CLASS_LAUNCHPAD);
        assertEq(totalIn, 0);
    }

    function test_close_before_deadline_reverts() public {
        vm.warp(START);
        vm.expectRevert(LaunchpadNotClosed.selector);
        rex.closeLaunchpad();
    }

    function test_close_below_minimum_fails_and_refunds_full() public {
        _fund(alice, 40e6); // below MIN = 100e6
        vm.warp(START);
        vm.prank(alice);
        rex.depositToLaunchpad(40e6);

        vm.warp(START + PERIOD);
        rex.closeLaunchpad(); // anyone
        assertEq(uint8(rex.state()), uint8(REXPrimary.LifecycleState.LaunchpadFail));

        vm.prank(alice);
        rex.refundLaunchpad(40e6);
        assertEq(usdc.balanceOf(alice), 40e6); // 100%, no fee
    }

    function test_close_twice_reverts() public {
        _fund(alice, 40e6);
        vm.warp(START);
        vm.prank(alice);
        rex.depositToLaunchpad(40e6);
        vm.warp(START + PERIOD);
        rex.closeLaunchpad();
        vm.expectRevert(AlreadyClosed.selector);
        rex.closeLaunchpad();
    }

    function test_close_success_bridges_and_claim_pays_pro_rata() public {
        address exec = makeAddr("executor");
        rex.enrollRemote(PRUV_DOMAIN, _b32(exec));
        _fund(alice, 60e6);
        _fund(bob, 60e6);
        vm.warp(START);
        vm.prank(alice);
        rex.depositToLaunchpad(60e6);
        vm.prank(bob);
        rex.depositToLaunchpad(60e6); // raised 120e6 >= MIN 100e6

        vm.warp(START + PERIOD);
        rex.closeLaunchpad(); // no gas needed (mock quote 0)
        assertEq(uint8(rex.state()), uint8(REXPrimary.LifecycleState.EpochBased));
        assertEq(rex.openSubBatchId(), 0, "launchpad batch is bridged, not the open one");
        assertEq(rex.nextSubBatchId(), 2, "launchpad batch minted");

        // deliver the wRWA return for batch 1 (rendezvous), then settle
        wrwaRoute.deliverTokens(_b32(address(rex)), 120e6);
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 120e6, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(exec), body);
        rex.settleSubBatch(1);

        vm.prank(alice);
        rex.claimLaunchpad(60e6);
        vm.prank(bob);
        rex.claimLaunchpad(60e6);
        assertEq(wrwaRoute.balanceOf(alice), 60e6); // pro-rata: 60/120 * 120
        assertEq(wrwaRoute.balanceOf(bob), 60e6);
    }

    function test_deposit_zero_reverts() public {
        vm.warp(START);
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        rex.depositToLaunchpad(0);
    }

    function test_cancel_after_window_reverts() public {
        _fund(alice, 60e6);
        vm.warp(START);
        vm.prank(alice);
        rex.depositToLaunchpad(60e6);
        vm.warp(START + PERIOD);
        vm.prank(alice);
        vm.expectRevert(LaunchpadNotOpen.selector);
        rex.cancelLaunchpad(60e6);
    }

    function test_close_at_exactly_minimum_succeeds() public {
        rex.enrollRemote(PRUV_DOMAIN, _b32(makeAddr("executor")));
        _fund(alice, 100e6); // exactly MIN
        vm.warp(START);
        vm.prank(alice);
        rex.depositToLaunchpad(100e6);
        vm.warp(START + PERIOD);
        rex.closeLaunchpad();
        assertEq(uint8(rex.state()), uint8(REXPrimary.LifecycleState.EpochBased), "raised == minimum is success");
        assertEq(rex.openSubBatchId(), 0, "batch bridged, not the open one");
        assertEq(rex.nextSubBatchId(), 2, "batch minted");
    }

    function test_claim_before_settle_reverts() public {
        rex.enrollRemote(PRUV_DOMAIN, _b32(makeAddr("executor")));
        _fund(alice, 120e6);
        vm.warp(START);
        vm.prank(alice);
        rex.depositToLaunchpad(120e6);
        vm.warp(START + PERIOD);
        rex.closeLaunchpad(); // bridged, not settled
        vm.prank(alice);
        vm.expectRevert(NotSettled.selector);
        rex.claimLaunchpad(120e6);
    }

    function test_refund_wrong_state_reverts() public {
        rex.enrollRemote(PRUV_DOMAIN, _b32(makeAddr("executor")));
        _fund(alice, 120e6);
        vm.warp(START);
        vm.prank(alice);
        rex.depositToLaunchpad(120e6);
        vm.warp(START + PERIOD);
        rex.closeLaunchpad(); // EpochBased, not LaunchpadFail
        vm.prank(alice);
        vm.expectRevert(WrongLifecycleState.selector);
        rex.refundLaunchpad(120e6);
    }

    /// @dev The inverse of the guard this replaces (ADR-026, amended: `closeLaunchpad` is a third
    /// `_bridgeBatch` call site the ADR's own site list missed). `closeLaunchpad` is permissionless
    /// and deadline-gated, so a stale home NAV used to block a deadline-gated state transition --
    /// the exact failure D2 removed from `initiateSubEpoch`. The read was load-bearing only while
    /// PRUV derived its deposit floor from `navAtInitiate`; PRUV now reads the price locally and
    /// merely echoes the field, so a NAV relay outage must not stop the launchpad from closing.
    ///
    /// Kept on the REAL `NavOracleConsumer` rather than a stub, and the staleness is PROVED in the
    /// same call -- `nav()` itself must still revert `StalePrice` at that timestamp. Without that
    /// assertion a fresh feed would satisfy the success case vacuously and the test would pin
    /// nothing.
    function test_close_succeeds_on_stale_nav() public {
        // fresh pool wired to a REAL consumer that is seeded then allowed to go stale
        NavOracleConsumer realOracle = new NavOracleConsumer(IMailbox(address(mailbox)), PRUV_DOMAIN, 1 hours, 1000);
        realOracle.seedNav(1e18);
        REXPrimary r = _newPool(
            INavOracle(address(realOracle)),
            100e6 /*launchpadMinimum*/
        );

        // fund a raise >= minimum so close takes the bridging branch that used to read nav()
        usdc.mint(alice, 100e6);
        vm.prank(alice);
        usdc.approve(address(r), 100e6);
        vm.warp(START);
        vm.prank(alice);
        r.depositToLaunchpad(100e6);

        vm.warp(START + PERIOD + 1 hours + 1);
        // the feed IS stale at this instant -- the display path still refuses to quote
        INavOracle oracle = r.navOracle();
        vm.expectRevert(StalePrice.selector);
        oracle.nav();

        r.closeLaunchpad();

        assertEq(uint8(r.state()), uint8(REXPrimary.LifecycleState.EpochBased), "closed despite the stale feed");
        (uint8 status, uint256 netIn,) = r.subBatch(1);
        assertEq(status, uint8(BatchStatus.Bridged), "the raise bridged");
        assertEq(netIn, 100e6, "the whole raise, in USDC, unpriced");

        // and the wire carries the 0 sentinel, not a price this call never read
        (, bytes32 instrMsgId,,) = r.batchLeg(1, false);
        (,,, bytes memory body,,) = mailbox.messageOf(instrMsgId);
        assertEq(Codec.decode(body).navAtInitiate, 0, "navAtInitiate is a 0 sentinel (ADR-026 D4)");
    }
}
