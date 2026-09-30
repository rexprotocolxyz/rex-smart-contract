// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./helpers/World.sol";

/// @notice SC13 R1, R2, R3, R4, R7, R9, R12: after the deadline a redemption has exactly two endings.
abstract contract PruvExecutorAbortBase is World {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    function _recordRedeem(address who, uint256 whole) internal returns (uint64 batchId, uint256 shares) {
        _requestRedeem(who, _wrwa(whole));
        rex.initiateSubEpoch();
        batchId = rex.nextRedeemBatchId() - 1;
        shares = _relay(_redeemInstr(batchId));
        vm.warp(_now() + 1);
    }

    function _aborted(uint64 id) internal view returns (bool a) {
        (,,,,,, a,) = exec.pendingRedeem(id);
    }

    function _executed(uint64 id) internal view returns (bool e) {
        (,,,,, e,,) = exec.pendingRedeem(id);
    }
}

contract PruvExecutorAbortTest is PruvExecutorAbortBase, DefaultConfig {
    /// @dev R1: NAV rises after record; funding the record-time figure is not enough; the live target is.
    function test_R1_nav_drift_is_executable_once_funded_live_and_abortable_otherwise() public {
        conversion.setValue(1.05e18);
        (uint64 id, uint256 shares) = _recordRedeem(alice, 1000);
        (,, uint256 recorded,,,,,) = exec.pendingRedeem(id);
        pusdcRoute.deliverTokens(_b32(address(vault)), recorded); // exactly what 1.3.1 asked for
        conversion.setValue(1.06e18);

        vm.expectRevert(NotReadyToExecute.selector);
        exec.executeRedeem(id); // clean refusal, not a vault revert
        assertEq(exec.redeemTarget(id), vault.convertToAssets(shares));

        uint256 snap = vm.snapshotState();
        pusdcRoute.deliverTokens(_b32(address(vault)), exec.redeemTarget(id) - recorded);
        exec.executeRedeem(id);
        assertTrue(_executed(id));
        vm.revertToState(snap);

        vm.warp(_now() + REDEEM_FULFILL);
        exec.abortRedeem(id);
        assertTrue(_aborted(id), "1.3.1 reverted BatchExecutable here");
    }

    /// @dev R2: the executor loses withdrawal rights; the vault is funded; abort must still work.
    function test_R2_withdrawal_block_is_abortable() public {
        (uint64 id, uint256 shares) = _recordRedeem(alice, 100);
        _fundVaultFor(shares);
        vault.setWithdrawalsBlocked(true);
        vm.warp(_now() + REDEEM_FULFILL);
        exec.abortRedeem(id);
        assertTrue(_aborted(id));
    }

    /// @dev A payable batch past its deadline is executed by the abort call, never cancelled.
    function test_abort_of_a_payable_batch_executes_it() public {
        (uint64 id, uint256 shares) = _recordRedeem(alice, 100);
        _fundVaultFor(shares);
        vm.warp(_now() + REDEEM_FULFILL);
        exec.abortRedeem(id);
        assertTrue(_executed(id));
        assertFalse(_aborted(id));
    }

    /// @dev R3 (F-B4-1): the deposit succeeds but the send home fails; the refund is still reachable.
    function test_R3_deposit_ok_send_fails_still_refunds() public {
        _subscribe(alice, _usd(100));
        vault.setRejectDeposits(true);
        rex.initiateSubEpoch();
        _relay(_subInstr(1)); // deferred
        vault.setRejectDeposits(false);
        pruvWrwaRoute.setRevertSends(true);
        vm.warp(_now() + SUB_FULFILL + 1);
        exec.abortDeposit(1);
        (,,, bool executed,, bool aborted) = exec.pending(1);
        assertFalse(executed, "the deposit was rolled back with its failed send");
        assertTrue(aborted, "and the USDC went home");
        assertEq(vault.balanceOf(address(exec)), 0);
    }

    /// @dev R4: after adminBurn, another batch still executes and a subscription is refunded.
    function test_R4_admin_burn_leaves_the_other_paths_working() public {
        (uint64 id1, uint256 shares1) = _recordRedeem(alice, 100);
        (uint64 id2,) = _recordRedeem(bob, 50);
        vault.adminBurn(address(exec), 1);
        _fundVaultFor(shares1);
        exec.executeRedeem(id1);
        assertTrue(_executed(id1));

        _subscribe(alice, _usd(10));
        rex.initiateSubEpoch();
        _relay(_subInstr(1)); // the return send is short by the burned share -> deferred, not a panic
        (,,, bool executed,,) = exec.pending(1);
        assertFalse(executed);
        vm.warp(_now() + SUB_FULFILL + 1);
        exec.abortDeposit(1);
        (,,,,, bool aborted) = exec.pending(1);
        assertTrue(aborted, "refund path still works");

        vm.warp(_now() + REDEEM_FULFILL);
        vm.expectRevert(); // the burned batch cannot send its shares home: outside the trust boundary
        exec.abortRedeem(id2);
    }

    /// @dev R7 (F-B4-6): past the deadline, vault funded, inside a t window -> abort works.
    function test_R7_no_dead_window_after_the_deadline() public {
        exec.setRedeemDelay(1 days);
        (uint64 id, uint256 shares) = _recordRedeem(alice, 100);
        _fundVaultFor(shares);
        vm.warp(_now() + REDEEM_FULFILL - 1 hours);
        _subscribe(bob, _usd(10));
        rex.initiateSubEpoch();
        _relay(_subInstr(1)); // stamps depositUnlockAt beyond the deadline
        vm.warp(_now() + 1 hours + 1);
        exec.abortRedeem(id);
        assertTrue(_aborted(id));
    }

    /// @dev R9: starving the attempt of gas can make abort revert, never abort a payable batch.
    /// If the pinned forge-std predates `snapshotState`/`revertToState`, use `snapshot`/`revertTo`.
    function test_R9_gas_griefing_cannot_force_an_abort() public {
        (uint64 id, uint256 shares) = _recordRedeem(alice, 100);
        _fundVaultFor(shares);
        vm.warp(_now() + REDEEM_FULFILL);
        uint256 starved;
        uint256 paid;
        for (uint256 g = 30_000; g < 1_500_000; g += 7_919) {
            uint256 snap = vm.snapshotState();
            (bool ok,) = address(exec).call{gas: g}(abi.encodeWithSelector(exec.abortRedeem.selector, id));
            if (ok) {
                paid++;
                assertTrue(_executed(id), "the only success an abort call may have here is the payout");
            } else {
                starved++;
            }
            assertFalse(_aborted(id), "a payable batch was aborted under a gas limit");
            vm.revertToState(snap);
        }
        // Both endings must actually be reached, or the sweep proves nothing: below the threshold the
        // attempt cannot finish AND the 1/64 left cannot pay for the send home, so the whole call
        // reverts; above it, the batch is simply paid.
        assertGt(starved, 0, "no gas limit in the sweep starved the call");
        assertGt(paid, 0, "no gas limit in the sweep let the batch pay out");
    }
}

contract PruvExecutorAbortFixedFeeTest is PruvExecutorAbortBase {
    function _config() internal pure override returns (Config memory) {
        return Config({nav: 1e18, feeKind: 2, feeValue: 30e6, homeUsdcDecimals: 6, homeWrwaDecimals: 6});
    }

    /// @dev R12: F <= a < 2F clears the vault but not REX's floor; a < F panics in the vault. Both abort.
    function test_R12_fixed_fee_dead_zones_abort() public {
        (uint64 idLow, uint256 sharesLow) = _recordRedeem(alice, 20); // a < F
        _fundVaultFor(sharesLow);
        vm.warp(_now() + REDEEM_FULFILL);
        exec.abortRedeem(idLow);
        assertTrue(_aborted(idLow));

        (uint64 idMid, uint256 sharesMid) = _recordRedeem(bob, 50); // F <= a < 2F
        _fundVaultFor(sharesMid);
        vm.warp(_now() + REDEEM_FULFILL);
        exec.abortRedeem(idMid);
        assertTrue(_aborted(idMid));
    }
}
