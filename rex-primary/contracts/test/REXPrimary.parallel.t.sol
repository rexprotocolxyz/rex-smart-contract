// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "../src/REXPrimary.sol";
import "../src/PruvExecutor.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/Errors.sol";
import "@rex-shared/Receipt.sol";
import "./mocks/MockERC20.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockRWAToken.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import {MockRWAConversion} from "./mocks/MockRWAConversion.sol";
import "@rex-shared-mocks/MockNavOracle.sol";
import "@rex-shared/INavOracle.sol";
import {perSecondSchedule, warpToNextPeriod} from "./helpers/TestSchedule.sol";

/// @notice ADR-018: subscribe retires single-in-flight and runs PARALLEL batches, mirroring
/// the redeem leg. Reuses the full rex+exec+mailbox+mock-routes harness from
/// `SubscribeAbortRoundTrip.t.sol` (setUp + `_subscribe`) so the keystone test can drive a real
/// PRUV round trip for one batch while a second stays outstanding.
contract REXPrimaryParallelTest is Test {
    MockMailbox mailbox;
    MockERC20 usdc;
    MockCollateralWarpRoute usdcRoute; // home USDC collateral (Sepolia locks/unlocks)
    MockSyntheticWarpRoute pusdcRoute; // PRUV USDC synthetic (executor holds/burns)
    MockRWAToken vault;
    MockRWAConversion conversion;
    MockCollateralWarpRoute pruvWrwaRoute;
    MockSyntheticWarpRoute homeWrwaRoute;
    MockNavOracle navOracle;
    REXPrimary rex;
    PruvExecutor exec;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint32 constant PRUV_DOMAIN = 7336;

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
        pusdcRoute = new MockSyntheticWarpRoute("pUSDC", 6);
        pusdcRoute.setGasQuote(0); // PRUV gas 0 — abortDeposit sends over this route

        vault = new MockRWAToken(address(pusdcRoute));
        conversion = new MockRWAConversion(1e18);
        pruvWrwaRoute = new MockCollateralWarpRoute(IERC20(address(vault)));
        pruvWrwaRoute.setGasQuote(0);
        homeWrwaRoute = new MockSyntheticWarpRoute("wRWA", 6);
        homeWrwaRoute.setGasQuote(0);

        navOracle = new MockNavOracle(1e18);
        rex = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(homeWrwaRoute)),
            PRUV_DOMAIN,
            0,
            uint64(block.timestamp + 1),
            1 days,
            0,
            0,
            address(0xFEE),
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
        exec = new PruvExecutor(
            IMailbox(address(mailbox)),
            IWarpRoute(address(pruvWrwaRoute)),
            PRUV_DOMAIN,
            address(vault),
            address(pusdcRoute),
            IWarpRoute(address(pusdcRoute)),
            1 hours,
            100,
            10 days,
            conversion,
            0,
            0
        );
        rex.enrollRemote(PRUV_DOMAIN, _b32(address(exec)));
        exec.enrollRemote(PRUV_DOMAIN, _b32(address(rex)));
        vm.warp(rex.launchpadStart() + rex.launchpadPeriod());
        rex.closeLaunchpad();
    }

    function _subscribe(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(rex), amount);
        rex.requestDeposit(amount);
        vm.stopPrank();
    }

    /// @dev Drives a batch's full PRUV round trip (deposit accepted at the vault -> wRWA bridges
    /// home -> the return instruction is processed at REX) and records the return. Mirrors the
    /// happy-path pattern from `REXPrimary.settle.t.sol`, but through the real `exec`.
    function _completeSubscribeReturn(uint64 batchId, uint256 amount) internal {
        bytes32 retInstr = _pendingSubscribeReturnInstr(batchId, amount);
        homeWrwaRoute.deliverTokens(_b32(address(rex)), amount); // the wRWA physically arrives home
        mailbox.process(retInstr); // rex records the return -- settledUnclaimed credited (E6)
    }

    /// @dev Runs the PRUV-side half of a batch's round trip only: delivers the bridged USDC to
    /// `exec`, processes REX's outbound Subscribe instruction (the vault accepts, mints shares,
    /// and `exec` bridges the wRWA + a return Instruction back home), and returns that return
    /// instruction's mailbox message id -- WITHOUT delivering the wRWA home. Lets a test process
    /// the return instruction while the covering wRWA is still "in transit".
    function _pendingSubscribeReturnInstr(uint64 batchId, uint256 amount) internal returns (bytes32 retInstrMsgId) {
        (, bytes32 outInstr,,) = rex.batchLeg(batchId, false);
        pusdcRoute.deliverTokens(_b32(address(exec)), amount);
        mailbox.process(outInstr); // exec deposits into the vault, bridges wRWA + Instruction back
        (, retInstrMsgId,,,) = exec.lastReturnLeg();
    }

    /// @notice ADR-018: subscribe runs PARALLEL batches — a second epoch initiates while
    /// the first batch is still Bridged (pre-ADR-018 this reverted EpochInFlight).
    function test_parallel_second_epoch_bridges_while_first_in_flight() public {
        _subscribe(alice, 100e6);
        rex.initiateSubEpoch(); // epoch 0 -> batch 1 Bridged
        assertEq(rex.nextSubBatchId(), 2, "batch 1 minted");
        assertEq(rex.openSubBatchId(), 0, "batch 1 bridged, no open batch");

        _subscribe(bob, 200e6);
        warpToNextPeriod(rex); // ADR-025: one close per period
        rex.initiateSubEpoch(); // epoch 1 -> batch 2 Bridged, WITHOUT settling batch 1
        assertEq(rex.nextSubBatchId(), 3, "second batch minted in parallel");
        assertEq(rex.openSubBatchId(), 0, "batch 2 bridged too");
    }

    /// @notice E6 keystone: with batch 1 returned-but-unsettled, batch 2's return must revert
    /// NotReadyToExecute while batch 2's wRWA is not yet home — it cannot borrow batch 1's.
    /// MUTATION TARGET: crediting settledUnclaimed at settle (not here) makes this WRONGLY succeed.
    function test_parallel_second_return_cannot_borrow_first_batchs_wrwa() public {
        _subscribe(alice, 100e6);
        rex.initiateSubEpoch(); // batch 1 Bridged
        _subscribe(bob, 100e6);
        warpToNextPeriod(rex); // ADR-025: one close per period
        rex.initiateSubEpoch(); // batch 2 Bridged (parallel)

        // Complete batch 1's PRUV round-trip so ONLY batch 1's wRWA is home; do NOT settleSubBatch.
        _completeSubscribeReturn(1, 100e6);
        assertEq(rex.settledUnclaimed(), 100e6, "E6: batch 1's return reserved at record");

        // Batch 2's return instruction arrives but batch 2's wRWA has NOT: availability = 100e6 - 100e6 = 0.
        bytes32 batch2Return = _pendingSubscribeReturnInstr(2, 100e6);
        vm.expectRevert(NotReadyToExecute.selector);
        mailbox.process(batch2Return);
    }

    /// @notice RS6: two parallel batches settle OUT OF ORDER (batch 2 before batch 1) and each
    /// holder's claim is correct and independent per batch (ADR-018). The existing tests prove the
    /// second epoch bridges while the first is in flight and cannot borrow its wRWA; this proves the
    /// tail of RS6 -- out-of-order settlement with independent, correct per-batch claims.
    function test_parallel_out_of_order_settle_independent_claims() public {
        uint64 epA = rex.currentEpochId();
        _subscribe(alice, 100e6);
        rex.initiateSubEpoch(); // batch 1 (epoch epA) Bridged
        uint64 epB = rex.currentEpochId();
        _subscribe(bob, 200e6);
        warpToNextPeriod(rex); // ADR-025: one close per period
        rex.initiateSubEpoch(); // batch 2 (epoch epB) Bridged, in parallel

        // both PRUV round-trips complete: both batches' wRWA home, both returns recorded
        _completeSubscribeReturn(1, 100e6);
        _completeSubscribeReturn(2, 200e6);
        assertEq(rex.settledUnclaimed(), 300e6, "both returns reserved at record");

        // settle OUT OF ORDER: batch 2 first, then batch 1 -- order must not matter
        rex.settleSubBatch(2);
        rex.settleSubBatch(1);

        // each holder claims their own epoch independently; nav 1e18, sole holder -> full amount
        vm.prank(alice);
        rex.claim(encodeId(CLASS_SUB_EPOCH, epA), 100e6);
        vm.prank(bob);
        rex.claim(encodeId(CLASS_SUB_EPOCH, epB), 200e6);

        assertEq(homeWrwaRoute.balanceOf(alice), 100e6, "alice gets batch-1 payout");
        assertEq(homeWrwaRoute.balanceOf(bob), 200e6, "bob gets batch-2 payout");
        assertEq(rex.settledUnclaimed(), 0, "both pots fully drained");
        assertEq(homeWrwaRoute.balanceOf(address(rex)), 0, "no residue in rex");
    }
}
