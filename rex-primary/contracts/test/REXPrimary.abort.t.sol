// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {Codec} from "@rex-shared/Codec.sol";
import "../src/REXPrimary.sol";
import "@rex-shared/Receipt.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/INavOracle.sol";
import "./mocks/MockERC20.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import "@rex-shared-mocks/MockNavOracle.sol";
import {perSecondSchedule, warpToNextPeriod} from "./helpers/TestSchedule.sol";
import {IEpochSchedule} from "@rex-shared/IEpochSchedule.sol";

/// @dev SC4a Task 3: the `heldEscrowUSDC` reservation counter (the USDC-leg analogue of
/// `liveRedeemEscrow`). These tests pin the invariant `usdc.balanceOf(this) >= heldEscrowUSDC`
/// across every site that moves USDC in or out of escrow. Abort-specific behavior (T4-T6)
/// belongs in later additions to this file, not here.
contract REXPrimaryAbortTest is Test {
    MockMailbox mailbox;
    MockERC20 usdc;
    MockCollateralWarpRoute usdcRoute;
    MockSyntheticWarpRoute wrwaRoute;
    MockNavOracle navOracle;
    REXPrimary rex;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address executor = makeAddr("executor");
    uint32 constant PRUV_DOMAIN = 7336;

    receive() external payable {}

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _deployPool(uint256 minSub_, uint256 launchpadMinimum_, uint16 cancelFeeBps_, address feeRecipient_)
        internal
        returns (REXPrimary r)
    {
        r = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            minSub_,
            uint64(block.timestamp + 1),
            1 days,
            launchpadMinimum_,
            cancelFeeBps_,
            feeRecipient_,
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
        r.enrollRemote(PRUV_DOMAIN, _b32(executor));
    }

    function setUp() public {
        mailbox = new MockMailbox(PRUV_DOMAIN);
        mailbox.setQuoteFee(0);
        usdc = new MockERC20("USDC", 6);
        usdcRoute = new MockCollateralWarpRoute(usdc);
        usdcRoute.setGasQuote(0);
        wrwaRoute = new MockSyntheticWarpRoute("wRWA", 6);
        navOracle = new MockNavOracle(1e18);
        rex = _deployPool(0, 0, 0, address(0xFEE));
        _reachEpochBased(rex);
    }

    /// @dev Reach EpochBased via a zero-raise vacuous launchpad close (launchpadMinimum == 0),
    /// which creates NO batch, so subscribe batch ids still start at 1.
    function _reachEpochBased(REXPrimary r) internal {
        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad();
    }

    /// @dev Reach EpochBased on a minSub>0 pool the only way the spec allows (launchpadMinimum
    /// >= minSub, so no zero-raise): a real launchpad round-trip, fully settled so the pool's
    /// first subscribe epoch accrues into a fresh batch 2, not the launchpad's own batch 1.
    function _launchToEpochBased(REXPrimary r, uint256 raise) internal {
        address seeder = makeAddr("lpSeeder");
        usdc.mint(seeder, raise);
        vm.warp(r.launchpadStart());
        vm.startPrank(seeder);
        usdc.approve(address(r), raise);
        r.depositToLaunchpad(raise);
        vm.stopPrank();
        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad();
        wrwaRoute.deliverTokens(_b32(address(r)), raise);
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Subscribe, amount: raise, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        r.handle(PRUV_DOMAIN, _b32(executor), body);
        r.settleSubBatch(1);
    }

    function _requestDeposit(REXPrimary r, address who, uint256 amount) internal returns (uint256 id) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(r), amount);
        id = r.requestDeposit(amount);
        vm.stopPrank();
    }

    function _requestRedeem(REXPrimary r, address who, uint256 amount) internal returns (uint256 id) {
        wrwaRoute.deliverTokens(_b32(who), amount);
        vm.startPrank(who);
        IERC20(address(wrwaRoute)).approve(address(r), amount);
        id = r.requestRedeem(amount);
        vm.stopPrank();
    }

    /// @dev SC4a Task 4: bridge exactly one subscribe batch to `Bridged` on the shared `rex`
    /// fixture (minSub == 0, so requestDeposit -> initiateSubEpoch bridges immediately).
    /// Returns the freshly-bridged batch id.
    function _bridgeOneSubBatch(uint256 raise) internal returns (uint64 batchId) {
        _requestDeposit(rex, alice, raise);
        rex.initiateSubEpoch();
        batchId = rex.nextSubBatchId() - 1;
    }

    /// @dev Delivers the Subscribe return instruction as the enrolled PRUV executor would
    /// (mirrors `REXPrimary.settle.t.sol`'s `_deliverReturn`, parameterized on `legId`).
    function _deliverSubscribeReturn(uint64 legId, uint256 amount) internal {
        bytes memory body =
            Codec.encode(Instruction({legId: legId, kind: RequestKind.Subscribe, amount: amount, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
    }

    /// @dev SC4a Task 5: stands in for the returned USDC collateral unlocking back onto the
    /// home chain. `MockCollateralWarpRoute` has no `deliverTokens` -- per its own doc comment
    /// this endpoint is always the *sending* (origin) side of its route in REX's topology, so
    /// there is no route-level delivery mechanism to drive here. Minting directly to `rex` is
    /// the fallback the task prescribes: it raises the raw balance exactly like a real unlock
    /// would, which is all `_onInstruction`'s `usdcFresh` rendezvous check observes.
    function _fundContractUSDC(uint256 amount) internal {
        usdc.mint(address(rex), amount);
    }

    /// @dev Delivers the SubAborted return instruction as the enrolled PRUV executor would
    /// (mirrors `_deliverSubscribeReturn`, but for the abort-return kind).
    function _deliverSubAborted(uint64 legId, uint256 amount) internal {
        bytes memory body = Codec.encode(
            Instruction({legId: legId, kind: RequestKind.SubAborted, amount: amount, navAtInitiate: 1e18})
        );
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
    }

    /// @dev SC4a Task 6: two holders subscribing into the SAME epoch (so they share one
    /// `SUB_EPOCH|epochId` receipt id) -- bridged, then aborted. Builds on `_bridgeOneSubBatch`
    /// (Task 4) and the abort-delivery flow (Task 5), but with two depositors instead of one, so
    /// `_claim`'s pro-rata split (Task 6) is actually exercised across holders.
    function _twoHolderAbortedBatch(uint256 aliceAmount, uint256 bobAmount)
        internal
        returns (uint64 batchId, uint256 id)
    {
        id = encodeId(CLASS_SUB_EPOCH, rex.currentEpochId());
        _requestDeposit(rex, alice, aliceAmount);
        _requestDeposit(rex, bob, bobAmount);
        rex.initiateSubEpoch(); // minSub == 0 -> bridges immediately (status Bridged)
        batchId = rex.nextSubBatchId() - 1;

        uint256 total = aliceAmount + bobAmount;
        _fundContractUSDC(total); // simulate the unlocked USDC collateral arriving back at rex
        _deliverSubAborted(batchId, total); // status -> Aborted, heldEscrowUSDC += total
    }

    /// @dev Generalizes `_fundContractUSDC` + `_deliverSubAborted` for an arbitrary pool `r`
    /// (those two are hardcoded to the shared `rex` fixture). Needed by the multi-epoch abort
    /// regression below, which requires a custom minSub>0 pool.
    function _abortBatchOn(REXPrimary r, uint64 batchId, uint256 amount) internal {
        usdc.mint(address(r), amount); // simulate the unlocked USDC collateral arriving back
        bytes memory body = Codec.encode(
            Instruction({legId: batchId, kind: RequestKind.SubAborted, amount: amount, navAtInitiate: 1e18})
        );
        vm.prank(address(mailbox));
        r.handle(PRUV_DOMAIN, _b32(executor), body);
    }

    /// @dev Sites 1 + 2 (requestDeposit / cancelRequest SUB_EPOCH branch), plus the trap:
    /// a RED_EPOCH cancel must never touch heldEscrowUSDC (it is a wRWA leg).
    function test_heldEscrowUSDC_tracks_balance_through_flows() public {
        // subscribe escrow in
        uint256 subId = _requestDeposit(rex, alice, 100e6);
        assertEq(rex.heldEscrowUSDC(), 100e6);
        assertGe(usdc.balanceOf(address(rex)), rex.heldEscrowUSDC());

        // partial cancel (SUB_EPOCH branch): whole gross leaves
        vm.prank(alice);
        rex.cancelRequest(subId, 40e6);
        assertEq(rex.heldEscrowUSDC(), 60e6);

        // a RED_EPOCH cancel must NOT touch heldEscrowUSDC
        uint256 redId = _requestRedeem(rex, bob, 10e6);
        uint256 held = rex.heldEscrowUSDC();
        vm.prank(bob);
        rex.cancelRequest(redId, 10e6);
        assertEq(rex.heldEscrowUSDC(), held); // unchanged
        assertGe(usdc.balanceOf(address(rex)), rex.heldEscrowUSDC());
    }

    /// @dev Constructor guard: feeRecipient cannot be the REXPrimary's own (predicted) address.
    function test_constructor_rejects_self_feeRecipient() public {
        // Hoisted out of the `new REXPrimary` argument list on purpose: creating the
        // schedule is itself a CALL, and inline it would be the call `vm.expectRevert`
        // consumes (and, below, a nonce bump that breaks the predicted address).
        IEpochSchedule sched = perSecondSchedule();
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        vm.expectRevert(InvalidLaunchpadConfig.selector);
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
            0,
            predicted, // feeRecipient == the about-to-be-deployed REXPrimary's own address
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

    /// @dev Site 2 with a non-zero cancel fee: heldEscrowUSDC must drop by the GROSS amount
    /// (both the net-to-user and the fee-to-feeRecipient legs leave the contract), not just net.
    function test_cancelRequest_subEpoch_decrements_by_gross_not_net() public {
        REXPrimary r = _deployPool(0, 0, 100, makeAddr("fee9")); // 1% cancel fee
        _reachEpochBased(r);
        uint256 id = _requestDeposit(r, alice, 100e6);
        assertEq(r.heldEscrowUSDC(), 100e6);

        vm.prank(alice);
        r.cancelRequest(id, 40e6); // 1% of 40e6 = 0.4e6 fee; net 39.6e6 to alice
        assertEq(r.heldEscrowUSDC(), 60e6, "gross decrement, not net -- the fee also left escrow");
        assertGe(usdc.balanceOf(address(r)), r.heldEscrowUSDC());
        assertEq(usdc.balanceOf(address(r)), 60e6);
    }

    /// @dev Sites 3 + 4 (depositToLaunchpad / cancelLaunchpad), with a non-zero fee so the
    /// gross-vs-net distinction is actually exercised.
    function test_depositToLaunchpad_and_cancelLaunchpad_track_gross() public {
        REXPrimary r = _deployPool(0, 0, 100, makeAddr("fee8")); // 1% cancel fee
        vm.warp(r.launchpadStart());
        usdc.mint(alice, 60e6);
        vm.startPrank(alice);
        usdc.approve(address(r), 60e6);
        r.depositToLaunchpad(60e6);
        vm.stopPrank();
        assertEq(r.heldEscrowUSDC(), 60e6, "site 3: deposit increments");
        assertGe(usdc.balanceOf(address(r)), r.heldEscrowUSDC());

        vm.prank(alice);
        r.cancelLaunchpad(60e6); // 1% fee = 0.6e6 to feeRecipient, 59.4e6 net to alice
        assertEq(r.heldEscrowUSDC(), 0, "site 4: gross decrement (net+fee), not just net");
        assertEq(usdc.balanceOf(address(r)), 0);
    }

    /// @dev Site 6, success branch: closeLaunchpad drains exactly `raised` when it bridges.
    function test_closeLaunchpad_success_decrements_heldEscrowUSDC_by_raised() public {
        REXPrimary r = _deployPool(0, 100e6, 0, address(0xFEE6));
        vm.warp(r.launchpadStart());
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(r), 100e6);
        r.depositToLaunchpad(100e6);
        vm.stopPrank();
        assertEq(r.heldEscrowUSDC(), 100e6);

        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad(); // raised(100e6) >= minimum(100e6) -> bridges
        assertEq(r.heldEscrowUSDC(), 0, "site 6: raised drained on bridge");
        assertEq(usdc.balanceOf(address(r)), 0);
    }

    /// @dev Site 6 trap + site 5: the LaunchpadFail branch must NOT decrement (the USDC stays
    /// for refundLaunchpad to drain), and refundLaunchpad then does exactly that.
    function test_closeLaunchpad_fail_does_not_touch_then_refund_drains() public {
        REXPrimary r = _deployPool(0, 100e6, 0, address(0xFEE7));
        vm.warp(r.launchpadStart());
        usdc.mint(alice, 40e6); // below the 100e6 minimum
        vm.startPrank(alice);
        usdc.approve(address(r), 40e6);
        r.depositToLaunchpad(40e6);
        vm.stopPrank();

        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad(); // raised(40e6) < minimum(100e6) -> LaunchpadFail
        assertEq(uint8(r.state()), uint8(REXPrimary.LifecycleState.LaunchpadFail));
        assertEq(r.heldEscrowUSDC(), 40e6, "trap: LaunchpadFail branch must NOT decrement");
        assertGe(usdc.balanceOf(address(r)), r.heldEscrowUSDC());

        vm.prank(alice);
        r.refundLaunchpad(40e6);
        assertEq(r.heldEscrowUSDC(), 0, "site 5: refund drains it");
        assertEq(usdc.balanceOf(address(r)), 0);
    }

    /// @dev Site 7: the Bridged branch of initiateSubEpoch drains exactly b.netIn.
    function test_initiateSubEpoch_bridged_decrements_heldEscrowUSDC_by_netIn() public {
        _requestDeposit(rex, alice, 100e6);
        assertEq(rex.heldEscrowUSDC(), 100e6);

        rex.initiateSubEpoch(); // minSub == 0 => bridges immediately (Bridged branch)
        assertEq(rex.heldEscrowUSDC(), 0, "site 7: netIn drained on bridge");
        assertEq(usdc.balanceOf(address(rex)), 0);
    }

    /// @dev Site 7 trap + site 8: the Released branch must NOT decrement (the USDC stays for
    /// _claim to drain), and _claim's Released-refund branch then drains it pro-rata.
    function test_initiateSubEpoch_released_does_not_touch_then_claim_drains() public {
        REXPrimary r = _deployPool(1000e6, 1000e6, 0, address(0xFEE5));
        _launchToEpochBased(r, 1000e6); // occupies batch 1; subscribe batches start at 2

        // epoch 1: alice deposits below minSub -> batch 2 stays Accumulating
        uint256 aliceId = _requestDeposit(r, alice, 100e6);
        r.initiateSubEpoch();
        (uint8 status1,,) = r.subBatch(2);
        assertEq(status1, uint8(BatchStatus.Accumulating));
        assertEq(r.heldEscrowUSDC(), 100e6, "still held while accumulating");

        // ADR-027 retired the accrual cap, so wind-down is now the only route to Released on this
        // leg: `triggerWindDown` turns subscribe off, which is what makes a below-minimum batch
        // genuinely unable to fill. The branch under test is the same one either way.
        uint256 bobId = _requestDeposit(r, bob, 1e6);
        warpToNextPeriod(r); // ADR-025: one close per period
        r.initiateSubEpoch();
        r.triggerWindDown();
        (uint8 status2, uint256 netIn2,) = r.subBatch(2);
        assertEq(status2, uint8(BatchStatus.Released), "below minSub, subscribe off -> released, never bridged");
        assertEq(netIn2, 101e6);
        assertEq(r.heldEscrowUSDC(), 101e6, "trap: Released branch must NOT decrement");
        assertGe(usdc.balanceOf(address(r)), r.heldEscrowUSDC());

        // claim drains it (site 8)
        vm.prank(alice);
        r.claim(aliceId, 100e6);
        assertEq(r.heldEscrowUSDC(), 1e6, "alice's refund drained her share only");
        assertEq(usdc.balanceOf(alice), 100e6);
        assertGe(usdc.balanceOf(address(r)), r.heldEscrowUSDC());

        vm.prank(bob);
        r.claim(bobId, 1e6);
        assertEq(r.heldEscrowUSDC(), 0, "fully drained");
        assertEq(usdc.balanceOf(address(r)), 0);
    }

    /// @dev SC4a Task 4: the per-leg replay latch (`processedLeg`) makes `_onInstruction`
    /// idempotent at the semantic-leg level (constitution Art 4.1). This harness pranks as
    /// the mailbox and calls `handle` directly, bypassing MockMailbox's own dispatch/process
    /// message registry entirely -- `handle` takes no message id in this call pattern, so
    /// there is NO transport-level dedup in play here. The only thing that can make the
    /// second, byte-identical delivery a silent no-op is the new semantic latch keyed on
    /// (legId, kind).
    function test_duplicate_subscribe_return_is_noop() public {
        // wRWA mock is 6-decimal (MockSyntheticWarpRoute("wRWA", 6)) -- e6-scale amounts.
        uint64 batchId = _bridgeOneSubBatch(100e6); // status Bridged
        wrwaRoute.deliverTokens(_b32(address(rex)), 99e6); // covering tokens arrive first
        _deliverSubscribeReturn(batchId, 99e6); // first delivery: sets returnReceived, emits

        (,, uint256 returnedAmount, bool returnReceived) = rex.batchLeg(batchId, false);
        assertTrue(returnReceived);
        assertEq(returnedAmount, 99e6);

        // second delivery of the SAME (legId, Subscribe): must not revert, must not re-emit
        vm.recordLogs();
        _deliverSubscribeReturn(batchId, 99e6);
        assertEq(vm.getRecordedLogs().length, 0);

        // and state must be byte-for-byte unchanged
        (,, uint256 returnedAmount2, bool returnReceived2) = rex.batchLeg(batchId, false);
        assertTrue(returnReceived2);
        assertEq(returnedAmount2, 99e6);
    }

    /// @dev SC4a Task 5: a `SubAborted` return settles the batch INLINE (Bridged -> Aborted,
    /// no separate `settleSubBatch` step, unlike the Subscribe return's two-step settle),
    /// and re-reserves the returned USDC into `heldEscrowUSDC` so `_claim` (Task 6) can refund it.
    function test_subAborted_return_settles_and_reserves_usdc() public {
        uint64 batchId = _bridgeOneSubBatch(100e6); // status Bridged
        _fundContractUSDC(100e6); // simulate the unlocked USDC collateral arriving back at rex
        uint256 heldBefore = rex.heldEscrowUSDC();

        _deliverSubAborted(batchId, 100e6);

        (uint8 status,,) = rex.subBatch(batchId);
        assertEq(status, uint8(BatchStatus.Aborted));
        assertEq(rex.heldEscrowUSDC(), heldBefore + 100e6);
    }

    /// @dev The USDC-leg rendezvous counterpart: if the returned collateral has not physically
    /// arrived yet, the abort-return instruction must revert `NotReadyToExecute` and stay
    /// re-processable (no latch set), mirroring the Subscribe branch's `available` guard.
    function test_subAborted_reverts_when_usdc_not_arrived() public {
        uint64 batchId = _bridgeOneSubBatch(100e6); // status Bridged -- no _fundContractUSDC
        vm.expectRevert(NotReadyToExecute.selector);
        _deliverSubAborted(batchId, 100e6);
    }

    /// @dev SC4a Task 6: `_claim` widened to accept an `Aborted` batch -- two holders of the
    /// same aborted batch each reclaim their pro-rata share of the re-reserved USDC, and the
    /// pot stays solvent (Σ refunds == heldEscrowUSDC re-reserved by the abort delivery).
    function test_claim_after_abort_refunds_usdc_prorata() public {
        (, uint256 id) = _twoHolderAbortedBatch(60e6, 40e6);
        uint256 held = rex.heldEscrowUSDC();

        vm.prank(alice);
        rex.claim(id, 60e6);
        assertEq(usdc.balanceOf(alice), 60e6);

        vm.prank(bob);
        rex.claim(id, 40e6);
        assertEq(usdc.balanceOf(bob), 40e6);

        assertEq(rex.heldEscrowUSDC(), held - 100e6);
        assertGe(usdc.balanceOf(address(rex)), rex.heldEscrowUSDC());
    }

    /// @dev Regression guard (whole-branch review, Important/non-blocking): every abort test
    /// above bridges a SINGLE-epoch batch, where `s.netAmount == b.returnedAmount == b.netIn`
    /// numerically -- so none of them can distinguish the CORRECT refund numerator
    /// (`_claim`'s `s.netAmount`) from the WRONG `b.returnedAmount`. This accrues TWO epochs of
    /// DIFFERENT sizes into the SAME batch (mirrors
    /// `test_initiateSubEpoch_released_does_not_touch_then_claim_drains`'s accrual, but sized
    /// to bridge instead of release), aborts the batch, then has each epoch's holder claim
    /// under their OWN epoch's id. If `_claim` used `b.returnedAmount` instead of `s.netAmount`,
    /// alice's claim would compute `mulDiv(30e6, 100e6, 30e6) == 100e6` -- the whole batch --
    /// instead of her own 30e6, and would also revert on underflow when bob's later claim tried
    /// to draw a second 70e6 from an already-drained `heldEscrowUSDC`.
    function test_claim_after_abort_multiEpoch_refunds_own_epoch_net_not_batch_total() public {
        REXPrimary r = _deployPool(100e6, 100e6, 0, address(0xFEEA));
        _launchToEpochBased(r, 100e6); // occupies batch 1; subscribe batches start at 2

        // epoch 1: alice alone, below minSub -> batch 2 stays Accumulating
        uint256 aliceId = _requestDeposit(r, alice, 30e6);
        r.initiateSubEpoch();
        (uint8 status1, uint256 netIn1,) = r.subBatch(2);
        assertEq(status1, uint8(BatchStatus.Accumulating));
        assertEq(netIn1, 30e6);
        assertGe(usdc.balanceOf(address(r)), r.heldEscrowUSDC());

        // epoch 2: bob alone, pushes the SAME batch to minSub -> bridges
        uint256 bobId = _requestDeposit(r, bob, 70e6);
        warpToNextPeriod(r); // ADR-025: one close per period
        r.initiateSubEpoch();
        (uint8 status2, uint256 netIn2,) = r.subBatch(2);
        assertEq(status2, uint8(BatchStatus.Bridged));
        assertEq(netIn2, 100e6);
        assertTrue(aliceId != bobId, "distinct epochs must mint distinct receipt ids");
        assertGe(usdc.balanceOf(address(r)), r.heldEscrowUSDC());

        // abort the whole batch: fund the returned USDC, deliver SubAborted(2, 100e6)
        _abortBatchOn(r, 2, 100e6);
        (uint8 status3,,) = r.subBatch(2);
        assertEq(status3, uint8(BatchStatus.Aborted));
        assertGe(usdc.balanceOf(address(r)), r.heldEscrowUSDC());

        // each holder claims under THEIR OWN epoch's id -- must equal that epoch's own net,
        // never a pro-rata split of the batch's 100e6 total.
        vm.prank(alice);
        r.claim(aliceId, 30e6);
        assertEq(usdc.balanceOf(alice), 30e6, "alice gets her own epoch's net, not the batch total");
        assertGe(usdc.balanceOf(address(r)), r.heldEscrowUSDC());

        vm.prank(bob);
        r.claim(bobId, 70e6);
        assertEq(usdc.balanceOf(bob), 70e6, "bob gets his own epoch's net");

        assertEq(r.heldEscrowUSDC(), 0, "fully drained");
        assertEq(usdc.balanceOf(address(r)), 0);
    }

    /// @dev SC4 followup (design 11 item 8): the SubAborted-side counterpart to
    /// `test_duplicate_subscribe_return_is_noop`. SubAborted's branch flips a batch's status
    /// Bridged -> Aborted and re-reserves `heldEscrowUSDC`, so a regressed latch-vs-status
    /// ordering here would double-count the refund reservation, not just re-emit a log.
    function test_duplicate_subAborted_return_is_noop() public {
        uint64 batchId = _bridgeOneSubBatch(100e6); // status Bridged
        _fundContractUSDC(100e6); // simulate the unlocked USDC collateral arriving back at rex
        uint256 heldBefore = rex.heldEscrowUSDC();

        _deliverSubAborted(batchId, 100e6); // first delivery: settles, emits, re-reserves

        (uint8 status,,) = rex.subBatch(batchId);
        assertEq(status, uint8(BatchStatus.Aborted));
        assertEq(rex.heldEscrowUSDC(), heldBefore + 100e6);

        // second delivery of the SAME (legId, SubAborted): must not revert, must not re-emit
        vm.recordLogs();
        _deliverSubAborted(batchId, 100e6);
        assertEq(vm.getRecordedLogs().length, 0);

        // heldEscrowUSDC must have moved exactly ONCE, not twice
        assertEq(rex.heldEscrowUSDC(), heldBefore + 100e6, "must not double-reserve on replay");
    }

    /// @dev Spec 7.1: closeLaunchpad's success branch bridges as an ordinary subscribe batch, so
    /// it recovers via the SAME abort machinery as any other batch -- but every existing abort
    /// test only ever SETTLES the launchpad batch successfully, never aborts it. Two real
    /// launchpad depositors clear `launchpadMinimum`, the raise bridges as batch 1, PRUV never
    /// executes it, and the abort return refunds both depositors via `claimLaunchpad` (not
    /// `claim` -- the launchpad receipt id is `CLASS_LAUNCHPAD|LAUNCHPAD_ID`, not a SUB_EPOCH id).
    function test_launchpad_abort_refunds_via_claimLaunchpad() public {
        REXPrimary r = _deployPool(0, 100e6, 0, address(0xFEEB));
        vm.warp(r.launchpadStart());

        usdc.mint(alice, 60e6);
        vm.startPrank(alice);
        usdc.approve(address(r), 60e6);
        r.depositToLaunchpad(60e6);
        vm.stopPrank();

        usdc.mint(bob, 40e6);
        vm.startPrank(bob);
        usdc.approve(address(r), 40e6);
        r.depositToLaunchpad(40e6);
        vm.stopPrank();

        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad(); // raised(100e6) >= minimum(100e6) -> bridges as batch 1
        (uint8 bridgedStatus,,) = r.subBatch(1);
        assertEq(bridgedStatus, uint8(BatchStatus.Bridged));

        // PRUV gate stays closed -- warp past the fulfillment deadline, then simulate the abort
        // return (USDC collateral unlocks back onto the home chain + the SubAborted instruction).
        vm.warp(block.timestamp + 30 days + 1);
        usdc.mint(address(r), 100e6);
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.SubAborted, amount: 100e6, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        r.handle(PRUV_DOMAIN, _b32(executor), body);

        (uint8 status,,) = r.subBatch(1);
        assertEq(status, uint8(BatchStatus.Aborted));

        vm.prank(alice);
        r.claimLaunchpad(60e6);
        assertEq(usdc.balanceOf(alice), 60e6);

        vm.prank(bob);
        r.claimLaunchpad(40e6);
        assertEq(usdc.balanceOf(bob), 40e6);

        assertEq(usdc.balanceOf(address(r)), 0);
        assertEq(r.heldEscrowUSDC(), 0);
    }
}
