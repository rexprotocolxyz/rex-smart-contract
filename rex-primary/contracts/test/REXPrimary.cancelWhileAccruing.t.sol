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
import {warpToNextPeriod, warpBy} from "./helpers/TestSchedule.sol";
import "@rex-shared/Wire.sol";

/// @notice ADR-027. A holder may cancel for as long as their batch is still `Accumulating`, on
/// BOTH legs, and the cancel shrinks the BATCH as well as the side.
///
/// The lock this replaces was ADR-015's, and ADR-015 rejected exactly this design for one reason:
/// cancelling would shrink `totalIn` against a fixed `matchedOut`. ADR-024 deleted `matchedOut`,
/// so the shrink is now symmetric and the §14 pro-rata invariant survives it.
///
/// MUTATION REQUIREMENT (inherited from `REXPrimary.lockOnConsume.t.sol`, re-pointed): deleting
/// `b.netIn -= amount` from `cancelRequest` MUST make `test_cancelCannotReachAnotherEpochsEscrow`
/// fail. The hazard was never cancellation — it is a batch counter drifting away from the escrow
/// that physically backs it. Verify by hand; a green suite is not the deliverable.
contract REXPrimaryCancelWhileAccruingTest is Test {
    MockMailbox mailbox;
    MockERC20 usdc;
    MockCollateralWarpRoute usdcRoute;
    MockSyntheticWarpRoute wrwaRoute;
    MockNavOracle navOracle;
    REXPrimary rex;
    EpochSchedule schedule;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address executor = makeAddr("executor");
    uint32 constant PRUV_DOMAIN = 7336;
    uint64 constant EPOCH_DURATION = 1 hours;
    /// Both minimums sit far above every amount below, so neither leg's batch ever bridges here:
    /// these suites test the accruing window, which is the only window the rule applies to.
    uint256 constant MIN_SUB = 1_000e6;
    uint256 constant MIN_REDEEM_WRWA = 1_000e6;

    function setUp() public {
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
            MIN_SUB,
            lpStart,
            lpPeriod,
            MIN_SUB, // launchpadMinimum >= minSub (ctor guard)
            0,
            address(0xFEE),
            SC3Params({
                navOracle: INavOracle(address(navOracle)),
                minRedeem: MIN_REDEEM_WRWA,
                redeemCancelFeeBps: 0,
                redemptionFeeBps: 0,
                redeemFulfillTimeout: 10 days,
                subFulfillTimeout: 10 days,
                windDownWindow: 9 days,
                schedule: IEpochSchedule(address(schedule))
            })
        );
        rex.enrollRemote(PRUV_DOMAIN, _b32(executor));
        usdcRoute.setGasQuote(0);
        wrwaRoute.setGasQuote(0);

        // `minSub > 0` forces `launchpadMinimum >= minSub`, so reaching EpochBased needs a REAL
        // raise rather than a vacuous close. That raise bridges and settles as batch 1, which is
        // why every subscribe batch below is batch 2. The redeem leg has its own id space.
        address seeder = makeAddr("seeder");
        usdc.mint(seeder, MIN_SUB);
        vm.warp(rex.launchpadStart());
        vm.startPrank(seeder);
        usdc.approve(address(rex), MIN_SUB);
        rex.depositToLaunchpad(MIN_SUB);
        vm.stopPrank();
        vm.warp(rex.launchpadStart() + rex.launchpadPeriod());
        vm.deal(address(this), 1 ether);
        rex.closeLaunchpad{value: 1e15}();
        wrwaRoute.deliverTokens(_b32(address(rex)), MIN_SUB);
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Subscribe, amount: MIN_SUB, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
        rex.settleSubBatch(1);
    }

    receive() external payable {} // the launchpad bridge refunds unspent native

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 id) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(rex), amount);
        id = rex.requestDeposit(amount);
        vm.stopPrank();
    }

    function _requestRedeem(address who, uint256 amount) internal returns (uint256 id) {
        wrwaRoute.deliverTokens(bytes32(uint256(uint160(who))), amount);
        vm.startPrank(who);
        IERC20(address(wrwaRoute)).approve(address(rex), amount);
        id = rex.requestRedeem(amount);
        vm.stopPrank();
    }

    function _initiate() internal {
        warpToNextPeriod(rex);
        rex.initiateSubEpoch();
    }

    /// @dev A second pool with a non-zero cancel fee. Its own deployment because `cancelFeeBps` is
    /// a constructor immutable and the shared fixture deliberately runs at 0.
    function _feePool(uint16 cancelFeeBps) internal returns (REXPrimary r) {
        EpochSchedule sch =
            new EpochSchedule(uint64(block.timestamp + 1) + 1 days + EPOCH_DURATION, EPOCH_DURATION, EPOCH_DURATION);
        r = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            MIN_SUB,
            uint64(block.timestamp + 1),
            1 days,
            MIN_SUB,
            cancelFeeBps,
            address(0xFEE2),
            SC3Params({
                navOracle: INavOracle(address(navOracle)),
                minRedeem: MIN_REDEEM_WRWA,
                redeemCancelFeeBps: 0,
                redemptionFeeBps: 0,
                redeemFulfillTimeout: 10 days,
                subFulfillTimeout: 10 days,
                windDownWindow: 9 days,
                schedule: IEpochSchedule(address(sch))
            })
        );
        r.enrollRemote(PRUV_DOMAIN, _b32(executor));

        address seeder = makeAddr("feeSeeder");
        usdc.mint(seeder, MIN_SUB);
        vm.warp(r.launchpadStart());
        vm.startPrank(seeder);
        usdc.approve(address(r), MIN_SUB);
        r.depositToLaunchpad(MIN_SUB);
        vm.stopPrank();
        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad{value: 1e15}();
        wrwaRoute.deliverTokens(_b32(address(r)), MIN_SUB);
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Subscribe, amount: MIN_SUB, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        r.handle(PRUV_DOMAIN, _b32(executor), body);
        r.settleSubBatch(1);
    }

    function _depositTo(REXPrimary r, address who, uint256 amount) internal returns (uint256 id) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(r), amount);
        id = r.requestDeposit(amount);
        vm.stopPrank();
    }

    // --- subscribe leg -------------------------------------------------------------------

    function test_subscriberCancelsWhileTheBatchAccrues() public {
        uint256 id = _deposit(alice, 100e6);
        _initiate(); // locks the side; 100 < MIN_SUB so the batch accrues instead of bridging

        vm.prank(alice);
        rex.cancelRequest(id, 100e6);

        assertEq(usdc.balanceOf(alice), 100e6, "alice was not made whole");
        assertEq(rex.balanceOf(alice, id), 0, "receipt not burned");
    }

    function test_cancelShrinksTheBatchNotOnlyTheSide() public {
        uint256 id = _deposit(alice, 100e6);
        _initiate();
        (, uint256 netInBefore,) = rex.subBatch(2);
        assertEq(netInBefore, 100e6, "fixture wrong: the batch did not accrue");

        vm.prank(alice);
        rex.cancelRequest(id, 40e6);

        (, uint256 netInAfter,) = rex.subBatch(2);
        assertEq(netInAfter, 60e6, "the batch still claims escrow that has left");
        assertEq(rex.heldEscrowUSDC(), 60e6, "escrow and batch disagree");
    }

    function test_cancelIsRefusedOnceTheBatchHasBridged() public {
        uint256 id = _deposit(alice, MIN_SUB);
        warpToNextPeriod(rex);
        rex.initiateSubEpoch{value: 1e15}(); // at the minimum -> bridges in-tx, escrow leaves

        vm.prank(alice);
        vm.expectRevert(EpochLocked.selector);
        rex.cancelRequest(id, MIN_SUB);
    }

    function test_aBelowMinimumBatchKeepsAccruingPastTheOldCap() public {
        _deposit(alice, 100e6);
        _initiate();

        warpBy(60 days); // far past the 30-day cap this deployment used to enforce
        _deposit(bob, 100e6);
        _initiate();

        (uint8 status, uint256 netIn,) = rex.subBatch(2);
        assertEq(status, uint8(BatchStatus.Accumulating), "the batch expired on a clock nobody asked for");
        assertEq(netIn, 200e6, "the second epoch did not accrue into the same batch");
    }

    // --- redeem leg ----------------------------------------------------------------------

    function test_redeemerCancelsWhileTheBatchAccrues() public {
        uint256 id = _requestRedeem(alice, 100e6);
        _initiate();

        vm.prank(alice);
        rex.cancelRequest(id, 100e6);

        assertEq(IERC20(address(wrwaRoute)).balanceOf(alice), 100e6, "alice was not made whole");
        assertEq(rex.liveRedeemEscrow(), 0, "escrow not released");
    }

    /// @notice The hazard `lockOnConsume` was written to prevent, with the fix in place instead of
    /// the lock. Alice's 100 is folded into the open batch in epoch 1; Bob then redeems into epoch
    /// 2, and HIS escrow is what would physically back Alice's share if the batch counter did not
    /// shrink with her cancel. She must take her own 100 and nothing of his.
    function test_cancelCannotReachAnotherEpochsEscrow() public {
        uint256 aliceId = _requestRedeem(alice, 100e6);
        _initiate();
        uint256 bobId = _requestRedeem(bob, 100e6); // epoch 2, not yet consumed
        assertEq(rex.liveRedeemEscrow(), 200e6, "fixture wrong: both escrows should be held");

        vm.prank(alice);
        rex.cancelRequest(aliceId, 100e6);

        assertEq(IERC20(address(wrwaRoute)).balanceOf(alice), 100e6, "alice took the wrong amount");
        (, uint256 netIn,,) = rex.redeemBatch(1);
        assertEq(netIn, 0, "the batch still claims escrow Alice has taken back");
        assertEq(rex.liveRedeemEscrow(), 100e6, "what is left must be exactly Bob's");

        // And Bob's own exit is untouched by any of it.
        vm.prank(bob);
        rex.cancelRequest(bobId, 100e6);
        assertEq(IERC20(address(wrwaRoute)).balanceOf(bob), 100e6, "bob could not exit");
    }

    /// @dev The ADR's central claim, on the leg it is hardest to see: a cancel must leave every
    /// OTHER holder's fraction exactly as it was. Two holders in one epoch, one leaves, and the
    /// one who stayed must still be owed all of their own deposit and nothing of hers.
    function test_cancelLeavesTheOtherHoldersShareUntouched() public {
        uint256 aliceId = _deposit(alice, 100e6);
        uint256 bobId = _deposit(bob, 100e6);
        _initiate();
        (, uint256 netIn,) = rex.subBatch(2);
        assertEq(netIn, 200e6);

        vm.prank(alice);
        rex.cancelRequest(aliceId, 100e6);
        (, uint256 netInAfter,) = rex.subBatch(2);
        assertEq(netInAfter, 100e6, "the batch kept alice's share after she left");

        // Wind-down releases the batch; bob's deferred claim must pay his full 100, not a diluted
        // or inflated slice of a denominator alice already walked away from.
        rex.triggerWindDown();
        vm.prank(bob);
        rex.claim(bobId, 100e6);
        assertEq(usdc.balanceOf(bob), 100e6, "bob's share moved when alice left");
        assertEq(rex.heldEscrowUSDC(), 0, "escrow fully unwound");
    }

    /// @dev A batch spanning two epochs is where a stale counter does its damage: epoch 1's holder
    /// leaves, and epoch 2's holder -- whose escrow is what physically backs the accrued total --
    /// must be unaffected. The subscribe mirror of lockOnConsume's Alice/Bob case.
    function test_cancelInOneEpochCannotReachTheNextEpochsEscrow() public {
        uint256 aliceId = _deposit(alice, 100e6);
        _initiate(); // epoch 1 -> batch 2 (100e6)
        uint256 bobId = _deposit(bob, 100e6);
        _initiate(); // epoch 2 -> the SAME batch (200e6)
        (, uint256 netIn,) = rex.subBatch(2);
        assertEq(netIn, 200e6, "fixture: one batch, two epochs");

        vm.prank(alice);
        rex.cancelRequest(aliceId, 100e6);

        assertEq(usdc.balanceOf(alice), 100e6, "alice took the wrong amount");
        (, uint256 netInAfter,) = rex.subBatch(2);
        assertEq(netInAfter, 100e6, "the batch would bridge against bob's escrow");
        assertEq(rex.heldEscrowUSDC(), 100e6, "what remains must be exactly bob's");

        // Bob's own epoch is untouched and still exits in full.
        vm.prank(bob);
        rex.cancelRequest(bobId, 100e6);
        assertEq(usdc.balanceOf(bob), 100e6, "bob could not exit");
        assertEq(rex.heldEscrowUSDC(), 0);
    }

    /// @dev With a cancel fee, escrow leaves GROSS while the holder receives NET. The batch must
    /// shrink by the gross too -- shrinking by the net would leave the batch claiming the fee,
    /// which is already on its way to the fee recipient.
    function test_cancelWithAFeeShrinksTheBatchByTheGross() public {
        REXPrimary r = _feePool(100); // 1%
        uint256 id = _depositTo(r, alice, 100e6);
        warpToNextPeriod(r);
        r.initiateSubEpoch();

        vm.prank(alice);
        r.cancelRequest(id, 100e6);

        assertEq(usdc.balanceOf(alice), 99e6, "net to the holder");
        assertEq(usdc.balanceOf(address(0xFEE2)), 1e6, "fee to the recipient");
        (, uint256 netIn,) = r.subBatch(2);
        assertEq(netIn, 0, "the batch must shrink by the gross, not the net");
        assertEq(r.heldEscrowUSDC(), 0, "escrow and batch agree at zero");
    }

    /// @dev A premise ADR-027 quietly falsified. `_requireClaimable` reads `netAmount == 0` as "this
    /// side has no batch", and lets such a side through WITHOUT checking its batch's status. That
    /// was safe while the branch was unreachable -- `locked` implied `netAmount > 0`, because the
    /// side's net was set to the whole side at initiate and nothing could reduce it. Cancelling
    /// during accrual reduces it, so a locked side with a LIVE batch can now read zero and walk
    /// past a gate that exists to stop exactly that.
    ///
    /// Today nothing can be stolen through it: `netAmount` and `totalIn` move together, so zero net
    /// means zero receipts and there is no one left to claim. The hole is that the guard's reason
    /// for being open no longer holds, and the next thing that separates those two numbers inherits
    /// an open gate. The claim must be refused by the state machine, not by arithmetic.
    function test_aFullyCancelledSideIsRefusedByTheGateNotByArithmetic() public {
        uint256 id = _deposit(alice, 100e6);
        _initiate();
        vm.prank(alice);
        rex.cancelRequest(id, 100e6); // side is now locked, batch live, netAmount 0

        vm.prank(alice);
        vm.expectRevert(NotSettled.selector);
        rex.claim(id, 1);
    }

    /// @dev ADR-027 argued that the accrual caps' only structural job was keeping
    /// `triggerShutDown` reachable, and that wind-down covers it. That missed a second consumer of
    /// the same counters: `sweep` gates on `outstanding*Batches() == 0` too. With the caps and the
    /// drain gone, an `Accumulating` batch has no terminal transition outside wind-down — so a
    /// batch whose holders ALL left would sit outstanding for the pool's operating life and hold
    /// the owner's mis-sent-token backstop shut behind it.
    ///
    /// An emptied batch is the one case where releasing cannot hurt anybody: there is no holder
    /// left to strand, which is exactly why it is safe to do automatically.
    function test_cancellingABatchToEmptyTerminatesIt() public {
        uint256 id = _deposit(alice, 100e6);
        _initiate();
        assertEq(rex.outstandingSubBatches(), 1, "batch 2 open (batch 1 is the settled raise)");

        vm.prank(alice);
        rex.cancelRequest(id, 100e6);

        (uint8 status, uint256 netIn,) = rex.subBatch(2);
        assertEq(netIn, 0);
        assertEq(status, uint8(BatchStatus.Released), "an emptied batch must not stay outstanding");
        assertEq(rex.openSubBatchId(), 0, "the open slot must be freed for the next epoch");
        assertEq(rex.outstandingSubBatches(), 0, "sweep and shut-down are reachable again");
    }

    /// @dev The same on the redeem leg, whose batch space is separate.
    function test_cancellingARedeemBatchToEmptyTerminatesIt() public {
        uint256 id = _requestRedeem(alice, 100e6);
        _initiate();
        assertEq(rex.outstandingRedeemBatches(), 1);

        vm.prank(alice);
        rex.cancelRequest(id, 100e6);

        (uint8 status,,,) = rex.redeemBatch(1);
        assertEq(status, uint8(BatchStatus.Released));
        assertEq(rex.openRedeemBatchId(), 0);
        assertEq(rex.outstandingRedeemBatches(), 0);
    }

    /// @dev ...and a partly-emptied batch keeps accruing, because its remaining holders have not
    /// left and releasing would end a position they did not ask to end.
    function test_aPartlyCancelledBatchKeepsAccruing() public {
        uint256 aliceId = _deposit(alice, 100e6);
        _deposit(bob, 100e6);
        _initiate();

        vm.prank(alice);
        rex.cancelRequest(aliceId, 100e6);

        (uint8 status, uint256 netIn,) = rex.subBatch(2);
        assertEq(netIn, 100e6);
        assertEq(status, uint8(BatchStatus.Accumulating), "bob is still in it");
        assertEq(rex.openSubBatchId(), 2);
    }

    /// @dev M10. A `Released` batch's exit is the deferred claim, which refunds in full and charges
    /// no fee; cancelling would be a second door to the same money at a DIFFERENT price
    /// (`cancelFeeBps`). Nothing asserted that the gate refuses it, so widening the gate to admit
    /// `Released` went unnoticed by the whole suite.
    function test_cancelIsRefusedOnAReleasedBatch() public {
        uint256 id = _deposit(alice, 100e6);
        _deposit(bob, 100e6); // a second holder, so the cancel below cannot empty the batch
        _initiate();
        rex.triggerWindDown(); // releases the open subscribe batch at entry

        (uint8 status,,) = rex.subBatch(2);
        assertEq(status, uint8(BatchStatus.Released), "fixture: the batch must be Released");

        vm.prank(alice);
        vm.expectRevert(EpochLocked.selector);
        rex.cancelRequest(id, 100e6);
    }

    /// @dev M5. The constructor must refuse a zero `subFulfillTimeout` itself. With zero, every
    /// bridged subscribe batch is instantly `recoverStuckBatch`-able -- which sets it `Settled`
    /// with `returnedAmount` 0 and zeroes every subscriber's claim irreversibly. The deploy script
    /// guards it, but a live deploy by raw `cast` bypasses the script entirely.
    function test_constructorRefusesAZeroSubFulfillTimeout() public {
        EpochSchedule sch =
            new EpochSchedule(uint64(block.timestamp + 1) + 1 days + EPOCH_DURATION, EPOCH_DURATION, EPOCH_DURATION);
        vm.expectRevert(InvalidLaunchpadConfig.selector);
        new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            MIN_SUB,
            uint64(block.timestamp + 1),
            1 days,
            MIN_SUB,
            0,
            address(0xFEE),
            SC3Params({
                navOracle: INavOracle(address(navOracle)),
                minRedeem: MIN_REDEEM_WRWA,
                redeemCancelFeeBps: 0,
                redemptionFeeBps: 0,
                redeemFulfillTimeout: 10 days,
                subFulfillTimeout: 0,
                windDownWindow: 9 days,
                schedule: IEpochSchedule(address(sch))
            })
        );
    }

    // --- the cases ADR-027 made reachable for the first time ---------------------------------

    /// @dev G3. Receipts are transferable (ADR-013): ownership IS the balance, and `cancelRequest`
    /// authorises by balance, never by who deposited. Before ADR-027 that never met a consumed
    /// side, because a consumed side could not be cancelled at all. Now a secondary-market buyer
    /// can pull escrow out mid-accrual — and the aggregates that shrink are the SELLER's epoch
    /// side, which is the only place the amount is recorded.
    function test_aSecondaryBuyerCanCancelWhatTheyBought() public {
        uint256 id = _deposit(alice, 100e6);
        _initiate();

        address carol = makeAddr("carol");
        vm.prank(alice);
        rex.safeTransferFrom(alice, carol, id, 100e6, "");

        vm.prank(carol);
        rex.cancelRequest(id, 100e6);

        assertEq(usdc.balanceOf(carol), 100e6, "the holder of the receipt is the one paid");
        assertEq(usdc.balanceOf(alice), 0, "the original depositor is owed nothing");
        assertEq(rex.heldEscrowUSDC(), 0);
    }

    /// @dev The dangerous half of G3: one position split between two holders, both leaving. The
    /// second cancel must not underflow `netIn`/`netAmount`, which it would if either had been
    /// decremented by anything other than the exact amount burned.
    function test_twoHoldersOfOnePositionCanBothLeave() public {
        uint256 id = _deposit(alice, 100e6);
        _initiate();

        address carol = makeAddr("carol");
        vm.prank(alice);
        rex.safeTransferFrom(alice, carol, id, 40e6, "");

        vm.prank(carol);
        rex.cancelRequest(id, 40e6);
        (, uint256 mid,) = rex.subBatch(2);
        assertEq(mid, 60e6);

        vm.prank(alice);
        rex.cancelRequest(id, 60e6);

        assertEq(usdc.balanceOf(carol), 40e6);
        assertEq(usdc.balanceOf(alice), 60e6);
        assertEq(rex.heldEscrowUSDC(), 0, "escrow fully unwound by two partial exits");
    }

    /// @dev G6. The release-on-empty is only idempotent because the NEXT accrual opens a fresh
    /// batch rather than reviving the released one — asserted here rather than left in a comment.
    function test_anEmptiedBatchIsSucceededByAFreshOne() public {
        uint256 id = _deposit(alice, 100e6);
        _initiate();
        vm.prank(alice);
        rex.cancelRequest(id, 100e6); // batch 2 released at netIn 0

        _deposit(bob, 50e6);
        _initiate();

        assertEq(rex.openSubBatchId(), 3, "a released batch must not be revived");
        (uint8 s3, uint256 n3,) = rex.subBatch(3);
        assertEq(s3, uint8(BatchStatus.Accumulating));
        assertEq(n3, 50e6);
        (uint8 s2, uint256 n2,) = rex.subBatch(2);
        assertEq(s2, uint8(BatchStatus.Released), "the old batch stays terminal");
        assertEq(n2, 0);
    }

    /// @dev G7. Two epochs cannot show a per-epoch `netAmount` drifting from the shared
    /// `b.netIn`; three can, because the middle epoch's cancel has neighbours on both sides.
    function test_aThreeEpochBatchSurvivesACancelInTheMiddleEpoch() public {
        _deposit(alice, 100e6);
        _initiate(); // epoch 1 -> batch 2
        uint256 bobId = _deposit(bob, 100e6);
        _initiate(); // epoch 2 -> same batch
        address carol = makeAddr("carol");
        uint256 carolId = _depositTo(rex, carol, 100e6);
        _initiate(); // epoch 3 -> same batch, 300e6

        (, uint256 before,) = rex.subBatch(2);
        assertEq(before, 300e6);

        vm.prank(bob);
        rex.cancelRequest(bobId, 100e6); // the MIDDLE epoch leaves

        (, uint256 after_,) = rex.subBatch(2);
        assertEq(after_, 200e6);
        assertEq(rex.heldEscrowUSDC(), 200e6, "escrow and batch agree with a hole in the middle");

        // Alice's and Carol's epochs are untouched and still exit in full.
        vm.prank(carol);
        rex.cancelRequest(carolId, 100e6);
        assertEq(usdc.balanceOf(carol), 100e6);
        (, uint256 last,) = rex.subBatch(2);
        assertEq(last, 100e6, "only alice's epoch is left");
    }

    /// @dev G8, and the last arithmetic ADR-027 leaves unasserted. Every other test here checks the
    /// symmetry on a batch that never bridged, where the refund is `netAmount / totalIn` and the
    /// two terms are equal by construction. On a batch that DOES bridge, the epoch's slice is
    /// `mulDiv(netAmount, returnedAmount, b.netIn)` — a second division, against a denominator the
    /// cancel moved. If the decrement were off, the surviving epochs would silently split a pot
    /// sized for a batch that no longer exists.
    ///
    /// An uneven return forces a real floor split rather than a vacuous one.
    function test_aCancelBeforeBridgingDoesNotDistortTheSettledSplit() public {
        uint256 aliceId = _deposit(alice, 600e6);
        _initiate(); // epoch 1 -> batch 2 at 600e6, below MIN_SUB
        vm.prank(alice);
        rex.cancelRequest(aliceId, 100e6); // 500e6 left, and the batch is 500e6

        uint256 bobId = _deposit(bob, 600e6);
        warpToNextPeriod(rex);
        rex.initiateSubEpoch{value: 1e15}(); // 500 + 600 = 1100e6 >= MIN_SUB -> bridges

        (uint8 status, uint256 netIn,) = rex.subBatch(2);
        assertEq(status, uint8(BatchStatus.Bridged));
        assertEq(netIn, 1_100e6, "the batch bridged what is actually backed, not what accrued");
        assertEq(rex.heldEscrowUSDC(), 0, "escrow left for exactly the bridged amount");

        // An uplifted, uneven return: 1,111 wRWA against 1,100 USDC bridged.
        uint256 returned = 1_111e6;
        wrwaRoute.deliverTokens(_b32(address(rex)), returned);
        bytes memory body =
            Codec.encode(Instruction({legId: 2, kind: RequestKind.Subscribe, amount: returned, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
        rex.settleSubBatch(2);

        vm.prank(alice);
        rex.claim(aliceId, 500e6);
        vm.prank(bob);
        rex.claim(bobId, 600e6);

        uint256 aliceGot = IERC20(address(wrwaRoute)).balanceOf(alice);
        uint256 bobGot = IERC20(address(wrwaRoute)).balanceOf(bob);
        // Each epoch takes its own share of the pot, in the proportion that SURVIVED the cancel.
        assertEq(aliceGot, Math.mulDiv(500e6, returned, 1_100e6), "alice's slice ignored her cancel");
        assertEq(bobGot, Math.mulDiv(600e6, returned, 1_100e6), "bob was diluted by a cancel not his");
        assertLe(aliceGot + bobGot, returned, "the two slices over-drew the pot");
        assertGe(aliceGot + bobGot + 2, returned, "more than floor-division dust went missing");
    }
}
