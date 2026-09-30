// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {Codec} from "@rex-shared/Codec.sol";
import "../src/REXPrimary.sol";
import {REXLens} from "../src/REXLens.sol";
import "@rex-shared/Receipt.sol";
import "@rex-shared/IHyperlane.sol";
import "./mocks/MockERC20.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import "@rex-shared-mocks/MockNavOracle.sol";
import "@rex-shared/INavOracle.sol";
import {perSecondSchedule, warpToNextPeriod} from "./helpers/TestSchedule.sol";

/// @notice A NAV oracle that ALWAYS reverts `StalePrice` (ADR-026 D2). The repo's `MockNavOracle`
/// cannot express this -- staleness lives in `NavOracleConsumer`, not in the mock -- so a pool wired
/// to this stub is the only way to prove `initiateSubEpoch` performs no NAV read whatsoever: any
/// surviving `nav()` call on the epoch trigger reverts instead of quietly returning a number.
contract AlwaysStaleNavOracle {
    function nav() external pure returns (uint256) {
        revert StalePrice();
    }

    function lastUpdated() external view returns (uint64) {
        return uint64(block.timestamp);
    }
}

contract REXPrimaryInitiateTest is Test {
    MockMailbox mailbox;
    MockERC20 usdc;
    MockCollateralWarpRoute usdcRoute;
    MockSyntheticWarpRoute wrwaRoute;
    MockNavOracle navOracle;
    REXPrimary rex;
    REXLens lens;

    address alice = makeAddr("alice");
    uint32 constant PRUV_DOMAIN = 7336;

    // re-declared so the tests can build the expected payloads for vm.expectEmit
    event SubEpochInitiated(uint64 epochId, uint64 batchId, uint256 netAmount);
    event SubBatchBridged(uint64 batchId, uint256 usdcAmount, bytes32 msgId);

    receive() external payable {}

    function _deploy(uint256 minSub_) internal returns (REXPrimary r) {
        return _deployWithOracle(minSub_, INavOracle(address(navOracle)));
    }

    /// @dev `_deploy` with the NAV oracle as a knob, so a test can wire `AlwaysStaleNavOracle`.
    function _deployWithOracle(uint256 minSub_, INavOracle oracle) internal returns (REXPrimary r) {
        r = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            minSub_,
            uint64(block.timestamp + 1),
            1 days,
            minSub_,
            0,
            address(0xFEE),
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
        r.enrollRemote(PRUV_DOMAIN, bytes32(uint256(uint160(address(0xBEEF)))));
    }

    function setUp() public {
        mailbox = new MockMailbox(PRUV_DOMAIN);
        mailbox.setQuoteFee(0);
        usdc = new MockERC20("USDC", 6);
        usdcRoute = new MockCollateralWarpRoute(usdc);
        usdcRoute.setGasQuote(0);
        wrwaRoute = new MockSyntheticWarpRoute("wRWA", 6);
        navOracle = new MockNavOracle(1e18);
        rex = _deploy(0);
        _reachEpochBased(rex);
        lens = new REXLens();
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

    function _deposit(REXPrimary r, address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(r), amount);
        r.requestDeposit(amount);
        vm.stopPrank();
    }

    function test_initiate_locks_the_side_and_advances_the_counter() public {
        _deposit(rex, alice, 100e6);
        rex.initiateSubEpoch();

        (uint256 totalIn, uint256 matchedOut, uint256 netAmount, uint64 batchId, bool locked) =
            rex.epochSide(1, CLASS_SUB_EPOCH);
        assertEq(totalIn, 100e6, "totalIn is frozen at lock");
        assertEq(matchedOut, 0, "matchedOut is a permanent 0 (ADR-024)");
        assertEq(netAmount, 100e6);
        assertEq(batchId, 1, "batch ids start at 1");
        assertTrue(locked);
        assertEq(rex.currentEpochId(), 2, "new requests land in the next epoch");
    }

    function test_initiate_cancel_after_lock_reverts() public {
        _deposit(rex, alice, 100e6);
        rex.initiateSubEpoch();
        vm.prank(alice);
        vm.expectRevert(EpochLocked.selector);
        rex.cancelRequest(encodeId(CLASS_SUB_EPOCH, 1), 1e6);
    }

    function test_initiate_bridges_the_batch() public {
        _deposit(rex, alice, 100e6);
        rex.initiateSubEpoch();

        (uint8 status, uint256 netIn,) = rex.subBatch(1);
        assertEq(status, uint8(BatchStatus.Bridged));
        assertEq(netIn, 100e6);
        assertEq(rex.openSubBatchId(), 0, "a bridged batch is no longer the open one");
        assertEq(usdc.balanceOf(address(rex)), 0, "USDC left for the collateral route");
    }

    function test_initiate_with_nothing_reverts() public {
        vm.expectRevert(NothingToSettle.selector);
        rex.initiateSubEpoch();
    }

    /// @dev ADR-025 replaced the keeper address check with a schedule check: alice, who used to
    /// be rejected here as "not the keeper", now runs the epoch herself. Asserted on the SUCCESS
    /// (a real bridged batch), not on the absence of one particular revert.
    function test_initiate_is_permissionless() public {
        _deposit(rex, alice, 100e6);
        vm.prank(alice);
        rex.initiateSubEpoch();
        (uint8 status, uint256 netIn,) = rex.subBatch(1);
        assertEq(status, uint8(BatchStatus.Bridged), "alice, not a keeper, closed the epoch");
        assertEq(netIn, 100e6);
    }

    /// @dev The accrual branch: below MIN_SUB the batch waits and takes the next
    /// epoch's residual too, then bridges once (spec §7.4 step 4, ADR-015).
    function test_initiate_below_min_accrues_across_epochs() public {
        REXPrimary r = _deploy(150e6);
        // launchpadMinimum == minSub (150e6) here, so EpochBased is only reachable via a real
        // launchpad (batch 1); the accrued subscribe batch is therefore batch 2.
        _launchToEpochBased(r, 150e6, bytes32(uint256(uint160(address(0xBEEF)))));

        _deposit(r, alice, 100e6);
        r.initiateSubEpoch();
        (uint8 s1, uint256 n1,) = r.subBatch(2);
        assertEq(s1, uint8(BatchStatus.Accumulating), "under the minimum, so it waits");
        assertEq(n1, 100e6);
        assertEq(r.openSubBatchId(), 2, "still the open batch");

        _deposit(r, alice, 80e6);
        warpToNextPeriod(r); // ADR-025: one close per period
        r.initiateSubEpoch();
        (uint8 s2, uint256 n2,) = r.subBatch(2);
        assertEq(s2, uint8(BatchStatus.Bridged), "180e6 clears 150e6");
        assertEq(n2, 180e6, "one batch, two epochs");

        (,,, uint64 b1,) = r.epochSide(1, CLASS_SUB_EPOCH);
        (,,, uint64 b2,) = r.epochSide(2, CLASS_SUB_EPOCH);
        assertEq(b1, 2);
        assertEq(b2, 2, "both epochs point at the same batch");
    }

    /// @dev The two events this task introduces must carry the right payload — a wrong
    /// epochId/batchId/amount would otherwise pass unnoticed (constitution Art 12).
    function test_initiate_emits_both_events_with_full_payload() public {
        _deposit(rex, alice, 100e6);

        // SubEpochInitiated fires before the bridge — epoch 1, batch 1, whole side is the residual
        vm.expectEmit(true, true, true, true, address(rex));
        emit SubEpochInitiated(1, 1, 100e6);
        // SubBatchBridged fires on bridge; the msgId is not known ahead of the call, so only
        // check the two predictable fields here and pin the msgId separately below
        vm.expectEmit(true, true, false, false, address(rex));
        emit SubBatchBridged(1, 100e6, bytes32(0));

        rex.initiateSubEpoch();

        (, bytes32 instrMsgId,,) = rex.batchLeg(1, false);
        assertTrue(instrMsgId != bytes32(0), "instruction leg dispatched");
    }

    /// @dev The accrual first call emits SubEpochInitiated but MUST NOT emit SubBatchBridged
    /// (nothing bridged below the minimum).
    function test_initiate_below_min_emits_no_bridge_event() public {
        REXPrimary r = _deploy(150e6);
        r.enrollRemote(PRUV_DOMAIN, bytes32(uint256(uint160(address(0xBEEF)))));
        _launchToEpochBased(r, 150e6, bytes32(uint256(uint160(address(0xBEEF)))));
        _deposit(r, alice, 100e6);

        vm.recordLogs();
        r.initiateSubEpoch();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        bytes32 bridgedSig = keccak256("SubBatchBridged(uint64,uint256,bytes32)");
        bytes32 initiatedSig = keccak256("SubEpochInitiated(uint64,uint64,uint256)");
        bool sawInitiated;
        for (uint256 i = 0; i < logs.length; i++) {
            if (logs[i].emitter != address(r)) continue;
            assertTrue(logs[i].topics[0] != bridgedSig, "no bridge event below the minimum");
            if (logs[i].topics[0] == initiatedSig) sawInitiated = true;
        }
        assertTrue(sawInitiated, "SubEpochInitiated still fires while accumulating");
    }

    /// @dev The invariant that lets requestDeposit skip a lock guard: after initiate,
    /// a fresh deposit lands on epoch 2, unlocked, and does not disturb epoch 1.
    function test_deposit_after_initiate_lands_on_a_fresh_unlocked_epoch() public {
        _deposit(rex, alice, 100e6);
        rex.initiateSubEpoch();

        usdc.mint(alice, 40e6);
        vm.startPrank(alice);
        usdc.approve(address(rex), 40e6);
        uint256 id2 = rex.requestDeposit(40e6);
        vm.stopPrank();

        assertEq(id2, encodeId(CLASS_SUB_EPOCH, 2), "new deposit is epoch 2");
        (uint256 t2,,,, bool locked2) = rex.epochSide(2, CLASS_SUB_EPOCH);
        assertEq(t2, 40e6, "epoch 2 carries only the new deposit");
        assertFalse(locked2, "epoch 2 is unlocked");

        (uint256 t1,,,, bool locked1) = rex.epochSide(1, CLASS_SUB_EPOCH);
        assertEq(t1, 100e6, "epoch 1 aggregate untouched by the later deposit");
        assertTrue(locked1, "epoch 1 stays locked");
    }

    /// @dev ADR-026 D2: `StalePrice` leaves the epoch trigger entirely, so a schedule (ADR-025) can
    /// never be blocked by a NAV relay that has not run. Wired to an oracle that reverts on EVERY
    /// read, so this passes only if `initiateSubEpoch` makes no NAV call at all -- not merely if the
    /// value it reads happens to be fresh.
    function test_initiate_succeeds_with_a_stale_nav() public {
        REXPrimary r = _deployWithOracle(0, INavOracle(address(new AlwaysStaleNavOracle())));
        _reachEpochBased(r);
        _deposit(r, alice, 100e6);
        vm.warp(block.timestamp + 30 days); // far past any staleness window
        r.initiateSubEpoch{value: 0}();
        assertEq(r.currentEpochId(), 2, "the epoch advanced without a NAV read");
        (uint8 status,,) = r.subBatch(1);
        assertEq(status, uint8(BatchStatus.Bridged), "and the batch bridged");
    }

    /// @dev Spec §2.3: `navAtInitiate` is now a fail-loud sentinel, not a placeholder. `PruvExecutor`
    /// used to DIVIDE by this field, so a `0` panics on any site that still depends on it, where a
    /// plausible-looking `1e18` would compute silently. Decoded off the real dispatched body, not
    /// off a getter -- the wire is what PRUV sees.
    function test_navAtInitiate_is_zero_on_the_wire() public {
        _deposit(rex, alice, 100e6);
        rex.initiateSubEpoch();

        (, bytes32 instrMsgId,,) = rex.batchLeg(1, false);
        (,,, bytes memory body,,) = mailbox.messageOf(instrMsgId);
        Instruction memory instr = Codec.decode(body);
        assertEq(uint256(instr.legId), 1, "decoded the instruction leg, not the token leg");
        assertEq(instr.amount, 100e6);
        assertEq(instr.navAtInitiate, 0, "navAtInitiate is a 0 sentinel (ADR-026 D4)");
    }

    /// @dev ADR-026 D3: home NAV survives as a DISPLAY feed. `previewRedeem` keeps reading it -- and
    /// keeps propagating `StalePrice`, which is the whole point of the split: a lapsed relay degrades
    /// a quote and halts nothing.
    function test_previewRedeem_still_reads_nav() public {
        (uint256 usdcOut,) = lens.previewRedeem(address(rex), 1e18);
        assertEq(usdcOut, 1e18, "quoted at the live 1e18 NAV, fee 0");

        REXPrimary stale = _deployWithOracle(0, INavOracle(address(new AlwaysStaleNavOracle())));
        _reachEpochBased(stale);
        vm.expectRevert(StalePrice.selector);
        lens.previewRedeem(address(stale), 1e18);
    }

    function test_initiate_refunds_unspent_interchain_gas() public {
        mailbox.setQuoteFee(1e14);
        usdcRoute.setGasQuote(2e14);
        _deposit(rex, alice, 100e6);

        uint256 fees = 3e14;
        vm.deal(address(this), fees + 1 ether);
        uint256 before = address(this).balance;
        rex.initiateSubEpoch{value: fees + 1 ether}();
        assertEq(address(this).balance, before - fees, "overpay refunded");
        assertEq(address(rex).balance, 0, "no native stranded");
    }
}
