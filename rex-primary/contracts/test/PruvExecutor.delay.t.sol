// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./helpers/World.sol";

/// @notice SC13 R5, R6, R8, R14 -- ADR-030 D1-D5 and D10 on the executor.
contract PruvExecutorDelayTest is World, DefaultConfig {
    uint64 internal constant T = 1 days;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function _deployExecutor() internal override returns (PruvExecutor) {
        return new PruvExecutor(
            IMailbox(address(mailbox)),
            IWarpRoute(address(pruvWrwaRoute)),
            PRUV_DOMAIN,
            address(vault),
            address(pusdcRoute),
            IWarpRoute(address(pusdcRoute)),
            SUB_FULFILL,
            EXEC_SLIPPAGE_BPS,
            REDEEM_FULFILL,
            conversion,
            T,
            1 hours
        );
    }

    function _now() internal view returns (uint256) {
        return vm.getBlockTimestamp();
    }

    /// @dev R5: subscribe and redeem close together; the redemption waits t.
    function test_R5_redeem_waits_t_after_the_shared_close() public {
        _subscribe(alice, _usd(100));
        _requestRedeem(bob, _wrwa(50));
        rex.initiateSubEpoch();
        _relay(_subInstr(1));
        uint256 shares = _relay(_redeemInstr(1));
        _fundVaultFor(shares);

        vm.expectRevert(NotReadyToExecute.selector);
        exec.executeRedeem(1);
        vm.warp(_now() + T);
        exec.executeRedeem(1);
    }

    /// @dev R6 (OQ-1 = b): a later subscription pauses a waiting redemption for another t.
    function test_R6_a_later_deposit_restarts_the_wait() public {
        _requestRedeem(bob, _wrwa(50));
        rex.initiateSubEpoch();
        uint256 shares = _relay(_redeemInstr(1));
        vm.warp(_now() + 2 days); // past R1's own t, issuer has not funded yet

        _subscribe(alice, _usd(100));
        rex.initiateSubEpoch();
        _relay(_subInstr(1)); // S2 lands now
        _fundVaultFor(shares);

        vm.expectRevert(NotReadyToExecute.selector);
        exec.executeRedeem(1);
        assertEq(exec.depositUnlockAt(), _now() + T);
        vm.warp(_now() + T);
        exec.executeRedeem(1);
    }

    /// @dev R8: the newer batch waits for the older; aborting the older unblocks it.
    function test_R8_oldest_first() public {
        _requestRedeem(alice, _wrwa(100));
        rex.initiateSubEpoch();
        _relay(_redeemInstr(1));
        vm.warp(_now() + 1);
        _requestRedeem(bob, _wrwa(50));
        rex.initiateSubEpoch();
        uint256 shares2 = _relay(_redeemInstr(2));
        assertEq(exec.oldestOpenRedeem(), 1);

        _fundVaultFor(shares2); // enough for batch 2, not batch 1
        vm.warp(_now() + T);
        vm.expectRevert(NotReadyToExecute.selector);
        exec.executeRedeem(2);

        // The vault holds batch 2's target, below batch 1's, so batch 1 aborts after its deadline.
        vm.warp(_now() + REDEEM_FULFILL);
        exec.abortRedeem(1);
        assertEq(exec.oldestOpenRedeem(), 2, "head moved past the aborted batch");
        exec.executeRedeem(2);
        assertEq(exec.oldestOpenRedeem(), 0);
    }

    /// @dev R14: the knob cannot go below the floor or reach the timeout.
    function test_R14_setRedeemDelay_bounds() public {
        vm.expectRevert(InvalidState.selector);
        exec.setRedeemDelay(1 hours - 1);
        vm.expectRevert(InvalidState.selector);
        exec.setRedeemDelay(uint64(REDEEM_FULFILL));
        vm.expectEmit(true, true, true, true);
        emit IPruvExecutor.RedeemDelaySet(2 days);
        exec.setRedeemDelay(2 days);
        assertEq(exec.redeemDelay(), 2 days);
        vm.prank(alice);
        vm.expectRevert();
        exec.setRedeemDelay(2 days);
    }

    function test_R14_constructor_bounds() public {
        vm.expectRevert(InvalidState.selector);
        new PruvExecutor(
            IMailbox(address(mailbox)),
            IWarpRoute(address(pruvWrwaRoute)),
            PRUV_DOMAIN,
            address(vault),
            address(pusdcRoute),
            IWarpRoute(address(pusdcRoute)),
            SUB_FULFILL,
            EXEC_SLIPPAGE_BPS,
            REDEEM_FULFILL,
            conversion,
            1 hours - 1,
            1 hours
        );
        vm.expectRevert(InvalidState.selector);
        new PruvExecutor(
            IMailbox(address(mailbox)),
            IWarpRoute(address(pruvWrwaRoute)),
            PRUV_DOMAIN,
            address(vault),
            address(pusdcRoute),
            IWarpRoute(address(pusdcRoute)),
            SUB_FULFILL,
            EXEC_SLIPPAGE_BPS,
            REDEEM_FULFILL,
            conversion,
            uint64(REDEEM_FULFILL),
            1 hours
        );
    }
}
