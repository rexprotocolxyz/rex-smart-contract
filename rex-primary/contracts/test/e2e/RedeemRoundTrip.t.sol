// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "../helpers/World.sol";

/// @notice SC5b RS8/RS13 end-to-end redeem round trips, run across the SC13 configuration matrix.
/// Fulfil: the issuer funds the vault with what the batch pays out, the executor redeems and bridges
/// the net USDC home, the redeemer claims all of it. Abort: nobody funds, the deadline passes, the
/// wRWA comes home in full.
abstract contract RedeemRoundTripBase is World {
    address internal alice = makeAddr("alice");

    function test_redeem_fulfil_round_trip_conserves() public {
        uint256 id = _requestRedeem(alice, _wrwa(100));
        rex.initiateSubEpoch();
        uint256 shares = _relay(_redeemInstr(1));

        _fundVaultFor(shares);
        uint256 expectedNet = vault.previewRedeem(shares);
        exec.executeRedeem(1);
        (, bytes32 ret,,,) = exec.lastReturnLeg();
        uint256 atHome = _relay(ret);
        assertEq(atHome, expectedNet * _usdUnit(), "home receives the vault's net payout");

        rex.settleRedeemBatch(1);
        // `_wrwa(100)` reads `homeWrwaRoute.decimals()`, an external staticcall that would
        // otherwise consume `vm.prank`'s single-use cheat if evaluated inline as the call arg.
        uint256 claimAmt = _wrwa(100);
        vm.prank(alice);
        rex.claim(id, claimAmt);

        assertEq(usdc.balanceOf(alice), atHome, "alice got the whole net payout");
        assertEq(usdc.balanceOf(address(rex)), 0, "no USDC stranded");
        assertEq(rex.settledRedeemUSDC(), 0, "reserve drained");
    }

    function test_redeem_abort_round_trip_refunds_wrwa() public {
        uint256 id = _requestRedeem(alice, _wrwa(100));
        rex.initiateSubEpoch();
        _relay(_redeemInstr(1));

        vm.warp(block.timestamp + REDEEM_FULFILL + 1);
        exec.abortRedeem(1);
        (, bytes32 ret,,,) = exec.lastReturnLeg();
        _relay(ret);
        rex.settleRedeemBatch(1);

        uint256 claimAmt = _wrwa(100);
        vm.prank(alice);
        rex.claim(id, claimAmt);
        assertEq(IERC20(address(homeWrwaRoute)).balanceOf(alice), _wrwa(100), "wRWA back in full, no fee");
        assertEq(rex.settledUnclaimed(), 0, "refund pot drained");
    }
}

contract RedeemRoundTripTest is RedeemRoundTripBase, DefaultConfig {}

contract RedeemRoundTripNavDriftTest is RedeemRoundTripBase, NavDriftConfig {}

contract RedeemRoundTripPercentFeeTest is RedeemRoundTripBase, PercentFeeConfig {}

contract RedeemRoundTripFixedFeeTest is RedeemRoundTripBase, FixedFeeConfig {}

contract RedeemRoundTripDecimals18Test is RedeemRoundTripBase, Decimals18Config {}
