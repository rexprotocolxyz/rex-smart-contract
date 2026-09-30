// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {Codec} from "@rex-shared/Codec.sol";
import "../src/REXPrimary.sol";
import {REXLens} from "../src/REXLens.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/Wire.sol";
import "@rex-shared/Errors.sol";
import "./mocks/MockERC20.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import "@rex-shared-mocks/MockNavOracle.sol";
import "@rex-shared/INavOracle.sol";
import {perSecondSchedule} from "./helpers/TestSchedule.sol";
import {IEpochSchedule} from "@rex-shared/IEpochSchedule.sol";

contract REXPrimaryFeeGovTest is Test {
    MockMailbox mailbox;
    MockERC20 usdc;
    MockCollateralWarpRoute usdcRoute;
    MockSyntheticWarpRoute wrwaRoute;
    MockNavOracle navOracle;
    REXPrimary rex;
    REXLens lens;
    uint32 constant PRUV_DOMAIN = 7336;
    address alice = makeAddr("alice"); // redeemer, Task 7 fix-round-2: first requester into an epoch
    address bob = makeAddr("bob"); // redeemer, Task 7 snapshot proof
    address executor = makeAddr("executor");
    receive() external payable {}

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function setUp() public {
        mailbox = new MockMailbox(PRUV_DOMAIN);
        mailbox.setQuoteFee(0);
        usdc = new MockERC20("USDC", 6);
        usdcRoute = new MockCollateralWarpRoute(usdc);
        usdcRoute.setGasQuote(0);
        wrwaRoute = new MockSyntheticWarpRoute("wRWA", 6);
        wrwaRoute.setGasQuote(0);
        navOracle = new MockNavOracle(1e18);
        rex = new REXPrimary(
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
            makeAddr("fee"),
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
        lens = new REXLens();
    }

    /// @dev A second deployment with a nonzero `redemptionFeeBps` (mirrors
    /// REXPrimary.redeemExec.t.sol's `_deployFee`), needed to prove the fee snapshot.
    function _deployFee(uint16 bps) internal returns (REXPrimary r) {
        r = new REXPrimary(
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
            makeAddr("fee"),
            SC3Params({
                navOracle: INavOracle(address(navOracle)),
                minRedeem: 0,
                redeemCancelFeeBps: 0,
                subFulfillTimeout: 10 days,
                redemptionFeeBps: bps,
                redeemFulfillTimeout: 10 days,
                windDownWindow: 9 days,
                schedule: perSecondSchedule()
            })
        );
        r.enrollRemote(PRUV_DOMAIN, _b32(executor));
        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad(); // vacuous close (minimum 0) -> EpochBased, no batch
    }

    /// @dev Give `who` wRWA and escrow it into `rex`'s current redeem epoch.
    function _requestRedeem(address who, uint256 amt) internal returns (uint256 id) {
        wrwaRoute.deliverTokens(_b32(who), amt);
        vm.startPrank(who);
        IERC20(address(wrwaRoute)).approve(address(rex), amt);
        id = rex.requestRedeem(amt);
        vm.stopPrank();
    }

    /// @dev Delivers a redeem batch's return instruction as the enrolled PRUV executor would
    /// (mirrors REXPrimary.redeemExec.t.sol's `_deliverRedeemReturn`).
    function _deliverRedeemReturn(uint64 batchId, RequestKind kind, uint256 amount) internal {
        if (kind == RequestKind.Redeem) {
            usdc.mint(address(usdcRoute), amount); // fund the collateral route to unlock from
            usdcRoute.deliverTokens(_b32(address(rex)), amount);
        } else {
            wrwaRoute.deliverTokens(_b32(address(rex)), amount);
        }
        bytes memory body = Codec.encode(Instruction({legId: batchId, kind: kind, amount: amount, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
    }

    /// @dev Art 8.2 keystone proof (Task 7): a redeemer's payout must not move when the owner
    /// raises the LIVE redemptionFeeBps mid-window. `requestRedeem` freezes the live rate onto
    /// the epoch at request time; claim must charge that snapshot, never the live storage var --
    /// so preview (before-act, live rate) == charge (at-claim, snapshotted rate), even though the
    /// live rate itself moved in between.
    function test_redemptionFee_snapshot_survives_rate_change() public {
        rex = _deployFee(50); // 0.5% live at request time
        uint256 id = _requestRedeem(bob, 100e6); // snapshots 50bps onto epoch 1
        (uint256 previewOut,) = lens.previewRedeem(address(rex), 100e6); // before-act preview, reads the live (still 50) rate
        assertEq(previewOut, 99_500_000, "sanity: 0.5% of 100e6");

        // Owner raises the live redemption fee to 200bps (== feeCapBps, allowed) and applies it
        // after the Task-6 48h timelock -- still well inside the ~9-day redeem window before claim.
        rex.setFees(0, 0, 200);
        vm.warp(block.timestamp + 49 hours);
        rex.applyFees();
        assertEq(rex.redemptionFeeBps(), 200, "live rate is now 200bps");

        rex.initiateSubEpoch(); // 100e6 >= minRedeem(0) -> bridges immediately as batch 1
        _deliverRedeemReturn(1, RequestKind.Redeem, 100e6);
        rex.settleRedeemBatch(1);

        uint256 gotBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        rex.claim(id, 100e6);

        // bob is charged the SNAPSHOTTED 50bps, equal to his pre-change preview -- not the live 200bps
        assertEq(usdc.balanceOf(bob) - gotBefore, previewOut);
        assertEq(usdc.balanceOf(bob) - gotBefore, 99_500_000, "0.5% of 100e6, not the live 2%");
    }

    /// @dev C1 fix-round-2 (whole-branch review): `previewRedeem` must read the CURRENT epoch's
    /// snapshot, not the live rate -- a non-first requester into an already-open epoch (whose
    /// snapshot was frozen by an earlier requester, at a rate the owner has since changed) must
    /// preview and later be charged the SAME snapshotted rate. Design doc
    /// 2026-08-13-sc6-lifecycle-access-design.md §4 (D1 semantics): "previewRedeem reads that
    /// snapshot for an existing epoch (live rate for a not-yet-created one)".
    function test_previewRedeem_reads_epoch_snapshot_for_nonFirst_requester() public {
        rex = _deployFee(100); // 1% live at request time
        uint256 id = _requestRedeem(alice, 40e6); // FIRST requester -> snapshots 100bps onto epoch 1

        // Owner LOWERS the live fee to 50bps, applies after the 48h timelock. initiateSubEpoch is
        // deliberately not called yet, so alice and bob still share the same currentEpochId epoch.
        rex.setFees(0, 0, 50);
        vm.warp(block.timestamp + 49 hours);
        rex.applyFees();
        assertEq(rex.redemptionFeeBps(), 50, "live rate is now 50bps");

        (uint256 bobPreviewOut, uint256 bobPreviewFee) = lens.previewRedeem(address(rex), 60e6);
        // must read the EPOCH SNAPSHOT (100bps, from alice's request), not the live 50bps
        assertEq(bobPreviewFee, 600_000, "preview must read the epoch snapshot, not the live rate");
        assertEq(bobPreviewOut, 59_400_000);

        uint256 bobId = _requestRedeem(bob, 60e6); // 2nd requester, same epoch -> inherits snapshot 100
        assertEq(bobId, id, "same RED_EPOCH id -- no initiateSubEpoch between the two requests");

        rex.initiateSubEpoch(); // 100e6 (alice 40 + bob 60) >= minRedeem(0) -> bridges as batch 1
        _deliverRedeemReturn(1, RequestKind.Redeem, 100e6);
        rex.settleRedeemBatch(1);

        uint256 gotBefore = usdc.balanceOf(bob);
        vm.prank(bob);
        rex.claim(bobId, 60e6);
        uint256 bobActualPayout = usdc.balanceOf(bob) - gotBefore;

        // bob's earlier preview equals his actual claim payout -- both at the snapshotted 100bps
        assertEq(bobActualPayout, bobPreviewOut);
        assertEq(bobActualPayout, 59_400_000);
        // and explicitly NOT what the live 50bps rate would have paid
        assertTrue(bobActualPayout != 59_700_000, "must not use the live 50bps rate");
    }

    function test_feeCapBps_defaults_200_and_ctor_rejects_above() public {
        // Hoisted out of the `new REXPrimary` argument list on purpose: creating the
        // schedule is itself a CALL, and inline it would be the call `vm.expectRevert`
        // consumes (and, below, a nonce bump that breaks the predicted address).
        IEpochSchedule sched = perSecondSchedule();
        assertEq(rex.feeCapBps(), 200);
        // a ctor with cancelFeeBps 201 must revert FeeCapExceeded
        vm.expectRevert(FeeCapExceeded.selector);
        new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            0,
            uint64(block.timestamp + 1),
            1 days,
            0,
            201,
            /* cancelFeeBps */
            makeAddr("fee"),
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

    function test_setFees_timelocked_apply() public {
        rex.setFees(100, 20, 100); // all <= 200
        // unchanged until applied
        assertEq(rex.redemptionFeeBps(), 0);
        vm.expectRevert(TimelockNotElapsed.selector);
        rex.applyFees();
        vm.warp(block.timestamp + 48 hours);
        rex.applyFees();
        assertEq(rex.redemptionFeeBps(), 100);
        assertEq(rex.cancelFeeBps(), 100);
        assertEq(rex.redeemCancelFeeBps(), 20);
    }

    function test_setFees_reverts_above_cap() public {
        vm.expectRevert(FeeCapExceeded.selector);
        rex.setFees(201, 0, 0);
    }

    function test_setFeeCap_raises_bound() public {
        rex.setFeeCap(500);
        vm.warp(block.timestamp + 48 hours);
        rex.applyFeeCap();
        assertEq(rex.feeCapBps(), 500);
        rex.setFees(400, 0, 0); // now allowed
    }

    function test_applyFees_reverts_when_cap_lowered_below_pending() public {
        rex.setFees(100, 20, 150); // all <= current cap 200
        rex.setFeeCap(100); // propose a lower cap
        vm.warp(block.timestamp + 48 hours); // both timelocks elapse
        rex.applyFeeCap();
        assertEq(rex.feeCapBps(), 100);
        // pending redemption bps (150) now exceeds the lowered cap (100)
        vm.expectRevert(FeeCapExceeded.selector);
        rex.applyFees();
    }

    function test_applyFees_reverts_invalidState_when_nothing_pending() public {
        vm.expectRevert(InvalidState.selector);
        rex.applyFees();
    }

    function test_applyFeeCap_reverts_invalidState_when_nothing_pending() public {
        vm.expectRevert(InvalidState.selector);
        rex.applyFeeCap();
    }

    function test_applyFees_reverts_invalidState_after_already_applied() public {
        rex.setFees(100, 20, 100);
        vm.warp(block.timestamp + 48 hours);
        rex.applyFees();
        // pending slot was cleared -- re-applying with nothing new proposed reverts
        vm.expectRevert(InvalidState.selector);
        rex.applyFees();
    }

    function test_applyFeeCap_reverts_invalidState_after_already_applied() public {
        rex.setFeeCap(500);
        vm.warp(block.timestamp + 48 hours);
        rex.applyFeeCap();
        // pending slot was cleared -- re-applying with nothing new proposed reverts
        vm.expectRevert(InvalidState.selector);
        rex.applyFeeCap();
    }

    /// @dev M-3 (audit): a cap > 100% is meaningless and would later underflow `gross - fee`
    /// in cancelRequest/claim/previewRedeem -- setFeeCap must reject it outright.
    function test_M3_setFeeCap_rejects_above_100pct() public {
        vm.expectRevert(FeeCapExceeded.selector);
        rex.setFeeCap(10_001); // > 100%
    }

    /// @dev M-3: exactly 100% (10_000 bps) is the boundary and must still be allowed --
    /// ADR-007 A1 keeps no ceiling below 100%.
    function test_M3_setFeeCap_allows_exactly_100pct() public {
        rex.setFeeCap(10_000);
        vm.warp(block.timestamp + 48 hours);
        rex.applyFeeCap();
        assertEq(rex.feeCapBps(), 10_000);
    }
}
