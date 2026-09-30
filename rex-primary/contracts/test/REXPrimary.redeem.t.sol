// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "../src/REXPrimary.sol";
import "@rex-shared/Receipt.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/INavOracle.sol";
import "@rex-shared/Errors.sol";
import "./mocks/MockERC20.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import "@rex-shared-mocks/MockNavOracle.sol";
import {EpochSchedule} from "../src/EpochSchedule.sol";
import {IEpochSchedule} from "@rex-shared/IEpochSchedule.sol";
import {perSecondSchedule, warpToNextPeriod} from "./helpers/TestSchedule.sol";

/// @notice Shared redeem fixture. Extracted so `REXPrimary.lockOnConsume.t.sol` can reuse the exact
/// same deployment (`minRedeem` above every amount these suites redeem, so a consumed residual accrues
/// into a below-minimum batch and never bridges) instead of duplicating it.
contract REXPrimaryTestBase is Test {
    MockMailbox mailbox;
    MockERC20 usdc;
    MockCollateralWarpRoute usdcRoute;
    MockSyntheticWarpRoute wrwaRoute;
    MockNavOracle navOracle;
    REXPrimary rex;
    /// @notice The real ADR-025 calendar this fixture deploys with (NOT the one-second grid the
    /// pre-schedule suites use): a genuine grid whose first moment is one full period AFTER the
    /// launchpad closes (spec 1.8), so `REXPrimary.schedule.t.sol` can test the floor from both
    /// sides. One hour, not 30 days, so `_initiate`'s step to the next moment stays small and
    /// changes nothing these suites assert.
    EpochSchedule schedule;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    /// @notice `REXPrimary`'s owner: `Ownable(msg.sender)` at construction, i.e. this test.
    address owner = address(this);
    uint32 constant PRUV_DOMAIN = 7336;
    uint64 constant EPOCH_DURATION = 1 hours;
    /// @notice The `minRedeem` this fixture deploys with. Denominated in **wRWA** (ADR-026 D2: the
    /// gate compares the accrued wRWA against it directly, no price), and the mock wRWA route is
    /// **6-decimal** (`MockSyntheticWarpRoute("wRWA", 6)` below) -- so this is 1,000 wRWA, not 1e-15
    /// of one. Single source of truth: the ctor argument and every threshold assertion read THIS.
    uint256 constant MIN_REDEEM_WRWA = 1_000e6;

    function setUp() public virtual {
        mailbox = new MockMailbox(PRUV_DOMAIN);
        usdc = new MockERC20("USDC", 6);
        usdcRoute = new MockCollateralWarpRoute(usdc);
        wrwaRoute = new MockSyntheticWarpRoute("wRWA", 6);
        navOracle = new MockNavOracle(1e18);
        uint64 lpStart = uint64(block.timestamp + 1);
        uint64 lpPeriod = 1 days;
        schedule = new EpochSchedule(lpStart + lpPeriod + EPOCH_DURATION, EPOCH_DURATION, EPOCH_DURATION);
        rex = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            0,
            lpStart,
            lpPeriod,
            0,
            0,
            address(0xFEE),
            SC3Params({
                navOracle: INavOracle(address(navOracle)),
                // Above every amount these suites redeem before initiateSubEpoch (100e6): they test
                // intake/cancel-while-unlocked, not SC5a bridge execution (REXPrimary.redeemExec.t.sol),
                // so the redeem side stays Accumulating (never bridges) here -- proving the lock-on-consume
                // guard (spec §14) fires from mere accrual alone, independent of the bridge threshold.
                minRedeem: MIN_REDEEM_WRWA,
                redeemCancelFeeBps: 0,
                subFulfillTimeout: 10 days,
                redemptionFeeBps: 0,
                redeemFulfillTimeout: 10 days,
                windDownWindow: 9 days,
                schedule: IEpochSchedule(address(schedule))
            })
        );
        vm.warp(rex.launchpadStart() + rex.launchpadPeriod());
        rex.closeLaunchpad();
    }

    function _giveWrwa(address who, uint256 amount) internal {
        wrwaRoute.deliverTokens(bytes32(uint256(uint160(who))), amount);
    }

    function _requestRedeem(address who, uint256 amount) internal returns (uint256 id) {
        _giveWrwa(who, amount);
        vm.startPrank(who);
        IERC20(address(wrwaRoute)).approve(address(rex), amount);
        id = rex.requestRedeem(amount);
        vm.stopPrank();
    }

    function _requestDeposit(address who, uint256 amount) internal returns (uint256 id) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(rex), amount);
        id = rex.requestDeposit(amount);
        vm.stopPrank();
    }

    /// @dev Run the epoch. Permissionless since ADR-025 (no keeper), but schedule-gated: step to
    /// the next scheduled moment first if we are not there yet. Reads `lastClosedPeriod` rather
    /// than counting calls, so it stays correct however many epochs a test runs.
    function _initiate() internal {
        warpToNextPeriod(rex);
        rex.initiateSubEpoch();
    }
}

contract REXPrimaryRedeemTest is REXPrimaryTestBase {
    function test_requestRedeem_mints_red_epoch_one_for_one() public {
        uint256 id = _requestRedeem(alice, 100e6);
        assertEq(id, encodeId(CLASS_RED_EPOCH, 1), "RED_EPOCH id for epoch 1");
        assertEq(rex.balanceOf(alice, id), 100e6, "receipt == wRWA escrowed");
        assertEq(IERC20(address(wrwaRoute)).balanceOf(address(rex)), 100e6, "wRWA escrowed");
        (uint256 totalIn,,,, bool locked) = rex.epochSide(1, CLASS_RED_EPOCH);
        assertEq(totalIn, 100e6);
        assertFalse(locked);
    }

    function test_requestRedeem_two_holders_share_one_id() public {
        _requestRedeem(alice, 100e6);
        uint256 id2 = _requestRedeem(bob, 400e6);
        assertEq(id2, encodeId(CLASS_RED_EPOCH, 1));
        (uint256 totalIn,,,,) = rex.epochSide(1, CLASS_RED_EPOCH);
        assertEq(totalIn, 500e6);
    }

    function test_requestRedeem_zero_reverts() public {
        vm.expectRevert(ZeroAmount.selector);
        rex.requestRedeem(0);
    }

    function test_cancelRedeem_refunds_wrwa() public {
        uint256 id = _requestRedeem(alice, 100e6);
        vm.prank(alice);
        rex.cancelRequest(id, 40e6);
        assertEq(rex.balanceOf(alice, id), 60e6);
        assertEq(IERC20(address(wrwaRoute)).balanceOf(alice), 40e6, "wRWA refunded (fee 0)");
        (uint256 totalIn,,,,) = rex.epochSide(1, CLASS_RED_EPOCH);
        assertEq(totalIn, 60e6);
    }

    function test_cancelRedeem_charges_wrwa_fee() public {
        address fee = makeAddr("fee");
        MockNavOracle o = new MockNavOracle(1e18);
        REXPrimary r = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            0,
            uint64(block.timestamp + 1),
            1 days,
            0,
            0,
            fee,
            SC3Params({
                navOracle: INavOracle(address(o)),
                minRedeem: 0,
                redeemCancelFeeBps: 100,
                subFulfillTimeout: 10 days,
                redemptionFeeBps: 0,
                redeemFulfillTimeout: 10 days,
                windDownWindow: 9 days,
                schedule: perSecondSchedule()
            })
        );
        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad();

        wrwaRoute.deliverTokens(bytes32(uint256(uint160(alice))), 100e6);
        vm.startPrank(alice);
        IERC20(address(wrwaRoute)).approve(address(r), 100e6);
        uint256 id = r.requestRedeem(100e6);
        r.cancelRequest(id, 40e6); // 1% of 40e6 = 0.4e6 fee in wRWA
        vm.stopPrank();

        assertEq(IERC20(address(wrwaRoute)).balanceOf(fee), 400_000, "1% wRWA fee to recipient");
        assertEq(IERC20(address(wrwaRoute)).balanceOf(alice), 39_600_000, "net wRWA refund");
    }

    /// @dev Lock-on-consume still happens (spec §7.3/§7.4 step 2, §14) -- `initiateSubEpoch`
    /// consuming this epoch's redeem side into a batch sets `locked`, mirroring `sub.locked`. What
    /// ADR-027 changed is what the flag is USED for: `cancelRequest` no longer asks it, it asks
    /// whether the batch has left `Accumulating`. The flag still marks a consumed side, and the
    /// cross-epoch hazard it used to guard is now held by the counter decrement instead --
    /// REXPrimary.lockOnConsume.t.sol carries the mutation-checked pin, and
    /// REXPrimaryRedeemExecTest.test_redeem_locked_blocks_cross_epoch_cancel the bridged case.
    function test_redeemSideLocksOnConsume_butStaysCancellableWhileAccruing() public {
        uint256 id = _requestRedeem(alice, 100e6);
        _initiate(); // consuming the residual locks it
        (,,,, bool locked) = rex.epochSide(1, CLASS_RED_EPOCH);
        assertTrue(locked, "redeem side locks once initiateSubEpoch consumes it");

        // ...and the exit is open regardless, because the batch is still Accumulating and the
        // escrow is therefore still here.
        vm.prank(alice);
        rex.cancelRequest(id, 100e6);
        assertEq(IERC20(address(wrwaRoute)).balanceOf(alice), 100e6, "alice's own wRWA, returned");
        assertEq(rex.liveRedeemEscrow(), 0, "escrow released with her");
    }
}

/// @notice ADR-026 D2 -- the redeem bridge gate is denominated in wRWA and consults no price. Its own
/// contract (not `REXPrimaryRedeemTest`) because it must bridge, which the shared fixture deliberately
/// never does: it needs the zero-fee mocks and an enrolled remote.
contract REXPrimaryRedeemGateTest is REXPrimaryTestBase {
    address executor = makeAddr("gateExecutor");

    receive() external payable {}

    function _readyToBridge() internal {
        mailbox.setQuoteFee(0);
        wrwaRoute.setGasQuote(0);
        usdcRoute.setGasQuote(0);
        rex.enrollRemote(PRUV_DOMAIN, bytes32(uint256(uint160(executor))));
    }

    function _redeemBatchStatus(uint64 batchId) internal view returns (uint8 status) {
        (status,,,) = rex.redeemBatch(batchId);
    }

    /// @dev The gate must DISCRIMINATE, not merely accept: one wRWA unit under the threshold accrues,
    /// and the very next unit -- accrued into the same batch by a second epoch -- bridges. If both
    /// cases landed on the same side of the branch the test would prove nothing. No NAV is consulted
    /// either way (the fixture's NAV is 1e18, so the two denominations are numerically identical
    /// here; `REXPrimary.navparam.t.sol` is where a NAV != 1 separates them).
    function test_redeem_batch_gate_compares_wrwa_directly() public {
        _readyToBridge();

        _requestRedeem(alice, MIN_REDEEM_WRWA - 1);
        _initiate();
        assertEq(
            _redeemBatchStatus(1),
            uint8(BatchStatus.Accumulating),
            "one wRWA unit under minRedeem must accrue, not bridge"
        );

        _requestRedeem(bob, 1);
        _initiate();
        assertEq(_redeemBatchStatus(1), uint8(BatchStatus.Bridged), "exactly at minRedeem in wRWA must bridge");
        (, uint256 netIn,,) = rex.redeemBatch(1);
        assertEq(netIn, MIN_REDEEM_WRWA, "the batch bridged the accrued wRWA, unpriced");
    }
}
