// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "./REXPrimary.invariant.t.sol";

/// @notice SC13 R10: the redeem-reserve solvency campaign with an 18-decimal home stablecoin.
contract REXPrimaryInvariant18Test is Test {
    MockMailbox mailbox;
    MockERC20 usdc;
    MockCollateralWarpRoute usdcRoute;
    MockSyntheticWarpRoute wrwaRoute;
    MockNavOracle navOracle;
    REXPrimaryRedeemHandler handler;

    function setUp() public {
        mailbox = new MockMailbox(7336);
        mailbox.setQuoteFee(0);
        usdc = new MockERC20("USDC", 18);
        usdcRoute = new MockCollateralWarpRoute(usdc);
        usdcRoute.setGasQuote(0);
        wrwaRoute = new MockSyntheticWarpRoute("wRWA", 6);
        navOracle = new MockNavOracle(1e18);
        handler = new REXPrimaryRedeemHandler(usdc, mailbox, usdcRoute, wrwaRoute, navOracle, makeAddr("executor"));
        targetContract(address(handler));
    }

    function invariant_usdcSolvent18() public view {
        REXPrimary r = handler.pool();
        assertGe(usdc.balanceOf(address(r)), r.heldEscrowUSDC() + r.settledRedeemUSDC());
    }

    function invariant_wrwaSolvent18() public view {
        REXPrimary r = handler.pool();
        assertGe(IERC20(address(wrwaRoute)).balanceOf(address(r)), r.settledUnclaimed() + r.liveRedeemEscrow());
    }

    function invariant_claimNeverRevertsWhenEligible18() public view {
        assertFalse(handler.claimSubUnexpectedRevert(), "subscribe claim reverted while eligible");
        assertFalse(handler.claimRedeemUnexpectedRevert(), "redeem claim reverted while eligible");
    }
}
