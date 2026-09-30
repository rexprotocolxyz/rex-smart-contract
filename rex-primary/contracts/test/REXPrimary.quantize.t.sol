// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./helpers/World.sol";

/// @notice SC13 R11 + the home half of R10: with an 18-decimal stablecoin and an 18-decimal wRWA, every
/// amount must be a whole micro-unit, and the wire carries micro-units both ways.
contract REXPrimaryQuantizeTest is World {
    address internal alice = makeAddr("alice");

    function _config() internal pure override returns (Config memory) {
        return Config({nav: 1e18, feeKind: 0, feeValue: 0, homeUsdcDecimals: 18, homeWrwaDecimals: 18});
    }

    function _mintApprove(uint256 amount) internal {
        usdc.mint(alice, amount);
        vm.prank(alice);
        usdc.approve(address(rex), amount);
    }

    function test_deposit_rejects_a_sub_micro_remainder() public {
        _mintApprove(1e12 + 1);
        vm.prank(alice);
        vm.expectRevert(AmountNotQuantized.selector);
        rex.requestDeposit(1e12 + 1);
        vm.prank(alice);
        rex.requestDeposit(1e12);
    }

    function test_redeem_rejects_a_sub_micro_remainder() public {
        homeWrwaRoute.deliverTokens(_b32(alice), 2e12);
        vm.startPrank(alice);
        IERC20(address(homeWrwaRoute)).approve(address(rex), 2e12);
        vm.expectRevert(AmountNotQuantized.selector);
        rex.requestRedeem(1e12 + 1);
        rex.requestRedeem(1e12);
        vm.stopPrank();
    }

    /// @dev The one ADR-028's site list missed: an UNLOCKED cancel de-quantizes `totalIn`, which the
    /// next close adds to the batch whole.
    function test_every_cancel_is_quantized() public {
        _mintApprove(2e12);
        vm.prank(alice);
        uint256 id = rex.requestDeposit(2e12);
        vm.prank(alice);
        vm.expectRevert(AmountNotQuantized.selector);
        rex.cancelRequest(id, 1);
        vm.prank(alice);
        rex.cancelRequest(id, 1e12);
    }

    function test_launchpad_amounts_are_quantized() public {
        REXPrimary lp = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(homeWrwaRoute)),
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
                redeemFulfillTimeout: 11 days,
                windDownWindow: 9 days,
                schedule: perSecondSchedule()
            })
        );
        vm.warp(lp.launchpadStart());
        usdc.mint(alice, 2e12);
        vm.startPrank(alice);
        usdc.approve(address(lp), 2e12);
        vm.expectRevert(AmountNotQuantized.selector);
        lp.depositToLaunchpad(1e12 + 1);
        lp.depositToLaunchpad(2e12);
        vm.expectRevert(AmountNotQuantized.selector);
        lp.cancelLaunchpad(1);
        vm.stopPrank();
    }

    function test_wire_carries_micro_units_out_and_back() public {
        _subscribe(alice, 5e18); // 5 USDC at 18 decimals
        rex.initiateSubEpoch();
        (,,, bytes memory body,,) = mailbox.messageOf(_subInstr(1));
        assertEq(Codec.decode(body).amount, 5e6, "outbound amount is micro-units");

        usdc.mint(address(rex), 5e18); // the abort's token leg has landed
        bytes memory ret =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.SubAborted, amount: 5e6, navAtInitiate: 0}));
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(address(exec)), ret);
        assertEq(rex.heldEscrowUSDC(), 5e18, "inbound micro-units become 18-decimal units");
    }
}
