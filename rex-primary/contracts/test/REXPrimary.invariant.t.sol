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
import {perSecondSchedule, warpToNextPeriod} from "./helpers/TestSchedule.sol";

contract REXPrimaryInvariantTest is Test {
    MockMailbox mailbox;
    MockERC20 usdc;
    MockCollateralWarpRoute usdcRoute;
    MockSyntheticWarpRoute wrwaRoute;
    MockNavOracle navOracle;
    REXPrimary rex;
    REXPrimaryRedeemHandler handler;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address executor = makeAddr("executor");
    uint32 constant PRUV_DOMAIN = 7336;
    uint256 constant ID1 = (uint256(1) << 248) | 1;

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
        rex.enrollRemote(PRUV_DOMAIN, _b32(executor));
        _reachEpochBased(rex);

        // SC5a Task 7 -- dedicated redeem-reserve solvency campaign: a separate handler + pool
        // (nonzero minRedeem, so Accumulating/Released are reachable, unlike
        // this fixture's minSub == minRedeem == 0, which always bridges same-call). Reuses this
        // contract's usdc/usdcRoute/wrwaRoute/mailbox/navOracle -- independent per-pool balances,
        // so nothing here touches the module-level `rex` used above.
        handler = new REXPrimaryRedeemHandler(usdc, mailbox, usdcRoute, wrwaRoute, navOracle, executor);
        bytes4[] memory selectors = new bytes4[](18);
        selectors[0] = handler.requestDeposit.selector;
        selectors[1] = handler.cancelSub.selector;
        selectors[2] = handler.deliverSubReturn.selector;
        selectors[3] = handler.deliverSubAborted.selector;
        selectors[4] = handler.settleSub.selector;
        selectors[5] = handler.claimSub.selector;
        selectors[6] = handler.requestRedeem.selector;
        selectors[7] = handler.cancelRedeem.selector;
        selectors[8] = handler.deliverRedeemReturn.selector;
        selectors[9] = handler.deliverRedeemAborted.selector;
        selectors[10] = handler.settleRedeem.selector;
        selectors[11] = handler.claimRedeem.selector;
        selectors[12] = handler.initiate.selector;
        selectors[13] = handler.warp.selector;
        // SC6b Task 7 -- lifecycle + sweep actions, each self-gated on the exact on-chain
        // precondition its contract counterpart checks, so the fuzz run stays 0-revert.
        selectors[14] = handler.triggerWindDown.selector;
        selectors[15] = handler.releaseStale.selector;
        selectors[16] = handler.sweep.selector;
        selectors[17] = handler.triggerShutDown.selector;
        targetContract(address(handler));
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Reach EpochBased via a zero-raise vacuous launchpad close (launchpadMinimum == 0),
    /// which creates NO batch, so subscribe batch ids still start at 1.
    function _reachEpochBased(REXPrimary r) internal {
        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad();
    }

    /// @dev Reach EpochBased on a minSub>0 pool the only way the spec allows (launchpadMinimum
    /// >= minSub, so no zero-raise): a real launchpad round-trip. This occupies batch 1, so the
    /// pool's first subscribe epoch accrues into batch 2.
    function _launchToEpochBased(REXPrimary r, uint256 raise, bytes32 remote) internal {
        address seeder = makeAddr("lpSeeder");
        usdc.mint(seeder, raise);
        vm.warp(r.launchpadStart());
        vm.startPrank(seeder);
        usdc.approve(address(r), raise);
        r.depositToLaunchpad(raise);
        vm.stopPrank();
        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad();
        wrwaRoute.deliverTokens(bytes32(uint256(uint160(address(r)))), raise);
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Subscribe, amount: raise, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        r.handle(PRUV_DOMAIN, remote, body);
        r.settleSubBatch(1);
    }

    function _deposit(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(rex), amount);
        rex.requestDeposit(amount);
        vm.stopPrank();
    }

    function _settleWith(uint256 shares) internal {
        rex.initiateSubEpoch();
        wrwaRoute.deliverTokens(_b32(address(rex)), shares);
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Subscribe, amount: shares, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
        rex.settleSubBatch(1);
    }

    /// Pro-rata uniformity (spec 14): two holders of one id claiming the same
    /// amount receive identical payouts, whenever they entered and whenever they claim.
    function testFuzz_pro_rata_uniformity(uint96 aliceIn, uint96 bobIn, uint96 returned) public {
        vm.assume(aliceIn > 1e6 && bobIn > 1e6);
        vm.assume(uint256(aliceIn) + uint256(bobIn) < 1e30);
        vm.assume(returned > 1e6);

        _deposit(alice, aliceIn);
        _deposit(bob, bobIn);
        _settleWith(returned);

        uint256 common = aliceIn < bobIn ? aliceIn : bobIn;

        vm.prank(alice);
        rex.claim(ID1, common);
        uint256 alicePaid = wrwaRoute.balanceOf(alice);

        vm.prank(bob);
        rex.claim(ID1, common);
        uint256 bobPaid = wrwaRoute.balanceOf(bob);

        assertEq(alicePaid, bobPaid, "same id, same amount, same payout");
    }

    /// Pot solvency (spec 14): the sum of all claims never exceeds the recorded
    /// pot; any shortfall is floor-division dust only.
    function testFuzz_pot_solvency(uint96 aliceIn, uint96 bobIn, uint96 returned) public {
        vm.assume(aliceIn > 1e6 && bobIn > 1e6);
        vm.assume(uint256(aliceIn) + uint256(bobIn) < 1e30);
        vm.assume(returned > 1e6);

        _deposit(alice, aliceIn);
        _deposit(bob, bobIn);
        _settleWith(returned);

        vm.prank(alice);
        rex.claim(ID1, aliceIn);
        vm.prank(bob);
        rex.claim(ID1, bobIn);

        uint256 paid = wrwaRoute.balanceOf(alice) + wrwaRoute.balanceOf(bob);
        assertLe(paid, returned, "never overpays the pot");
        assertGe(paid + 2, returned, "shortfall is at most one unit of dust per claim");
    }

    /// Pot solvency across a multi-epoch (accrued) batch: with `minSub` set above a
    /// single epoch's deposit, three epochs accrue into ONE batch before it bridges,
    /// so both the per-epoch `slice` mulDiv AND the per-holder `payout` mulDiv floor
    /// in the same claim path. Deposits are fixed to guarantee the accrual shape
    /// (epoch 1 and 2 stay under `minSub`, epoch 3 tips it over); only the returned
    /// pot is fuzzed.
    function testFuzz_pot_solvency_multi_epoch_batch(uint96 returned) public {
        vm.assume(returned > 1e6 && returned < 1e30);

        REXPrimary rex2 = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            300e6, // minSub: above any single epoch's deposit below
            uint64(block.timestamp + 1),
            1 days,
            300e6,
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
        rex2.enrollRemote(PRUV_DOMAIN, _b32(executor));
        // launchpadMinimum == minSub (300e6): EpochBased needs a real launchpad (batch 1),
        // so the accrued subscribe batch below is batch 2.
        _launchToEpochBased(rex2, 300e6, _b32(executor));

        address carol = makeAddr("carol");

        // epoch 1: 100e6, netIn = 100e6 < minSub, stays Accumulating.
        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(rex2), 100e6);
        rex2.requestDeposit(100e6);
        vm.stopPrank();
        rex2.initiateSubEpoch();

        // epoch 2: 100e6, netIn = 200e6 < minSub, still Accumulating.
        usdc.mint(bob, 100e6);
        vm.startPrank(bob);
        usdc.approve(address(rex2), 100e6);
        rex2.requestDeposit(100e6);
        vm.stopPrank();
        warpToNextPeriod(rex2); // ADR-025: one close per period
        rex2.initiateSubEpoch();

        // epoch 3: 150e6, netIn = 350e6 >= minSub, the batch bridges.
        usdc.mint(carol, 150e6);
        vm.startPrank(carol);
        usdc.approve(address(rex2), 150e6);
        rex2.requestDeposit(150e6);
        vm.stopPrank();
        warpToNextPeriod(rex2); // ADR-025: one close per period
        rex2.initiateSubEpoch();

        wrwaRoute.deliverTokens(_b32(address(rex2)), returned);
        bytes memory body =
            Codec.encode(Instruction({legId: 2, kind: RequestKind.Subscribe, amount: returned, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        rex2.handle(PRUV_DOMAIN, _b32(executor), body);
        rex2.settleSubBatch(2);

        uint256 id1 = encodeId(CLASS_SUB_EPOCH, 1);
        uint256 id2 = encodeId(CLASS_SUB_EPOCH, 2);
        uint256 id3 = encodeId(CLASS_SUB_EPOCH, 3);

        vm.prank(alice);
        rex2.claim(id1, 100e6);
        vm.prank(bob);
        rex2.claim(id2, 100e6);
        vm.prank(carol);
        rex2.claim(id3, 150e6);

        uint256 paid = wrwaRoute.balanceOf(alice) + wrwaRoute.balanceOf(bob) + wrwaRoute.balanceOf(carol);
        assertLe(paid, returned, "never overpays the pot across a multi-epoch batch");
        // 3 epochs, each floors the per-epoch slice once: shortfall bounded accordingly.
        assertGe(paid + 3, returned, "shortfall is bounded by one dust unit per epoch");
    }

    /// totalIn is mutable only while the side is unlocked.
    function testFuzz_totalIn_unchanged_by_claim(uint96 amount, uint96 claimPart) public {
        vm.assume(amount > 1e6 && amount < 1e30);
        vm.assume(claimPart > 0 && claimPart <= amount);

        _deposit(alice, amount);
        _settleWith(amount);

        vm.prank(alice);
        rex.claim(ID1, claimPart);

        (uint256 totalIn,,,,) = rex.epochSide(1, CLASS_SUB_EPOCH);
        assertEq(totalIn, amount, "claim must never move the denominator");
    }

    /// Conservation: every USDC that came in either left over the bridge or was refunded.
    function testFuzz_usdc_conservation(uint96 amount, uint96 cancelPart) public {
        vm.assume(amount > 1e6 && amount < 1e30);
        vm.assume(cancelPart > 0 && cancelPart < amount);

        _deposit(alice, amount);
        vm.prank(alice);
        rex.cancelRequest(ID1, cancelPart);
        rex.initiateSubEpoch();

        assertEq(usdc.balanceOf(address(rex)), 0, "nothing left behind");
        assertEq(usdc.balanceOf(alice), cancelPart, "the cancelled part came back");
    }

    /// @dev Bitmask isolating the `seq` half of a receipt id (Receipt.sol's `encodeId` packs
    /// `class_` into the top 8 bits, `seq` into the low 248), so a receipt id can be mapped
    /// back to the epoch/launchpad seq it belongs to without tracking it separately.
    uint256 constant SEQ_MASK = (uint256(1) << 248) - 1;

    /// Escrow solvency across abort + launchpad (design 11 item 10): `testFuzz_usdc_conservation`
    /// above only drives deposit -> cancel -> initiate. This drives a bounded-random SEQUENCE of
    /// ops (fuzzed selectors + amounts) across requestDeposit, cancelRequest, depositToLaunchpad,
    /// closeLaunchpad, initiateSubEpoch, a simulated SubAborted return delivery, and
    /// claim/claimLaunchpad -- asserting the reservation invariant after EVERY step. Matches the
    /// file's existing `testFuzz_` style (bounded-random inputs), not a stateful-handler
    /// framework: each op is guarded by the on-chain preconditions it needs, read fresh off `r`,
    /// so an op the current state cannot accept is simply skipped rather than reverting.
    function testFuzz_heldEscrowUSDC_solvency_across_abort_and_launchpad(uint8[8] memory ops, uint96[8] memory amts)
        public
    {
        REXPrimary r = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            10e6,
            uint64(block.timestamp + 1),
            1 days,
            10e6,
            0,
            address(0xFEED),
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
        vm.warp(r.launchpadStart());

        uint256 subId; // most recent SUB_EPOCH receipt id alice holds (0 == none yet)
        uint64 lastSubBatchId; // most recently bridged subscribe batch id (0 == none yet)

        for (uint256 i = 0; i < ops.length; i++) {
            uint256 amount = bound(amts[i], 1, 1e12);
            uint8 op = ops[i] % 8;

            if (op == 0) {
                // requestDeposit
                if (r.state() == REXPrimary.LifecycleState.EpochBased) {
                    usdc.mint(alice, amount);
                    vm.startPrank(alice);
                    usdc.approve(address(r), amount);
                    subId = r.requestDeposit(amount);
                    vm.stopPrank();
                }
            } else if (op == 1) {
                // cancelRequest
                if (subId != 0) {
                    uint256 bal = r.balanceOf(alice, subId);
                    uint64 epoch = uint64(subId & SEQ_MASK);
                    (,,,, bool locked) = r.epochSide(epoch, CLASS_SUB_EPOCH);
                    if (bal > 0 && !locked) {
                        uint256 amt = bound(amount, 1, bal);
                        vm.prank(alice);
                        r.cancelRequest(subId, amt);
                    }
                }
            } else if (op == 2) {
                // depositToLaunchpad
                if (
                    r.state() == REXPrimary.LifecycleState.Initialized && block.timestamp >= r.launchpadStart()
                        && block.timestamp < r.launchpadStart() + r.launchpadPeriod()
                ) {
                    usdc.mint(alice, amount);
                    vm.startPrank(alice);
                    usdc.approve(address(r), amount);
                    r.depositToLaunchpad(amount);
                    vm.stopPrank();
                }
            } else if (op == 3) {
                // closeLaunchpad
                if (r.state() == REXPrimary.LifecycleState.Initialized) {
                    uint256 deadline = r.launchpadStart() + r.launchpadPeriod();
                    if (block.timestamp < deadline) vm.warp(deadline);
                    r.closeLaunchpad();
                }
            } else if (op == 4) {
                // initiateSubEpoch -- ADR-018: no single-in-flight guard, batches run in parallel
                if (r.state() == REXPrimary.LifecycleState.EpochBased) {
                    uint64 epoch = r.currentEpochId();
                    (uint256 totalIn,,,,) = r.epochSide(epoch, CLASS_SUB_EPOCH);
                    if (totalIn > 0) {
                        // ADR-025: the trigger is schedule-gated. Mirrored exactly, like every other gate
                        // here, by stepping to the next due moment -- so this action still FIRES instead
                        // of turning into a silent TooEarly revert that the fuzzer would discard.
                        warpToNextPeriod(r);
                        r.initiateSubEpoch();
                        (,,, uint64 batchId,) = r.epochSide(epoch, CLASS_SUB_EPOCH);
                        if (batchId != 0) lastSubBatchId = batchId;
                    }
                }
            } else if (op == 5) {
                // simulated SubAborted return delivery, on the most recently bridged batch
                uint64 bId = lastSubBatchId;
                if (bId != 0) {
                    (uint8 status, uint256 netIn,) = r.subBatch(bId);
                    if (status == uint8(BatchStatus.Bridged)) {
                        usdc.mint(address(r), netIn); // simulate the unlocked collateral arriving back
                        bytes memory body = Codec.encode(
                            Instruction({legId: bId, kind: RequestKind.SubAborted, amount: netIn, navAtInitiate: 1e18})
                        );
                        vm.prank(address(mailbox));
                        r.handle(PRUV_DOMAIN, _b32(executor), body);
                    }
                }
            } else if (op == 6) {
                // claim (SUB_EPOCH)
                if (subId != 0) {
                    uint256 bal = r.balanceOf(alice, subId);
                    if (bal > 0) {
                        uint64 epoch = uint64(subId & SEQ_MASK);
                        (,, uint256 netAmount, uint64 batchId,) = r.epochSide(epoch, CLASS_SUB_EPOCH);
                        if (netAmount > 0 && batchId != 0) {
                            (uint8 status,,) = r.subBatch(batchId);
                            if (status == uint8(BatchStatus.Released) || status == uint8(BatchStatus.Aborted)) {
                                uint256 amt = bound(amount, 1, bal);
                                vm.prank(alice);
                                r.claim(subId, amt);
                            }
                        }
                    }
                }
            } else {
                // claimLaunchpad
                uint256 lpId = encodeId(CLASS_LAUNCHPAD, LAUNCHPAD_ID);
                uint256 bal = r.balanceOf(alice, lpId);
                if (bal > 0) {
                    (,, uint256 netAmount, uint64 batchId,) = r.epochSide(LAUNCHPAD_ID, CLASS_LAUNCHPAD);
                    if (netAmount > 0 && batchId != 0) {
                        (uint8 status,,) = r.subBatch(batchId);
                        if (status == uint8(BatchStatus.Released) || status == uint8(BatchStatus.Aborted)) {
                            uint256 amt = bound(amount, 1, bal);
                            vm.prank(alice);
                            r.claimLaunchpad(amt);
                        }
                    }
                }
            }

            assertGe(usdc.balanceOf(address(r)), r.heldEscrowUSDC(), "escrow solvency broke");
        }
    }

    // ------------------------------------------------------------------------------------------
    // SC5a Task 7 -- redeem reserve solvency (stateful campaign via REXPrimaryRedeemHandler).
    // ------------------------------------------------------------------------------------------

    /// @dev USDC solvency (design 1/5): every USDC a fulfilled-but-unclaimed redeem batch
    /// (settledRedeemUSDC) or a cancellable subscribe/launchpad request (heldEscrowUSDC) is owed
    /// must be physically held by the pool.
    function invariant_usdcSolvent() public view {
        REXPrimary r = handler.pool();
        assertGe(usdc.balanceOf(address(r)), r.heldEscrowUSDC() + r.settledRedeemUSDC());
    }

    /// @dev wRWA solvency: every wRWA a settled-unclaimed pot (subscribe returns + aborted
    /// redeems) or a still-live redeemer's escrow is owed must be physically held.
    function invariant_wrwaSolvent() public view {
        REXPrimary r = handler.pool();
        assertGe(IERC20(address(wrwaRoute)).balanceOf(address(r)), r.settledUnclaimed() + r.liveRedeemEscrow());
    }

    /// @dev Claim-totality: the handler only calls `claim` when its own ghost-eligibility check
    /// mirrors the contract's gate (Settled/Released, or netAmount==0 && locked) AND the actor
    /// holds a real balance. Under that precondition `claim` must never revert -- neither for the
    /// subscribe id class nor (this task's target) the RED_EPOCH id class.
    function invariant_claimNeverRevertsWhenEligible() public view {
        assertFalse(handler.claimSubUnexpectedRevert(), "subscribe claim reverted while eligible");
        assertFalse(handler.claimRedeemUnexpectedRevert(), "redeem claim reverted while eligible");
    }

    /// @dev SC6b Task 7 -- counter-equivalence (the safety net for a missed exactly-once terminal
    /// hook): `outstandingSubBatches` is a subtraction of two counters
    /// (`nextSubBatchId - 1 - subBatchesTerminated`), so a batch double-counted into
    /// `subBatchesTerminated` would eventually underflow that view and revert the fuzz run rather
    /// than silently drift; this invariant additionally proves the derived count matches the real
    /// non-terminal ({Accumulating, Bridged}) batch count at every step, not just that it never
    /// underflows.
    function invariant_outstandingSub_matches_nonterminal() public view {
        REXPrimary r = handler.pool();
        uint64 n;
        uint64 next = r.nextSubBatchId();
        for (uint64 i = 1; i < next; i++) {
            (uint8 status,,) = r.subBatch(i);
            if (status == uint8(BatchStatus.Accumulating) || status == uint8(BatchStatus.Bridged)) n++;
        }
        assertEq(r.outstandingSubBatches(), n, "outstandingSubBatches drifted from the real non-terminal count");
    }

    /// @dev Redeem-leg analogue of `invariant_outstandingSub_matches_nonterminal`.
    function invariant_outstandingRedeem_matches_nonterminal() public view {
        REXPrimary r = handler.pool();
        uint64 n;
        uint64 next = r.nextRedeemBatchId();
        for (uint64 i = 1; i < next; i++) {
            (uint8 status,,,) = r.redeemBatch(i);
            if (status == uint8(BatchStatus.Accumulating) || status == uint8(BatchStatus.Bridged)) n++;
        }
        assertEq(r.outstandingRedeemBatches(), n, "outstandingRedeemBatches drifted from the real non-terminal count");
    }
}

/// @notice SC5a Task 7 -- stateful handler for the redeem-reserve solvency invariant campaign.
/// @dev Deploys its OWN REXPrimary (`pool`), reusing the outer test's usdc/usdcRoute/wrwaRoute/
/// mailbox/navOracle (independent per-pool balances -- the mocks don't care which pool calls
/// them). `minSub == 0` (subscribe always bridges same-epoch, mirroring the outer `rex` fixture
/// and out of THIS task's focus) but `minRedeem > 0`, so on the redeem side -- the actual
/// target -- Accumulating and (via `warp`) Released are both reachable. `pool` is both owner and
/// keeper of itself (deployed by this contract), so admin calls need no prank; actor calls pick from a small fixed roster via
/// a fuzzed seed and prank as that actor, decoupling "who Foundry calls the handler as"
/// (irrelevant) from "which economic actor acts" (bounded, honest). Every entrypoint re-reads
/// on-chain state and no-ops when its precondition is not met, so a call Foundry cannot use yet
/// is skipped rather than reverted (genuine coverage, not reverts -- task brief). `claimSub`/
/// `claimRedeem` are the one deliberate exception: they try/catch and latch a ghost flag,
/// because `fail_on_revert = false` (profile default, foundry.toml) would otherwise silently
/// swallow a genuine claim-totality violation instead of surfacing it as a failing invariant.
contract REXPrimaryRedeemHandler is Test {
    uint32 constant PRUV_DOMAIN = 7336;
    uint256 constant MIN_REDEEM = 20e6; // wRWA (ADR-026 D2); the mock wRWA route is 6-decimal
    uint256 constant MAX_AMOUNT = 200e6;

    MockMailbox public mailbox;
    MockERC20 public usdc;
    MockCollateralWarpRoute public usdcRoute;
    MockSyntheticWarpRoute public wrwaRoute;
    MockNavOracle public navOracle;
    REXPrimary public pool;
    address public executor;
    /// @notice SC13 ADR-028: one micro-unit of `usdc` in its own decimals, so this handler's USDC
    /// amounts stay whole micro-units under an 18-decimal fixture (REXPrimaryInvariant18Test) and
    /// collapse to 1 under the 6-decimal fixture, leaving the original campaign unchanged.
    uint256 public immutable U;
    /// @notice SC6b Task 7 -- an unrelated ERC20 with no reservation on `pool`, so `sweep` can be
    /// fuzzed against a genuinely "stray" token (full-balance sweepable) alongside usdc/wrwaRoute
    /// (reservation-bounded).
    MockERC20 public strayToken;

    address[3] public actors;
    uint256[] public subIds;
    uint256[] public redIds;
    mapping(uint64 => bool) public redeemReturnDelivered;
    mapping(uint64 => bool) public subReturnDelivered;

    bool public claimSubUnexpectedRevert;
    bool public claimRedeemUnexpectedRevert;
    bytes public claimSubRevertData;
    bytes public claimRedeemRevertData;

    uint256 public maxSettledRedeemUSDC;
    uint256 public maxSettledUnclaimed;
    uint256 public maxLiveRedeemEscrow;

    constructor(
        MockERC20 usdc_,
        MockMailbox mailbox_,
        MockCollateralWarpRoute usdcRoute_,
        MockSyntheticWarpRoute wrwaRoute_,
        MockNavOracle navOracle_,
        address executor_
    ) {
        usdc = usdc_;
        mailbox = mailbox_;
        usdcRoute = usdcRoute_;
        wrwaRoute = wrwaRoute_;
        navOracle = navOracle_;
        executor = executor_;
        U = 10 ** (usdc_.decimals() - 6);
        wrwaRoute.setGasQuote(0); // SC5a: redeem bridges wRWA out; every leg stays fee-free

        pool = new REXPrimary(
            IERC20(address(usdc)),
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            0, // minSub: subscribe always bridges same-epoch -- out of this task's focus
            uint64(block.timestamp + 1),
            1 days,
            0,
            0,
            address(0xFEE),
            SC3Params({
                navOracle: INavOracle(address(navOracle)),
                minRedeem: MIN_REDEEM, // nonzero: Accumulating/Released/every matching zone reachable
                redeemCancelFeeBps: 0,
                subFulfillTimeout: 10 days,
                redemptionFeeBps: 0,
                redeemFulfillTimeout: 10 days,
                windDownWindow: 9 days,
                schedule: perSecondSchedule()
            })
        );
        pool.enrollRemote(PRUV_DOMAIN, _b32(executor));
        vm.warp(pool.launchpadStart() + pool.launchpadPeriod());
        pool.closeLaunchpad(); // vacuous (launchpadMinimum 0) -> EpochBased, no batch

        strayToken = new MockERC20("STRAY", 18);

        actors[0] = makeAddr("handlerActor0");
        actors[1] = makeAddr("handlerActor1");
        actors[2] = makeAddr("handlerActor2");
    }

    receive() external payable {}

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    /// @dev Picks an id from `ids` and the first of the 3 fixed actors (starting at
    /// `actorSeed`) that currently holds a nonzero balance of it; `who == address(0)` tells the
    /// caller there is nothing to do.
    function _pickHolder(uint256[] storage ids, uint256 idSeed, uint256 actorSeed)
        internal
        view
        returns (uint256 id, address who, uint256 bal)
    {
        if (ids.length == 0) return (0, address(0), 0);
        id = ids[idSeed % ids.length];
        // mod actorSeed down FIRST -- actorSeed is a raw fuzzed uint256 (Foundry loves
        // type(uint256).max), and actors.length is a tiny constant, so adding `i` to the
        // UNREDUCED seed would checked-overflow at the top of its range.
        uint256 start = actorSeed % actors.length;
        for (uint256 i = 0; i < actors.length; i++) {
            address cand = actors[(start + i) % actors.length];
            uint256 b = pool.balanceOf(cand, id);
            if (b > 0) return (id, cand, b);
        }
        return (id, address(0), 0);
    }

    /// @dev A Bridged redeem batch with no return recorded yet (ghost-tracked: `redeemBatch`
    /// has no `returnReceived` projection, unlike `subBatchLeg`).
    function _pickOpenRedeemBatch(uint256 seed) internal view returns (uint64) {
        uint64 n = pool.nextRedeemBatchId();
        if (n <= 1) return 0; // ids start at 1; none opened yet
        uint64 batchId = uint64((seed % (n - 1)) + 1);
        if (redeemReturnDelivered[batchId]) return 0;
        (uint8 status,,,) = pool.redeemBatch(batchId);
        if (status != uint8(BatchStatus.Bridged)) return 0;
        return batchId;
    }

    /// @dev ADR-018 twin of `_pickOpenRedeemBatch`: a Bridged subscribe batch with no return
    /// recorded yet. Subscribe batches now run in parallel (no single in-flight slot), so a
    /// batch is picked the same way the redeem side already does -- by seed over the id space,
    /// ghost-tracked via `subReturnDelivered` since `subBatchLeg.returnReceived` alone cannot
    /// distinguish "delivered" from "delivered and already resolved onward" once the handler
    /// has stopped re-polling a batch it has already handled.
    function _pickOpenSubBatch(uint256 seed) internal view returns (uint64) {
        uint64 n = pool.nextSubBatchId();
        if (n <= 1) return 0; // ids start at 1; none opened yet
        uint64 batchId = uint64((seed % (n - 1)) + 1);
        if (subReturnDelivered[batchId]) return 0;
        (uint8 status,,) = pool.subBatch(batchId);
        if (status != uint8(BatchStatus.Bridged)) return 0;
        return batchId;
    }

    function _snapshot() internal {
        uint256 sr = pool.settledRedeemUSDC();
        if (sr > maxSettledRedeemUSDC) maxSettledRedeemUSDC = sr;
        uint256 su = pool.settledUnclaimed();
        if (su > maxSettledUnclaimed) maxSettledUnclaimed = su;
        uint256 lre = pool.liveRedeemEscrow();
        if (lre > maxLiveRedeemEscrow) maxLiveRedeemEscrow = lre;
    }

    // ------------------------------------------------------------------
    // subscribe side (support: exercises the redeem side's shared initiateSubEpoch trigger;
    // ADR-018 -- batches run in PARALLEL, so every entrypoint below picks ITS OWN batch by seed,
    // mirroring the redeem side's `_pickOpenRedeemBatch`, instead of reading a single in-flight id)
    // ------------------------------------------------------------------

    function requestDeposit(uint256 actorSeed, uint256 amount) external {
        _snapshot();
        if (pool.state() != REXPrimary.LifecycleState.EpochBased) return;
        amount = bound(amount, 1, MAX_AMOUNT) * U;
        address who = _actor(actorSeed);
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), amount);
        uint256 id = pool.requestDeposit(amount);
        vm.stopPrank();
        subIds.push(id);
    }

    function cancelSub(uint256 idSeed, uint256 actorSeed, uint256 amount) external {
        _snapshot();
        (uint256 id, address who, uint256 bal) = _pickHolder(subIds, idSeed, actorSeed);
        if (who == address(0)) return;
        // ADR-027: `locked` is no longer the gate -- a consumed side is still cancellable while
        // its batch accrues, and that is precisely the window whose solvency needs fuzzing. Mirror
        // the contract's own gate: unconsumed, or consumed into a still-Accumulating batch.
        (,,, uint64 batchId, bool locked) = pool.epochSide(seqOf(id), CLASS_SUB_EPOCH);
        if (locked) {
            (uint8 bs,,) = pool.subBatch(batchId);
            if (bs != uint8(BatchStatus.Accumulating)) return;
        }
        if (bal < U) return;
        amount = bound(amount, 1, bal / U) * U;
        vm.prank(who);
        pool.cancelRequest(id, amount);
    }

    function deliverSubReturn(uint256 batchSeed, uint256 amount) external {
        _snapshot();
        uint64 batchId = _pickOpenSubBatch(batchSeed);
        if (batchId == 0) return;
        amount = bound(amount, 1, MAX_AMOUNT);
        wrwaRoute.deliverTokens(_b32(address(pool)), amount);
        bytes memory body = Codec.encode(
            Instruction({legId: batchId, kind: RequestKind.Subscribe, amount: amount, navAtInitiate: 1e18})
        );
        vm.prank(address(mailbox));
        pool.handle(PRUV_DOMAIN, _b32(executor), body);
        subReturnDelivered[batchId] = true;
    }

    function deliverSubAborted(uint256 batchSeed) external {
        _snapshot();
        uint64 batchId = _pickOpenSubBatch(batchSeed);
        if (batchId == 0) return;
        (, uint256 netIn,) = pool.subBatch(batchId);
        usdc.mint(address(pool), netIn);
        bytes memory body = Codec.encode(
            Instruction({legId: batchId, kind: RequestKind.SubAborted, amount: netIn / U, navAtInitiate: 1e18})
        );
        vm.prank(address(mailbox));
        pool.handle(PRUV_DOMAIN, _b32(executor), body);
        subReturnDelivered[batchId] = true;
    }

    function settleSub(uint256 batchSeed) external {
        _snapshot();
        uint64 n = pool.nextSubBatchId();
        if (n <= 1) return;
        uint64 batchId = uint64((batchSeed % (n - 1)) + 1);
        if (!subReturnDelivered[batchId]) return;
        (uint8 status,,) = pool.subBatch(batchId);
        if (status != uint8(BatchStatus.Bridged)) return;
        pool.settleSubBatch(batchId);
    }

    function claimSub(uint256 idSeed, uint256 actorSeed, uint256 amount) external {
        _snapshot();
        (uint256 id, address who, uint256 bal) = _pickHolder(subIds, idSeed, actorSeed);
        if (who == address(0)) return;
        (,, uint256 netAmount, uint64 batchId, bool locked) = pool.epochSide(seqOf(id), CLASS_SUB_EPOCH);
        bool claimable;
        if (netAmount == 0) {
            claimable = locked;
        } else {
            (uint8 status,,) = pool.subBatch(batchId);
            claimable = status == uint8(BatchStatus.Settled) || status == uint8(BatchStatus.Released)
                || status == uint8(BatchStatus.Aborted);
        }
        if (!claimable) return;
        amount = bound(amount, 1, bal);
        vm.prank(who);
        try pool.claim(id, amount) {}
        catch (bytes memory reason) {
            claimSubUnexpectedRevert = true;
            claimSubRevertData = reason;
        }
    }

    // ------------------------------------------------------------------
    // redeem side (SC5a Task 7 -- this task's actual target)
    // ------------------------------------------------------------------

    function requestRedeem(uint256 actorSeed, uint256 amount) external {
        _snapshot();
        if (pool.state() != REXPrimary.LifecycleState.EpochBased) return;
        amount = bound(amount, 1, MAX_AMOUNT);
        address who = _actor(actorSeed);
        wrwaRoute.deliverTokens(_b32(who), amount);
        vm.startPrank(who);
        IERC20(address(wrwaRoute)).approve(address(pool), amount);
        uint256 id = pool.requestRedeem(amount);
        vm.stopPrank();
        redIds.push(id);
    }

    function cancelRedeem(uint256 idSeed, uint256 actorSeed, uint256 amount) external {
        _snapshot();
        (uint256 id, address who, uint256 bal) = _pickHolder(redIds, idSeed, actorSeed);
        if (who == address(0)) return;
        // ADR-027, mirroring `cancelSub` above: the accruing window is cancellable on this leg too.
        (,,, uint64 batchId, bool locked) = pool.epochSide(seqOf(id), CLASS_RED_EPOCH);
        if (locked) {
            (uint8 bs,,,) = pool.redeemBatch(batchId);
            if (bs != uint8(BatchStatus.Accumulating)) return;
        }
        amount = bound(amount, 1, bal);
        vm.prank(who);
        pool.cancelRequest(id, amount);
    }

    function deliverRedeemReturn(uint256 batchSeed, uint256 amount) external {
        _snapshot();
        uint64 batchId = _pickOpenRedeemBatch(batchSeed);
        if (batchId == 0) return;
        amount = bound(amount, 1, MAX_AMOUNT) * U;
        usdc.mint(address(usdcRoute), amount);
        usdcRoute.deliverTokens(_b32(address(pool)), amount);
        bytes memory body = Codec.encode(
            Instruction({legId: batchId, kind: RequestKind.Redeem, amount: amount / U, navAtInitiate: 1e18})
        );
        vm.prank(address(mailbox));
        pool.handle(PRUV_DOMAIN, _b32(executor), body);
        redeemReturnDelivered[batchId] = true;
    }

    /// @dev Land a redeem batch's USDC return WITHOUT its paired instruction -- the unordered
    /// rendezvous window of spec §3.4. Exploration only: it puts every other invariant in this
    /// campaign in front of a balance fatter than any reserve counter knows about. The property
    /// that this money is never taken is proven in `RecoveryResidualInvariantTest`, whose clock
    /// actually reaches a bridge deadline (this campaign's `warp` is capped at 6 hours against a
    /// 10-day timeout, so recovery here is nearly unreachable -- measured, not assumed).
    function landRedeemTokensOnly(uint256 batchSeed, uint256 amount) external {
        _snapshot();
        uint64 batchId = _pickOpenRedeemBatch(batchSeed);
        if (batchId == 0) return;
        amount = bound(amount, 1, MAX_AMOUNT) * U;
        usdc.mint(address(usdcRoute), amount);
        usdcRoute.deliverTokens(_b32(address(pool)), amount);
    }

    /// @dev Delivers the batch's OWN `netIn`, not a fuzzed amount -- an abort is a straight
    /// refund of what was bridged, never a NAV conversion (mirrors `deliverSubAborted` and every
    /// hand-written *Aborted test in the suite). `_claimRedeem`'s Released/Aborted wRWA-refund
    /// branch splits purely by the epoch-level ratio (`s.netAmount/s.totalIn`), unlike the
    /// Fulfilled branch, which additionally scales by the batch-level `returnedAmount/netIn` --
    /// so an abort return smaller than `netIn` (which `_onInstruction` does not itself reject)
    /// can underflow `settledUnclaimed` once cumulative claims exceed the actually-recorded pot.
    /// See the Task 7 report for the counterexample this surfaced and why it is out of THIS
    /// harness's scope (constructing it needs an honest-executor violation, not a call sequence
    /// reachable through REXPrimary's own permissionless surface).
    function deliverRedeemAborted(uint256 batchSeed) external {
        _snapshot();
        uint64 batchId = _pickOpenRedeemBatch(batchSeed);
        if (batchId == 0) return;
        (, uint256 netIn,,) = pool.redeemBatch(batchId);
        wrwaRoute.deliverTokens(_b32(address(pool)), netIn);
        bytes memory body = Codec.encode(
            Instruction({legId: batchId, kind: RequestKind.RedeemAborted, amount: netIn, navAtInitiate: 1e18})
        );
        vm.prank(address(mailbox));
        pool.handle(PRUV_DOMAIN, _b32(executor), body);
        redeemReturnDelivered[batchId] = true;
    }

    function settleRedeem(uint256 batchSeed) external {
        _snapshot();
        uint64 n = pool.nextRedeemBatchId();
        if (n <= 1) return;
        uint64 batchId = uint64((batchSeed % (n - 1)) + 1);
        if (!redeemReturnDelivered[batchId]) return;
        (uint8 status,,,) = pool.redeemBatch(batchId);
        if (status != uint8(BatchStatus.Bridged)) return;
        pool.settleRedeemBatch(batchId);
    }

    function claimRedeem(uint256 idSeed, uint256 actorSeed, uint256 amount) external {
        _snapshot();
        (uint256 id, address who, uint256 bal) = _pickHolder(redIds, idSeed, actorSeed);
        if (who == address(0)) return;
        (,, uint256 netAmount, uint64 batchId, bool locked) = pool.epochSide(seqOf(id), CLASS_RED_EPOCH);
        bool claimable;
        if (netAmount == 0) {
            claimable = locked;
        } else {
            (uint8 status,,,) = pool.redeemBatch(batchId);
            claimable = status == uint8(BatchStatus.Settled) || status == uint8(BatchStatus.Released);
        }
        if (!claimable) return;
        amount = bound(amount, 1, bal);
        vm.prank(who);
        try pool.claim(id, amount) {}
        catch (bytes memory reason) {
            claimRedeemUnexpectedRevert = true;
            claimRedeemRevertData = reason;
        }
    }

    // ------------------------------------------------------------------
    // epoch trigger + time
    // ------------------------------------------------------------------

    function initiate() external {
        _snapshot();
        if (pool.state() != REXPrimary.LifecycleState.EpochBased) return;
        uint64 epoch = pool.currentEpochId();
        (uint256 subIn,,,,) = pool.epochSide(epoch, CLASS_SUB_EPOCH);
        (uint256 redIn,,,,) = pool.epochSide(epoch, CLASS_RED_EPOCH);
        if (subIn == 0 && redIn == 0) return;
        // ADR-025: the trigger is schedule-gated. Mirrored exactly, like every other gate
        // here, by stepping to the next due moment -- so this action still FIRES instead
        // of turning into a silent TooEarly revert that the fuzzer would discard.
        warpToNextPeriod(pool);
        pool.initiateSubEpoch();
    }

    function warp(uint256 delta) external {
        _snapshot();
        delta = bound(delta, 0, 6 hours);
        vm.warp(block.timestamp + delta);
    }

    // ------------------------------------------------------------------
    // SC6b Task 7 -- lifecycle (wind-down/shut-down) + sweep. Every action re-derives the exact
    // on-chain gate its contract counterpart checks (mirroring, not guessing), so a call this
    // handler makes never reverts -- it either satisfies the real precondition or no-ops.
    // ------------------------------------------------------------------

    /// @dev Only fires in `EpochBased` (the contract's own guard) -- self-gated so an
    /// already-wound-down or still-`Initialized`/`ShutDown` pool is a silent no-op, never a revert.
    /// @dev Local mirror of the (now internal, for EIP-170) `windDownStart`: stamped when this
    /// handler triggers wind-down, so the stale-release/shut-down gates below stay revert-free
    /// without reading the demoted getter.
    uint64 internal _wdStart;

    function triggerWindDown() external {
        _snapshot();
        if (pool.state() != REXPrimary.LifecycleState.EpochBased) return;
        pool.triggerWindDown();
        _wdStart = uint64(block.timestamp);
    }

    /// @dev Mirrors `releaseStaleRedeemBatch`'s own gate exactly (state, batch status, and the
    /// wind-down-window clause -- ADR-027 removed the ordinary `maxRedeemWait` one) so it only
    /// ever calls onto a batch genuinely eligible to drain.
    function releaseStale(uint256 batchSeed) external {
        _snapshot();
        REXPrimary.LifecycleState st = pool.state();
        if (st != REXPrimary.LifecycleState.EpochBased && st != REXPrimary.LifecycleState.WindDown) return;
        uint64 n = pool.nextRedeemBatchId();
        if (n <= 1) return;
        uint64 batchId = uint64((batchSeed % (n - 1)) + 1);
        (uint8 status,,,) = pool.redeemBatch(batchId);
        if (status != uint8(BatchStatus.Accumulating)) return;
        if (st != REXPrimary.LifecycleState.WindDown || block.timestamp < _wdStart + pool.windDownWindow()) return;
        pool.releaseStaleRedeemBatch(batchId);
    }

    /// @dev Fuzzes both protocol tokens (usdc/wrwaRoute, reservation-bounded exactly as `sweep`
    /// itself computes `free`) and a genuinely stray third token (no reservation, full balance
    /// sweepable) -- the boundary proof: bounding `amount <= free` here means a break in
    /// `invariant_usdcSolvent`/`invariant_wrwaSolvent` could only come from `sweep` mis-tracking
    /// the reservation, not from this harness ever asking it to over-sweep.
    function sweep(uint256 tokenSeed, uint256 amount, uint256 strayMint) external {
        _snapshot();
        uint256 t = tokenSeed % 3;
        address token;
        if (t == 0) {
            token = address(usdc);
        } else if (t == 1) {
            token = address(wrwaRoute);
        } else {
            token = address(strayToken);
            strayMint = bound(strayMint, 0, MAX_AMOUNT);
            if (strayMint > 0) strayToken.mint(address(pool), strayMint);
        }
        uint256 free = IERC20(token).balanceOf(address(pool));
        if (token == address(usdc)) {
            free -= (pool.heldEscrowUSDC() + pool.settledRedeemUSDC());
        } else if (token == address(wrwaRoute)) {
            free -= (pool.liveRedeemEscrow() + pool.settledUnclaimed());
        }
        if (free == 0) return;
        amount = bound(amount, 1, free);
        // 2026-09-18: a protocol token's free balance may go only to the immutable `feeRecipient`;
        // a stray token may go anywhere, so this handler stays the recipient for that one.
        pool.sweep(token, token == address(strayToken) ? address(this) : pool.feeRecipient(), amount);
    }

    /// @dev Mirrors `triggerShutDown`'s own gate exactly (state, window elapsed, both outstanding
    /// counters zero). Deliberately NOT a raw unguarded selector -- `ShutDown` is terminal, so an
    /// unguarded call would frequently revert (WindDownNotComplete) and, once it succeeded, brick
    /// every state-gated action for the rest of the run. Gating it here instead means it only ever
    /// fires when the transition is genuinely legal, and every other action in this handler already
    /// self-gates on `EpochBased`/`WindDown` (returning early otherwise), so `ShutDown` is simply
    /// one more terminal state those guards already tolerate -- the run keeps going, 0-revert, and
    /// still exercises claim/cancel/sweep against a shut-down pool.
    function triggerShutDown() external {
        _snapshot();
        if (pool.state() != REXPrimary.LifecycleState.WindDown) return;
        if (block.timestamp < _wdStart + pool.windDownWindow()) return;
        if (pool.outstandingSubBatches() != 0 || pool.outstandingRedeemBatches() != 0) return;
        pool.triggerShutDown();
    }
}

/// @notice Migrated from the deleted `invariants/ZoneInvariant.t.sol` (ADR-024). That file held two
/// invariants: the spec section 8 zone invariant died with matching, this one did NOT --
/// `invariant_min_respected_never_bridges_submin` is spec section 14 (never send Pruv a below-minimum
/// ticket), which stands on `minSub`/`minRedeem` as Pruv's batch thresholds, not on any netting.
/// It keeps the same handler wiring: fuzz over a NAV that VARIES within the campaign (every other
/// harness in the suite fixes `MockNavOracle(1e18)`, which is why H-2 shipped past a green board).
///
/// Handler design: after ADR-026 D2 both minimums are compared against the batch's own accrued
/// amount in its own unit -- `minSub` against USDC, `minRedeem` against wRWA -- so no price enters
/// the bridge decision on either leg. The fuzzed `setNav` therefore inverts its former role: it used
/// to supply the number the invariant had to replay (ghost-tracked per batch touch, because the old
/// gate re-valued the whole accrual at whatever nav the LAST touch read), and it now exists to prove
/// that varying the price cannot move the branch point at all. Any surviving NAV term in the redeem
/// gate would show up here as a Bridged batch whose `netIn` is under `minRedeem`.
contract MinRespectedInvariantTest is Test {
    MinRespectedHandler handler;

    function setUp() public {
        handler = new MinRespectedHandler();

        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.requestDeposit.selector;
        selectors[1] = handler.requestRedeem.selector;
        selectors[2] = handler.cancelSub.selector;
        selectors[3] = handler.cancelRedeem.selector;
        selectors[4] = handler.setNav.selector;
        selectors[5] = handler.initiate.selector;
        targetContract(address(handler));
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev ADR-027 coverage, measured rather than assumed. `REXPrimaryInvariantTest` owns the
    /// solvency invariants but its pool runs `minSub: 0`, so a subscribe side bridges in the same
    /// transaction that locks it and its widened cancel handler is dead code -- 128,000 calls
    /// reached the locked-and-accruing branch zero times (counter-probed, not inferred; a
    /// reverting handler proves nothing because a revert is counted, not failed). THIS suite's
    /// pool has a real `minSub`, so it is the only campaign where a subscribe cancel mid-accrual
    /// happens at all -- which makes it the only place these two can observe the decrement.
    function invariant_minRespected_usdcSolvent() public view {
        REXPrimary r = handler.pool();
        assertGe(
            handler.usdc().balanceOf(address(r)),
            r.heldEscrowUSDC() + r.settledRedeemUSDC(),
            "usdc owed exceeds usdc held"
        );
    }

    function invariant_minRespected_wrwaSolvent() public view {
        REXPrimary r = handler.pool();
        assertGe(
            IERC20(address(handler.wrwaRoute())).balanceOf(address(r)),
            r.settledUnclaimed() + r.liveRedeemEscrow(),
            "wrwa owed exceeds wrwa held"
        );
    }

    /// @dev spec section 14 min-respected -- every Bridged batch, either leg, cleared its own
    /// minimum at the nav its bridge decision was made under.
    function invariant_min_respected_never_bridges_submin() public view {
        REXPrimary r = handler.pool();

        uint64 nextSub = r.nextSubBatchId();
        for (uint64 i = 1; i < nextSub; i++) {
            (uint8 status, uint256 netIn,) = r.subBatch(i);
            if (status != uint8(BatchStatus.Bridged)) continue;
            assertGe(netIn, r.minSub(), "min-respected: sub-min sub batch bridged");
        }

        uint64 nextRedeem = r.nextRedeemBatchId();
        for (uint64 i = 1; i < nextRedeem; i++) {
            (uint8 status, uint256 netIn,,) = r.redeemBatch(i);
            if (status != uint8(BatchStatus.Bridged)) continue;
            assertGe(netIn, r.minRedeem(), "min-respected: sub-min redeem batch bridged");
        }
    }
}

/// @notice Stateful handler backing `MinRespectedInvariantTest`. Deliberately narrow -- only the
/// actions that can drive a below-minimum side (deposit/redeem/cancel/vary nav/initiate), no
/// settle/claim/bridge-return legs: the invariant only depends on state `initiateSubEpoch` itself
/// finalizes (batch bridge decisions), which is fixed the instant that call returns and never
/// revisited by the async round trip.
contract MinRespectedHandler is Test {
    uint32 constant PRUV_DOMAIN = 7336;
    uint256 constant MIN_SUB = 15e6;
    uint256 constant MIN_REDEEM = 20e6; // wRWA (ADR-026 D2); the mock wRWA route is 6-decimal
    uint256 constant MAX_AMOUNT = 500e6;
    uint256 constant MIN_NAV = 0.1e18;
    uint256 constant MAX_NAV = 5e18;

    MockMailbox public mailbox;
    MockERC20 public usdc;
    MockCollateralWarpRoute public usdcRoute;
    MockSyntheticWarpRoute public wrwaRoute;
    MockNavOracle public navOracle;
    REXPrimary public pool;
    address public executor = makeAddr("minRespectedExecutor");

    address[3] public actors;
    uint256[] public subIds;
    uint256[] public redIds;

    receive() external payable {}

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    constructor() {
        mailbox = new MockMailbox(PRUV_DOMAIN);
        mailbox.setQuoteFee(0);
        usdc = new MockERC20("USDC", 6);
        usdcRoute = new MockCollateralWarpRoute(usdc);
        usdcRoute.setGasQuote(0);
        wrwaRoute = new MockSyntheticWarpRoute("wRWA", 6);
        wrwaRoute.setGasQuote(0);
        navOracle = new MockNavOracle(1e18); // varied at runtime via `setNav`

        pool = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            MIN_SUB,
            uint64(block.timestamp + 1),
            1 days,
            MIN_SUB, // launchpadMinimum_ -- must be >= minSub_, so a real (non-vacuous) launchpad round
            0,
            address(0xFEE),
            SC3Params({
                navOracle: INavOracle(address(navOracle)),
                minRedeem: MIN_REDEEM,
                redeemCancelFeeBps: 0,
                subFulfillTimeout: 10 days,
                redemptionFeeBps: 0,
                redeemFulfillTimeout: 10 days,
                windDownWindow: 9 days,
                schedule: perSecondSchedule()
            })
        );
        pool.enrollRemote(PRUV_DOMAIN, _b32(executor));

        // Real launchpad round-trip (MIN_SUB > 0 forbids the vacuous zero-raise close every other
        // harness in the suite uses) -- occupies sub batch id 1, so the accrued-epoch batches this
        // handler drives start at id 2, mirroring `REXPrimaryInvariantTest`'s `_launchToEpochBased`.
        address seeder = makeAddr("minRespectedSeeder");
        usdc.mint(seeder, MIN_SUB);
        vm.warp(pool.launchpadStart());
        vm.startPrank(seeder);
        usdc.approve(address(pool), MIN_SUB);
        pool.depositToLaunchpad(MIN_SUB);
        vm.stopPrank();
        vm.warp(pool.launchpadStart() + pool.launchpadPeriod());
        pool.closeLaunchpad();
        wrwaRoute.deliverTokens(_b32(address(pool)), MIN_SUB);
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Subscribe, amount: MIN_SUB, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        pool.handle(PRUV_DOMAIN, _b32(executor), body);
        pool.settleSubBatch(1);

        actors[0] = makeAddr("minRespectedActor0");
        actors[1] = makeAddr("minRespectedActor1");
        actors[2] = makeAddr("minRespectedActor2");
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % actors.length];
    }

    function _pickHolder(uint256[] storage ids, uint256 idSeed, uint256 actorSeed)
        internal
        view
        returns (uint256 id, address who, uint256 bal)
    {
        if (ids.length == 0) return (0, address(0), 0);
        id = ids[idSeed % ids.length];
        uint256 start = actorSeed % actors.length;
        for (uint256 i = 0; i < actors.length; i++) {
            address cand = actors[(start + i) % actors.length];
            uint256 b = pool.balanceOf(cand, id);
            if (b > 0) return (id, cand, b);
        }
        return (id, address(0), 0);
    }

    function requestDeposit(uint256 actorSeed, uint256 amount) external {
        if (pool.state() != REXPrimary.LifecycleState.EpochBased) return;
        amount = bound(amount, 1, MAX_AMOUNT);
        address who = _actor(actorSeed);
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), amount);
        uint256 id = pool.requestDeposit(amount);
        vm.stopPrank();
        subIds.push(id);
    }

    function requestRedeem(uint256 actorSeed, uint256 amount) external {
        if (pool.state() != REXPrimary.LifecycleState.EpochBased) return;
        amount = bound(amount, 1, MAX_AMOUNT);
        address who = _actor(actorSeed);
        wrwaRoute.deliverTokens(_b32(who), amount);
        vm.startPrank(who);
        IERC20(address(wrwaRoute)).approve(address(pool), amount);
        uint256 id = pool.requestRedeem(amount);
        vm.stopPrank();
        redIds.push(id);
    }

    function cancelSub(uint256 idSeed, uint256 actorSeed, uint256 amount) external {
        (uint256 id, address who, uint256 bal) = _pickHolder(subIds, idSeed, actorSeed);
        if (who == address(0)) return;
        // ADR-027, as in REXPrimaryRedeemHandler: the accruing window is cancellable, and it is the
        // window this invariant cares about -- a cancel that shrank the side but not the batch
        // would let a below-minimum batch bridge on a total nobody still backs.
        (,,, uint64 batchId, bool locked) = pool.epochSide(seqOf(id), CLASS_SUB_EPOCH);
        if (locked) {
            (uint8 bs,,) = pool.subBatch(batchId);
            if (bs != uint8(BatchStatus.Accumulating)) return;
        }
        amount = bound(amount, 1, bal);
        vm.prank(who);
        pool.cancelRequest(id, amount);
    }

    function cancelRedeem(uint256 idSeed, uint256 actorSeed, uint256 amount) external {
        (uint256 id, address who, uint256 bal) = _pickHolder(redIds, idSeed, actorSeed);
        if (who == address(0)) return;
        (,,, uint64 batchId, bool locked) = pool.epochSide(seqOf(id), CLASS_RED_EPOCH);
        if (locked) {
            (uint8 bs,,,) = pool.redeemBatch(batchId);
            if (bs != uint8(BatchStatus.Accumulating)) return;
        }
        amount = bound(amount, 1, bal);
        vm.prank(who);
        pool.cancelRequest(id, amount);
    }

    /// @dev The nav lever this handler adds over the rest of the suite: bounded exactly like the
    /// brief's fuzz-nav tests (`bound(navSeed, 0.1e18, 5e18)`), settable any time. No ghost tracking
    /// is needed any more -- ADR-026 D2 took the price out of both bridge gates, so the invariant
    /// compares each batch against its own unit-matched minimum and this lever is the thing being
    /// PROVED irrelevant rather than the thing being replayed.
    function setNav(uint256 navSeed) external {
        navOracle.setNav(bound(navSeed, MIN_NAV, MAX_NAV));
    }

    function initiate() external {
        if (pool.state() != REXPrimary.LifecycleState.EpochBased) return;
        uint64 epoch = pool.currentEpochId();
        (uint256 subIn,,,,) = pool.epochSide(epoch, CLASS_SUB_EPOCH);
        (uint256 redIn,,,,) = pool.epochSide(epoch, CLASS_RED_EPOCH);
        if (subIn == 0 && redIn == 0) return;

        // ADR-025: the trigger is schedule-gated. Mirrored exactly, like every other gate
        // here, by stepping to the next due moment -- so this action still FIRES instead
        // of turning into a silent TooEarly revert that the fuzzer would discard.
        warpToNextPeriod(pool);
        pool.initiateSubEpoch();
    }
}

/// @notice 2026-09-18, review finding B1 (`docs/planning/sc13-codex-review.md`). Reserve-based
/// solvency is BLIND to a bridge return that has physically landed while its paired instruction is
/// still in flight: it sits in `balanceOf` and in no reserve counter, so the old `recoverStuckBatch`
/// payout of `balance - reserved` took a HEALTHY parallel batch's money to `feeRecipient` without
/// breaking `invariant_usdcSolvent` -- and the victim's instruction then reverted `NotReadyToExecute`
/// forever, its holders claiming zero.
///
/// This campaign exists because the main one cannot reach that state: its `warp` is capped at 6
/// hours against a 10-day `redeemFulfillTimeout`, so a bridge deadline never arrives. Here the
/// timeout is 1 day, `minRedeem` is 0 so every request bridges at once, the recovery action steps
/// the clock to the deadline itself, and it picks a batch that is NOT the one holding landed money
/// -- because "recovering A must not touch B's landed return" is the property, so A != B is what
/// is worth fuzzing. `afterInvariant` asserts that coverage rather than assuming it (cf. the
/// ADR-027 counter-probe above).
contract RecoveryResidualInvariantTest is Test {
    RecoveryResidualHandler handler;

    function setUp() public {
        handler = new RecoveryResidualHandler();
        bytes4[] memory selectors = new bytes4[](11);
        selectors[0] = handler.requestRedeem.selector;
        selectors[1] = handler.initiate.selector;
        selectors[2] = handler.landTokensOnly.selector;
        selectors[3] = handler.deliverReturn.selector;
        selectors[4] = handler.recoverStuck.selector;
        selectors[5] = handler.sweepFreeUsdc.selector;
        // The subscribe leg is the same shape in the other token: its return is wRWA, and
        // `recoverStuckBatch(_, false)` used to pay out `balanceOf(wrwaRoute) - reserved`.
        selectors[6] = handler.requestDeposit.selector;
        selectors[7] = handler.landWrwaTokensOnly.selector;
        selectors[8] = handler.deliverSubReturn.selector;
        selectors[9] = handler.recoverStuckSub.selector;
        selectors[10] = handler.sweepFreeWrwa.selector;
        targetContract(address(handler));
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev The invariant the B1 defect breaks: USDC physically landed for a batch whose
    /// instruction has not processed is owed to that batch, even though no counter says so.
    function invariant_landedButUnrecordedIsNeverTaken() public view {
        REXPrimary r = handler.pool();
        assertGe(
            handler.usdc().balanceOf(address(r)),
            r.heldEscrowUSDC() + r.settledRedeemUSDC() + handler.ghostLandedUnrecorded(),
            "a landed-but-unrecorded return was taken"
        );
    }

    /// @dev The subscribe leg of the same property, in the other token: wRWA physically landed for
    /// a bridged subscribe batch whose `Subscribe` instruction has not processed is owed to that
    /// batch. `recoverStuckBatch(_, false)` paid out `balanceOf(wrwaRoute) - reserved`, so this
    /// fails on the pre-fix contract exactly as its USDC twin does.
    function invariant_landedWrwaIsNeverTaken() public view {
        REXPrimary r = handler.pool();
        assertGe(
            IERC20(address(handler.wrwaRoute())).balanceOf(address(r)),
            r.settledUnclaimed() + r.liveRedeemEscrow() + handler.ghostLandedWrwa(),
            "a landed-but-unrecorded subscribe return was taken"
        );
    }
}

/// @notice Coverage probe for `RecoveryResidualInvariantTest`, measured rather than assumed -- but
/// deterministic, not in `afterInvariant`: that hook runs per RUN against per-run state, so a
/// cumulative coverage assertion there is trivially failable and shrinks to a nonsense 1-call
/// sequence. This drives the handler's own actions in order and proves the campaign's dangerous
/// state -- a recovery running while a DIFFERENT batch holds landed-but-unrecorded money -- is
/// reachable through them at all.
contract RecoveryResidualCoverageTest is Test {
    function test_handler_reaches_recovery_with_another_batchs_landed_money() public {
        RecoveryResidualHandler h = new RecoveryResidualHandler();
        h.requestRedeem(0, 50e6);
        h.initiate();
        (uint8 st1,,,) = h.pool().redeemBatch(1);
        assertEq(st1, uint8(BatchStatus.Bridged), "batch 1 bridged");

        h.landTokensOnly(0, 30e6); // batch 1's USDC lands; its instruction does not
        assertEq(h.landings(), 1, "tokens landed without an instruction");
        assertEq(h.landed(1), 30e6, "landed against batch 1");

        // An even seed makes recovery pick a batch that is NOT batch 1 -- it bootstraps one and
        // terminates that, while batch 1's landed money must stay exactly where it is.
        h.recoverStuck(0);
        assertEq(h.recoveries(), 1, "recovery fired");
        assertEq(h.recoveriesWithForeignLandedMoney(), 1, "and it ran against batch 1's landed money");
        assertEq(h.ghostLandedUnrecorded(), 30e6, "batch 1's money is still owed to batch 1");
        assertEq(h.usdc().balanceOf(address(h.pool())), 30e6, "and still physically there");

        // The other pairing (odd seed): recovery picks the batch holding its OWN landed money,
        // which releases that money from the ghost -- otherwise the release is dead behaviour.
        h.recoverStuck(1);
        assertEq(h.recoveriesOfOwnLandedMoney(), 1, "recovery also runs on a batch's own landing");
        assertEq(h.ghostLandedUnrecorded(), 0, "which releases it from the ghost");
    }

    /// @dev The subscribe leg reaches the same state, in wRWA: a bridged subscribe batch's return
    /// lands, its `Subscribe` instruction does not, and a DIFFERENT dead subscribe batch is
    /// recovered while that money sits there.
    function test_handler_reaches_sub_recovery_with_another_batchs_landed_wrwa() public {
        RecoveryResidualHandler h = new RecoveryResidualHandler();
        h.requestDeposit(0, 100e6);
        h.initiate();
        (uint8 st1,,) = h.pool().subBatch(1);
        assertEq(st1, uint8(BatchStatus.Bridged), "subscribe batch 1 bridged");

        h.landWrwaTokensOnly(0, 40e6); // batch 1's wRWA lands; its instruction does not
        assertEq(h.subLandings(), 1, "wRWA landed without an instruction");
        assertEq(h.landedSub(1), 40e6, "landed against subscribe batch 1");

        uint256 held = IERC20(address(h.wrwaRoute())).balanceOf(address(h.pool()));
        h.recoverStuckSub(0); // even seed -> a batch that is NOT batch 1
        assertEq(h.subRecoveriesWithForeignLandedMoney(), 1, "recovery ran against batch 1's landed wRWA");
        assertEq(h.ghostLandedWrwa(), 40e6, "batch 1's wRWA is still owed to batch 1");
        assertEq(IERC20(address(h.wrwaRoute())).balanceOf(address(h.pool())), held, "and still physically there");
    }
}

/// @notice Stateful handler for `RecoveryResidualInvariantTest`. Narrow on purpose: request,
/// bridge, land tokens without their instruction, deliver the instruction, recover a dead batch,
/// sweep. No claim/cancel/wind-down -- none of them can move a landed-but-unrecorded balance, and
/// every one is already fuzzed by the main campaign.
contract RecoveryResidualHandler is Test {
    uint32 constant PRUV_DOMAIN = 7336;
    uint256 constant MAX_AMOUNT = 200e6;
    uint64 constant REDEEM_FULFILL = 1 days;

    MockMailbox public mailbox;
    MockERC20 public usdc;
    MockCollateralWarpRoute public usdcRoute;
    MockSyntheticWarpRoute public wrwaRoute;
    MockNavOracle public navOracle;
    REXPrimary public pool;
    address public executor = makeAddr("recoveryResidualExecutor");
    address[3] public actors;

    /// @notice USDC landed for a bridged batch whose instruction has not processed yet -- money the
    /// contract itself cannot attribute, and the whole subject of this campaign.
    mapping(uint64 => uint256) public landed;
    uint256 public ghostLandedUnrecorded;
    /// @notice The subscribe leg's twin: wRWA landed for a bridged subscribe batch whose
    /// `Subscribe` instruction has not processed yet.
    mapping(uint64 => uint256) public landedSub;
    /// @dev `subBatch()` exposes `accrualStart`, never `bridgedAt`, so the subscribe leg's deadline
    /// is not readable from the contract (FE handover says the same). The harness stamps it.
    mapping(uint64 => uint64) public subBridgedAt;
    uint256 public ghostLandedWrwa;
    uint256 public landings;
    uint256 public subLandings;
    uint256 public recoveries;
    uint256 public subRecoveries;
    uint256 public subRecoveriesWithForeignLandedMoney;
    /// @notice Recoveries that ran while a DIFFERENT batch was holding landed money -- the exact
    /// state B1 lived in -- and, separately, those where the recovered batch held its own landing.
    uint256 public recoveriesWithForeignLandedMoney;
    uint256 public recoveriesOfOwnLandedMoney;

    receive() external payable {}

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    constructor() {
        mailbox = new MockMailbox(PRUV_DOMAIN);
        mailbox.setQuoteFee(0);
        usdc = new MockERC20("USDC", 6);
        usdcRoute = new MockCollateralWarpRoute(usdc);
        usdcRoute.setGasQuote(0);
        wrwaRoute = new MockSyntheticWarpRoute("wRWA", 6);
        wrwaRoute.setGasQuote(0);
        navOracle = new MockNavOracle(1e18);

        pool = new REXPrimary(
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
            address(0xFEE),
            SC3Params({
                navOracle: INavOracle(address(navOracle)),
                minRedeem: 0, // every request bridges at once -> parallel bridged batches
                redeemCancelFeeBps: 0,
                subFulfillTimeout: REDEEM_FULFILL,
                redemptionFeeBps: 0,
                redeemFulfillTimeout: REDEEM_FULFILL,
                windDownWindow: 9 days,
                schedule: perSecondSchedule()
            })
        );
        pool.enrollRemote(PRUV_DOMAIN, _b32(executor));
        vm.warp(pool.launchpadStart() + pool.launchpadPeriod());
        pool.closeLaunchpad();

        actors[0] = makeAddr("recActor0");
        actors[1] = makeAddr("recActor1");
        actors[2] = makeAddr("recActor2");
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[seed % 3];
    }

    /// @dev Called after every `initiateSubEpoch`: record when each subscribe batch bridged, since
    /// the contract does not expose it.
    function _stampSubBatches() internal {
        uint64 n = pool.nextSubBatchId();
        for (uint64 id = 1; id < n; id++) {
            if (subBridgedAt[id] != 0) continue;
            (uint8 status,,) = pool.subBatch(id);
            if (status == uint8(BatchStatus.Bridged)) subBridgedAt[id] = uint64(vm.getBlockTimestamp());
        }
    }

    /// @dev A Bridged redeem batch whose instruction has not been delivered yet. The seed is
    /// reduced BEFORE it is offset: `seed + k` on a raw uint256 seed overflows for the values the
    /// fuzzer actually hands out (it opens with one near 2^256).
    function _pickOpen(uint256 seed) internal view returns (uint64) {
        return _pick(seed, false);
    }

    /// @dev `_pickOpen`, restricted to a batch with nothing landed for it yet.
    function _pickOpenClean(uint256 seed) internal view returns (uint64) {
        return _pick(seed, true);
    }

    function _pick(uint256 seed, bool cleanOnly) internal view returns (uint64) {
        uint64 n = pool.nextRedeemBatchId();
        if (n <= 1) return 0;
        uint64 span = n - 1;
        uint64 base = uint64(seed % span);
        for (uint64 k = 0; k < span; k++) {
            uint64 id = ((base + k) % span) + 1;
            if (cleanOnly && landed[id] != 0) continue;
            (uint8 status,,,) = pool.redeemBatch(id);
            (,,, bool returnReceived) = pool.batchLeg(id, true);
            if (status == uint8(BatchStatus.Bridged) && !returnReceived) return id;
        }
        return 0;
    }

    /// @dev Request + bridge a batch, so an action that needs one is never wasted on an empty
    /// book. Without it, reachability depends on the fuzzer's ordering and a run that opens with
    /// the wrong selector explores nothing (measured: zero landings).
    function _bootstrapBridged(uint256 seed, uint256 amount) internal returns (uint64) {
        if (pool.state() != REXPrimary.LifecycleState.EpochBased) return 0;
        uint256 amt = bound(amount, 1, MAX_AMOUNT);
        address who = _actor(seed);
        wrwaRoute.deliverTokens(_b32(who), amt);
        vm.startPrank(who);
        IERC20(address(wrwaRoute)).approve(address(pool), amt);
        pool.requestRedeem(amt);
        vm.stopPrank();
        warpToNextPeriod(pool);
        pool.initiateSubEpoch(); // minRedeem 0 -> bridges in-tx
        _stampSubBatches();
        return pool.nextRedeemBatchId() - 1;
    }

    function requestRedeem(uint256 actorSeed, uint256 amount) external {
        if (pool.state() != REXPrimary.LifecycleState.EpochBased) return;
        amount = bound(amount, 1, MAX_AMOUNT);
        address who = _actor(actorSeed);
        wrwaRoute.deliverTokens(_b32(who), amount);
        vm.startPrank(who);
        IERC20(address(wrwaRoute)).approve(address(pool), amount);
        pool.requestRedeem(amount);
        vm.stopPrank();
    }

    function initiate() external {
        if (pool.state() != REXPrimary.LifecycleState.EpochBased) return;
        (uint256 redIn,,,,) = pool.epochSide(pool.currentEpochId(), CLASS_RED_EPOCH);
        (uint256 subIn,,,,) = pool.epochSide(pool.currentEpochId(), CLASS_SUB_EPOCH);
        if (redIn == 0 && subIn == 0) return;
        warpToNextPeriod(pool);
        pool.initiateSubEpoch();
        _stampSubBatches();
    }

    /// @dev The B1 window: the token leg arrives, its instruction does not.
    function landTokensOnly(uint256 batchSeed, uint256 amount) external {
        uint64 batchId = _pickOpen(batchSeed);
        if (batchId == 0) batchId = _bootstrapBridged(batchSeed, amount);
        if (batchId == 0) return;
        amount = bound(amount, 1, MAX_AMOUNT);
        usdc.mint(address(usdcRoute), amount);
        usdcRoute.deliverTokens(_b32(address(pool)), amount);
        landed[batchId] += amount;
        ghostLandedUnrecorded += amount;
        landings++;
    }

    /// @dev The instruction finally lands, for exactly what was landed for it, so the rendezvous
    /// can complete. A batch with nothing landed is skipped -- minting extra here would paper over
    /// the very gap this campaign is about.
    function deliverReturn(uint256 batchSeed) external {
        uint64 batchId = _pickOpen(batchSeed);
        if (batchId == 0 || landed[batchId] == 0) return;
        uint256 amount = landed[batchId];
        bytes memory body =
            Codec.encode(Instruction({legId: batchId, kind: RequestKind.Redeem, amount: amount, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        pool.handle(PRUV_DOMAIN, _b32(executor), body);
        ghostLandedUnrecorded -= amount;
        landed[batchId] = 0;
    }

    /// @dev M-1 recovery of a dead bridged batch, stepped to its own deadline so it actually
    /// fires, and biased onto a batch that is NOT the one holding landed money. Once terminated, a
    /// batch's OWN landed money is genuinely unowned, so the ghost releases it here; what the
    /// invariant still protects is every other batch's.
    function recoverStuck(uint256 batchSeed) external {
        // Even seeds pick a batch that is NOT the one holding landed money, because "recovering A
        // must not touch B's landed return" is the property and A != B is the case worth fuzzing --
        // picking the landed batch itself (which `_pickOpen` does, since it is open) made the
        // dangerous pairing never occur, measured as zero rather than assumed. Odd seeds keep the
        // other pairing, so the ghost release below is exercised instead of being dead behaviour.
        uint64 batchId = batchSeed % 2 == 0 ? _pickOpenClean(batchSeed) : _pickOpen(batchSeed);
        if (batchId == 0) batchId = _pickOpenClean(batchSeed);
        if (batchId == 0) batchId = _bootstrapBridged(batchSeed, batchSeed);
        if (batchId == 0) return;
        (,,, uint64 deadline) = pool.redeemBatch(batchId);
        if (deadline == 0) return;
        if (vm.getBlockTimestamp() < deadline) vm.warp(deadline);
        uint256 own = landed[batchId];
        uint256 foreign = ghostLandedUnrecorded - own;
        pool.recoverStuckBatch(batchId, true);
        ghostLandedUnrecorded -= own; // the recovered batch's own landing is now unowned
        landed[batchId] = 0;
        recoveries++;
        if (foreign > 0) recoveriesWithForeignLandedMoney++;
        if (own > 0) recoveriesOfOwnLandedMoney++;
    }

    // ----------------------------------------------------------------------------------------
    // subscribe leg -- the same five actions in the other token (its return is wRWA)
    // ----------------------------------------------------------------------------------------

    /// @dev A Bridged subscribe batch whose `Subscribe` return has not been delivered yet;
    /// `cleanOnly` excludes one that already has wRWA landed for it.
    function _pickSub(uint256 seed, bool cleanOnly) internal view returns (uint64) {
        uint64 n = pool.nextSubBatchId();
        if (n <= 1) return 0;
        uint64 span = n - 1;
        uint64 base = uint64(seed % span);
        for (uint64 k = 0; k < span; k++) {
            uint64 id = ((base + k) % span) + 1;
            if (cleanOnly && landedSub[id] != 0) continue;
            (uint8 status,,) = pool.subBatch(id);
            (,,, bool returnReceived) = pool.batchLeg(id, false);
            if (status == uint8(BatchStatus.Bridged) && !returnReceived) return id;
        }
        return 0;
    }

    /// @dev Twin of `_bootstrapBridged` for the subscribe leg (`minSub` is 0, so it bridges in-tx).
    function _bootstrapBridgedSub(uint256 seed, uint256 amount) internal returns (uint64) {
        if (pool.state() != REXPrimary.LifecycleState.EpochBased) return 0;
        uint256 amt = bound(amount, 1, MAX_AMOUNT);
        address who = _actor(seed);
        usdc.mint(who, amt);
        vm.startPrank(who);
        usdc.approve(address(pool), amt);
        pool.requestDeposit(amt);
        vm.stopPrank();
        warpToNextPeriod(pool);
        pool.initiateSubEpoch();
        _stampSubBatches();
        return pool.nextSubBatchId() - 1;
    }

    function requestDeposit(uint256 actorSeed, uint256 amount) external {
        if (pool.state() != REXPrimary.LifecycleState.EpochBased) return;
        amount = bound(amount, 1, MAX_AMOUNT);
        address who = _actor(actorSeed);
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(pool), amount);
        pool.requestDeposit(amount);
        vm.stopPrank();
    }

    /// @dev The B1 window on the subscribe leg: the wRWA arrives, its instruction does not.
    function landWrwaTokensOnly(uint256 batchSeed, uint256 amount) external {
        uint64 batchId = _pickSub(batchSeed, false);
        if (batchId == 0) batchId = _bootstrapBridgedSub(batchSeed, amount);
        if (batchId == 0) return;
        amount = bound(amount, 1, MAX_AMOUNT);
        wrwaRoute.deliverTokens(_b32(address(pool)), amount);
        landedSub[batchId] += amount;
        ghostLandedWrwa += amount;
        subLandings++;
    }

    function deliverSubReturn(uint256 batchSeed) external {
        uint64 batchId = _pickSub(batchSeed, false);
        if (batchId == 0 || landedSub[batchId] == 0) return;
        uint256 amount = landedSub[batchId];
        bytes memory body = Codec.encode(
            Instruction({legId: batchId, kind: RequestKind.Subscribe, amount: amount, navAtInitiate: 1e18})
        );
        vm.prank(address(mailbox));
        pool.handle(PRUV_DOMAIN, _b32(executor), body);
        ghostLandedWrwa -= amount;
        landedSub[batchId] = 0;
    }

    function recoverStuckSub(uint256 batchSeed) external {
        uint64 batchId = batchSeed % 2 == 0 ? _pickSub(batchSeed, true) : _pickSub(batchSeed, false);
        if (batchId == 0) batchId = _pickSub(batchSeed, true);
        if (batchId == 0) batchId = _bootstrapBridgedSub(batchSeed, batchSeed);
        if (batchId == 0) return;
        uint64 bridgedAt = subBridgedAt[batchId];
        if (bridgedAt == 0) return;
        uint64 deadline = bridgedAt + uint64(pool.subFulfillTimeout());
        if (vm.getBlockTimestamp() < deadline) vm.warp(deadline);
        uint256 own = landedSub[batchId];
        uint256 foreign = ghostLandedWrwa - own;
        pool.recoverStuckBatch(batchId, false);
        ghostLandedWrwa -= own;
        landedSub[batchId] = 0;
        subRecoveries++;
        if (foreign > 0) subRecoveriesWithForeignLandedMoney++;
    }

    /// @dev wRWA twin of `sweepFreeUsdc`.
    function sweepFreeWrwa(uint256 amount) external {
        if (pool.outstandingSubBatches() != 0 || pool.outstandingRedeemBatches() != 0) return;
        uint256 reserved = pool.settledUnclaimed() + pool.liveRedeemEscrow();
        uint256 bal = IERC20(address(wrwaRoute)).balanceOf(address(pool));
        if (bal <= reserved) return;
        amount = bound(amount, 1, bal - reserved);
        pool.sweep(address(wrwaRoute), pool.feeRecipient(), amount);
    }

    /// @dev Bounded exactly as `sweep` computes `free`, so a break can only come from the contract
    /// mis-judging what is free -- never from this harness asking it to over-sweep.
    function sweepFreeUsdc(uint256 amount) external {
        if (pool.outstandingSubBatches() != 0 || pool.outstandingRedeemBatches() != 0) return;
        uint256 reserved = pool.heldEscrowUSDC() + pool.settledRedeemUSDC();
        uint256 bal = usdc.balanceOf(address(pool));
        if (bal <= reserved) return;
        amount = bound(amount, 1, bal - reserved);
        pool.sweep(address(usdc), pool.feeRecipient(), amount);
    }
}
