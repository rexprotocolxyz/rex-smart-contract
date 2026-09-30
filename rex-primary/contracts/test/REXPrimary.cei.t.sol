// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "../src/REXPrimary.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/INavOracle.sol";
import "@rex-shared/Errors.sol";
import "./mocks/MockERC20.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import "@rex-shared-mocks/MockNavOracle.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {perSecondSchedule} from "./helpers/TestSchedule.sol";

/// @notice M-7: a malicious/compromised `usdcRoute` whose `transferRemote` reenters the
/// permissionless `releaseStaleRedeemBatch` mid-bridge. `initiateSubEpoch` already holds the
/// shared OZ `ReentrancyGuard` lock (it is itself `nonReentrant`) for the whole call -- the lock
/// is a single contract-wide flag, not per-function -- so the only thing standing between a
/// successful reentrant release and a reverted one is whether `releaseStaleRedeemBatch` itself
/// carries the `nonReentrant` modifier.
contract MaliciousWrwaRoute is MockSyntheticWarpRoute {
    address public target;
    uint64 public batchIdToRelease;
    bool public reenterEnabled;
    bool public reentryOk;
    bytes public reentryReturnData;

    constructor(string memory n, uint8 d) MockSyntheticWarpRoute(n, d) {}

    function configure(address _target, uint64 _batchId, bool _enabled) external {
        target = _target;
        batchIdToRelease = _batchId;
        reenterEnabled = _enabled;
    }

    /// @dev Fires on the wRWA payout inside `_claimRedeem`, which is the only external call REX
    /// still makes while a drainable redeem batch exists (ADR-027 narrowed the drain to wind-down,
    /// where the subscribe leg never bridges and the redeem leg cannot be both open and bridging).
    function _update(address from, address to, uint256 value) internal override {
        super._update(from, to, value);
        if (reenterEnabled) {
            reenterEnabled = false; // one shot: the reentrant call transfers nothing itself
            (bool ok, bytes memory data) =
                target.call(abi.encodeWithSignature("releaseStaleRedeemBatch(uint64)", batchIdToRelease));
            reentryOk = ok;
            reentryReturnData = data;
        }
    }
}

contract MaliciousUsdcRoute {
    IERC20 public immutable token;
    address public target;
    uint64 public batchIdToRelease;
    bool public reenterEnabled;
    bool public reentryOk;
    bytes public reentryReturnData;

    uint256 private nonce;

    constructor(IERC20 _token) {
        token = _token;
    }

    function configure(address _target, uint64 _batchId, bool _enabled) external {
        target = _target;
        batchIdToRelease = _batchId;
        reenterEnabled = _enabled;
    }

    function quoteTransferRemote(uint32, bytes32, uint256) external pure returns (Quote[] memory quotes) {
        quotes = new Quote[](1);
        quotes[0] = Quote({token: address(0), amount: 0});
    }

    function transferRemote(uint32, bytes32, uint256 amount) external payable returns (bytes32 id) {
        token.transferFrom(msg.sender, address(this), amount); // mirror a collateral route's lock
        if (reenterEnabled) {
            (bool ok, bytes memory data) =
                target.call(abi.encodeWithSignature("releaseStaleRedeemBatch(uint64)", batchIdToRelease));
            reentryOk = ok;
            reentryReturnData = data;
        }
        id = keccak256(abi.encode(nonce++, amount));
    }

    function wrappedToken() external view returns (address) {
        return address(token);
    }
}

contract REXPrimaryCEITest is Test {
    MockMailbox mailbox;
    MockERC20 usdc;
    MockCollateralWarpRoute usdcRoute;
    MockSyntheticWarpRoute wrwaRoute;
    MockNavOracle navOracle;
    REXPrimary rex;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint32 constant PRUV_DOMAIN = 7336;

    receive() external payable {}

    function setUp() public {
        mailbox = new MockMailbox(PRUV_DOMAIN);
        mailbox.setQuoteFee(0);
        usdc = new MockERC20("USDC", 6);
        usdcRoute = new MockCollateralWarpRoute(usdc);
        usdcRoute.setGasQuote(0);
        wrwaRoute = new MockSyntheticWarpRoute("wRWA", 6);
        wrwaRoute.setGasQuote(0);
        navOracle = new MockNavOracle(1e18);
        rex = _deploy(IWarpRoute(address(usdcRoute)), IWarpRoute(address(wrwaRoute)), 0);
        rex.enrollRemote(PRUV_DOMAIN, bytes32(uint256(uint160(address(0xBEEF)))));
        vm.warp(rex.launchpadStart() + rex.launchpadPeriod());
        rex.closeLaunchpad();
    }

    function _requestRedeemVia(REXPrimary r, MockSyntheticWarpRoute route, address who, uint256 amount)
        internal
        returns (uint256 id)
    {
        route.deliverTokens(bytes32(uint256(uint160(who))), amount);
        vm.startPrank(who);
        IERC20(address(route)).approve(address(r), amount);
        id = r.requestRedeem(amount);
        vm.stopPrank();
    }

    /// @param minRedeem_ In **wRWA** (ADR-026 D2); this fixture's NAV is a fixed 1e18 and both mocks
    /// are 6-decimal, so the threshold reads the same as under the old USDC-value gate.
    function _deploy(IWarpRoute usdcRoute_, IWarpRoute wrwaRoute_, uint256 minRedeem_) internal returns (REXPrimary r) {
        r = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            usdcRoute_,
            wrwaRoute_,
            PRUV_DOMAIN,
            0,
            uint64(block.timestamp + 1),
            1 days,
            0,
            0,
            address(0xFEE),
            SC3Params({
                navOracle: INavOracle(address(navOracle)),
                minRedeem: minRedeem_,
                redeemCancelFeeBps: 0,
                subFulfillTimeout: 10 days,
                redemptionFeeBps: 0,
                redeemFulfillTimeout: 10 days,
                windDownWindow: 9 days,
                schedule: perSecondSchedule()
            })
        );
    }

    function _deposit(REXPrimary r, address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(r), amount);
        r.requestDeposit(amount);
        vm.stopPrank();
    }

    function _requestRedeem(REXPrimary r, address who, uint256 amount) internal {
        wrwaRoute.deliverTokens(bytes32(uint256(uint160(who))), amount);
        vm.startPrank(who);
        IERC20(address(wrwaRoute)).approve(address(r), amount);
        r.requestRedeem(amount);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------
    // Guard test (M-7): releaseStaleRedeemBatch must carry nonReentrant.
    // ------------------------------------------------------------------

    /// @dev A redeem batch eligible for `releaseStaleRedeemBatch` -- below `minRedeem`, still
    /// `Accumulating`, in wind-down with the grace window elapsed -- while a DIFFERENT, already
    /// released batch pays out a claim through a malicious `wrwaRoute` that reenters the drain on
    /// the live batch mid-transfer. The reentrant call's own state-machine checks hold regardless
    /// of CEI ordering, which isolates what `nonReentrant` alone contributes.
    ///
    /// ADR-027 moved which call can carry the reentry. The drain used to open in `EpochBased` on
    /// an elapsed accrual cap, so a SUBSCRIBE bridge could carry it; the cap is gone and the drain
    /// now opens only in wind-down, where `initiateSubEpoch` forces `S = 0` and the redeem leg
    /// cannot be bridging and accruing at once (one `openRedeemBatchId`). The claim payout is what
    /// is left, and it is enough: `claim` is `nonReentrant` too, so the shared lock is held.
    ///
    /// FAILS pre-fix: the reentrant call succeeds (no guard on `releaseStaleRedeemBatch`) and
    /// releases a batch out from under a still-executing `claim`. PASSES post-fix: the shared
    /// `ReentrancyGuard` lock makes it revert with `ReentrancyGuardReentrantCall`, batch untouched.
    function test_releaseStaleRedeemBatch_blocks_reentry_from_claim_payout() public {
        MaliciousWrwaRoute evilWrwaRoute = new MaliciousWrwaRoute("wRWA", 6);
        REXPrimary r = _deploy(IWarpRoute(address(usdcRoute)), IWarpRoute(address(evilWrwaRoute)), 100e6);
        r.enrollRemote(PRUV_DOMAIN, bytes32(uint256(uint160(address(0xBEEF)))));
        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad(); // vacuous close (launchpadMinimum 0) -> EpochBased, no batch

        // Batch 1: below minRedeem, then wind down and let the window elapse so it can be drained.
        uint256 bobId = _requestRedeemVia(r, evilWrwaRoute, bob, 40e6);
        r.initiateSubEpoch();
        r.triggerWindDown();
        vm.warp(block.timestamp + r.windDownWindow() + 1);
        r.releaseStaleRedeemBatch(1);
        (uint8 b1,,,) = r.redeemBatch(1);
        assertEq(b1, uint8(BatchStatus.Released), "batch 1 is the one that pays a claim");

        // Batch 2: a fresh below-minimum redeem in wind-down -- open, and itself drainable.
        _requestRedeemVia(r, evilWrwaRoute, alice, 50e6);
        r.initiateSubEpoch();
        assertEq(r.openRedeemBatchId(), 2, "batch 2 accrues while batch 1 is done");
        (uint8 b2,,,) = r.redeemBatch(2);
        assertEq(b2, uint8(BatchStatus.Accumulating));

        // Bob claims his refund off batch 1; the payout transfer reenters the drain on batch 2.
        evilWrwaRoute.configure(address(r), 2, true);
        vm.prank(bob);
        r.claim(bobId, 40e6);

        assertFalse(evilWrwaRoute.reentryOk(), "reentrant releaseStaleRedeemBatch must revert (guard)");
        (uint8 b2After,,,) = r.redeemBatch(2);
        assertEq(b2After, uint8(BatchStatus.Accumulating), "batch 2 released mid-claim");
        bytes memory data = evilWrwaRoute.reentryReturnData();
        assertEq(data.length, 4, "revert data is a bare custom error selector");
        assertEq(bytes4(data), ReentrancyGuard.ReentrancyGuardReentrantCall.selector, "reverts via the shared guard");

        (, uint256 postNetIn,,) = r.redeemBatch(2);
        assertEq(postNetIn, 50e6, "batch 2's accrual untouched");
        assertEq(r.openRedeemBatchId(), 2, "batch 2 still the open redeem batch");
    }

    // ------------------------------------------------------------------
    // CEI reorder consistency (M-7): the reorder must not change outcomes.
    // ------------------------------------------------------------------

    /// @dev Drives initiateSubEpoch to bridge BOTH a subscribe batch and a redeem batch in the
    /// same call (matching off, so both residuals equal their gross sides) and asserts the
    /// terminal state matches the pre-reorder outcome exactly -- proving the effects-before-
    /// interaction reorder changed nothing on the happy path. Passes both before and after M-7.
    function test_initiateSubEpoch_bridges_both_legs_cei_reorder_is_behavior_preserving() public {
        REXPrimary r = _deploy(IWarpRoute(address(usdcRoute)), IWarpRoute(address(wrwaRoute)), 10e6);
        r.enrollRemote(PRUV_DOMAIN, bytes32(uint256(uint160(address(0xBEEF)))));
        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad();

        _deposit(r, alice, 100e6);
        _requestRedeem(r, bob, 50e6);

        assertEq(r.heldEscrowUSDC(), 100e6, "sub escrow held pre-initiate");
        assertEq(r.liveRedeemEscrow(), 50e6, "redeem escrow held pre-initiate");

        r.initiateSubEpoch();

        (uint8 sStatus, uint256 sNetIn,) = r.subBatch(1);
        assertEq(sStatus, uint8(BatchStatus.Bridged), "subscribe batch bridged");
        assertEq(sNetIn, 100e6);
        assertEq(r.openSubBatchId(), 0, "no longer the open subscribe batch");
        assertEq(r.heldEscrowUSDC(), 0, "subscribe escrow fully drained on bridge");
        assertEq(usdc.balanceOf(address(r)), 0, "USDC left for the collateral route");

        (uint8 rStatus, uint256 rNetIn,,) = r.redeemBatch(1);
        assertEq(rStatus, uint8(BatchStatus.Bridged), "redeem batch bridged");
        assertEq(rNetIn, 50e6);
        assertEq(r.openRedeemBatchId(), 0, "no longer the open redeem batch");
        assertEq(r.liveRedeemEscrow(), 0, "redeem escrow fully drained on bridge");
        assertEq(IERC20(address(wrwaRoute)).balanceOf(address(r)), 0, "wRWA left for the synthetic burn route");

        assertEq(r.outstandingSubBatches(), 1, "bridged, not terminated");
        assertEq(r.outstandingRedeemBatches(), 1, "bridged, not terminated");
    }
}
