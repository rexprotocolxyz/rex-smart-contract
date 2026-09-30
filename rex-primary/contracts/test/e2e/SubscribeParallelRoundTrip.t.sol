// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "../helpers/World.sol";
import {warpBy} from "../helpers/TestSchedule.sol";

/// @notice ADR-018 T+5 end-to-end, across the SC13 matrix: three daily subscribe batches are in flight
/// together; batch 3 settles first, then batch 1; batch 2's deposit gate never opens, so it aborts.
abstract contract SubscribeParallelRoundTripBase is World {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");

    function _id(uint64 seq) internal pure returns (uint256) {
        return (uint256(1) << 248) | seq;
    }

    function _completeSubscribeReturn(uint64 batchId) internal returns (uint256 shares) {
        _relay(_subInstr(batchId));
        (, bytes32 ret,,,) = exec.lastReturnLeg();
        shares = _relay(ret);
    }

    function _abortSubscribe(uint64 batchId) internal returns (uint256 refunded) {
        vault.setRejectDeposits(true);
        _relay(_subInstr(batchId)); // records + SubDepositDeferred
        warpBy(SUB_FULFILL + 1);
        exec.abortDeposit(batchId);
        (, bytes32 ret,,,) = exec.lastReturnLeg();
        refunded = _relay(ret);
        vault.setRejectDeposits(false);
    }

    function test_three_parallel_batches_settle_and_abort_independently() public {
        _subscribe(alice, _usd(100));
        rex.initiateSubEpoch();
        _subscribe(bob, _usd(200));
        warpBy(1 days);
        rex.initiateSubEpoch();
        _subscribe(carol, _usd(300));
        warpBy(1 days);
        rex.initiateSubEpoch();
        assertEq(rex.nextSubBatchId(), 4);
        assertEq(rex.openSubBatchId(), 0);

        uint256 shares3 = _completeSubscribeReturn(3);
        rex.settleSubBatch(3);
        uint256 shares1 = _completeSubscribeReturn(1);
        rex.settleSubBatch(1);
        uint256 refunded2 = _abortSubscribe(2);
        assertEq(refunded2, _usd(200), "batch 2 comes home whole");

        // `_usd(N)` reads `usdc.decimals()`, an external staticcall that would otherwise consume
        // `vm.prank`'s single-use cheat if evaluated inline as the call arg.
        uint256 carolAmt = _usd(300);
        vm.prank(carol);
        rex.claim(_id(3), carolAmt);
        uint256 aliceAmt = _usd(100);
        vm.prank(alice);
        rex.claim(_id(1), aliceAmt);
        uint256 bobAmt = _usd(200);
        vm.prank(bob);
        rex.claim(_id(2), bobAmt);

        assertEq(homeWrwaRoute.balanceOf(carol), shares3, "batch 3 wRWA");
        assertEq(homeWrwaRoute.balanceOf(alice), shares1, "batch 1 wRWA");
        assertEq(usdc.balanceOf(bob), _usd(200), "batch 2 USDC refunded, not wRWA");
        assertEq(homeWrwaRoute.balanceOf(bob), 0, "aborted cohort got no wRWA");
        assertGe(
            IERC20(address(homeWrwaRoute)).balanceOf(address(rex)), rex.settledUnclaimed() + rex.liveRedeemEscrow()
        );
    }
}

contract SubscribeParallelRoundTripTest is SubscribeParallelRoundTripBase, DefaultConfig {}

contract SubscribeParallelRoundTripNavDriftTest is SubscribeParallelRoundTripBase, NavDriftConfig {}

contract SubscribeParallelRoundTripPercentFeeTest is SubscribeParallelRoundTripBase, PercentFeeConfig {}

contract SubscribeParallelRoundTripFixedFeeTest is SubscribeParallelRoundTripBase, FixedFeeConfig {}

contract SubscribeParallelRoundTripDecimals18Test is SubscribeParallelRoundTripBase, Decimals18Config {}
