// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "../helpers/World.sol";

/// @notice SC1 walking-skeleton e2e against the real warp-route topology, run across the SC13 matrix:
///   USDC : Sepolia HypERC20Collateral(USDC) <-> PRUV HypERC20 synthetic
///   wRWA : PRUV HypERC20Collateral(RWAToken) <-> Sepolia HypERC20 synthetic  <- retail hold this
abstract contract SubscribeRoundTripBase is World {
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    uint256 internal constant ID1 = (uint256(1) << 248) | 1;

    /// @dev Tokens land before the instruction on both hops — the relayer drives it all.
    function test_round_trip_tokens_first() public {
        _subscribe(alice, _usd(100));
        _subscribe(bob, _usd(300));
        uint256 expectedShares = vault.previewDeposit(_pusd(400));

        rex.initiateSubEpoch();
        _relay(_subInstr(1));
        (, bytes32 ret,,,) = exec.lastReturnLeg();
        uint256 shares = _relay(ret);
        assertEq(shares, expectedShares * _wrwaUnit(), "home receives what the vault minted");

        rex.settleSubBatch(1);
        // `_usd(N)` reads `usdc.decimals()`, an external staticcall that would otherwise consume
        // `vm.prank`'s single-use cheat if evaluated inline as the call arg.
        uint256 aliceAmt = _usd(100);
        vm.prank(alice);
        rex.claim(ID1, aliceAmt);
        uint256 bobAmt = _usd(300);
        vm.prank(bob);
        rex.claim(ID1, bobAmt);

        assertApproxEqAbs(homeWrwaRoute.balanceOf(alice), shares / 4, 1, "alice: a quarter");
        assertApproxEqAbs(homeWrwaRoute.balanceOf(bob), shares * 3 / 4, 1, "bob: three quarters");
        assertLe(homeWrwaRoute.balanceOf(address(rex)), 2, "at most rounding dust left");
        if (_config().nav == 1e18 && _config().feeKind == 0) {
            assertEq(homeWrwaRoute.balanceOf(address(rex)), 0, "no wRWA stranded");
        }
        assertEq(usdc.balanceOf(address(rex)), 0, "no USDC stranded");
        assertEq(
            pusdcRoute.balanceOf(address(vault)) + pusdcRoute.balanceOf(pruvFeeRecipient),
            _pusd(400),
            "deposit landed in the vault, net of Pruv's entry fee"
        );
    }

    /// @dev The instruction beats the tokens on the PRUV hop. The delivery reverts, which rolls back
    /// Hyperlane's delivery mark, so the SAME message is processed again once the tokens land.
    function test_round_trip_instruction_first_is_reprocessed() public {
        _subscribe(alice, _usd(400));
        rex.initiateSubEpoch();
        bytes32 outInstr = _subInstr(1);

        vm.expectRevert(NotReadyToExecute.selector);
        mailbox.process(outInstr); // no pUSDC at the executor yet
        assertFalse(mailbox.delivered(outInstr), "a reverted handle leaves the message undelivered");
        (,, bool exists,,,) = exec.pending(1);
        assertFalse(exists, "and records nothing");

        _relay(outInstr); // tokens land, anyone re-processes
        (, bytes32 ret,,,) = exec.lastReturnLeg();
        uint256 shares = _relay(ret);
        rex.settleSubBatch(1);

        uint256 aliceAmt = _usd(400);
        vm.prank(alice);
        rex.claim(ID1, aliceAmt);
        assertEq(homeWrwaRoute.balanceOf(alice), shares);
    }
}

contract SubscribeRoundTripTest is SubscribeRoundTripBase, DefaultConfig {}

contract SubscribeRoundTripNavDriftTest is SubscribeRoundTripBase, NavDriftConfig {}

contract SubscribeRoundTripPercentFeeTest is SubscribeRoundTripBase, PercentFeeConfig {}

contract SubscribeRoundTripFixedFeeTest is SubscribeRoundTripBase, FixedFeeConfig {}

contract SubscribeRoundTripDecimals18Test is SubscribeRoundTripBase, Decimals18Config {}
