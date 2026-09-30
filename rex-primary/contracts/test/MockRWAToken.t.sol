// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "@rex-shared-mocks/MockRWAToken.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import {MockRWAConversion} from "./mocks/MockRWAConversion.sol";

/// @notice SC13 §1.1 -- the vault mock reproduces the Pruv vault's measured behaviour (Track A §1.4):
/// NAV-priced conversion, percentage and fixed fees on both sides, a withdrawal block and adminBurn.
contract MockRWATokenTest is Test {
    MockSyntheticWarpRoute pusdc;
    MockRWAToken vault;
    MockRWAConversion conversion;
    address feeTo = makeAddr("feeTo");
    address user = makeAddr("user");

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function setUp() public {
        pusdc = new MockSyntheticWarpRoute("pUSDC", 6);
        vault = new MockRWAToken(address(pusdc));
        conversion = new MockRWAConversion(1e18);
        vault.setFeeRecipient(feeTo);
    }

    function _deposit(uint256 assets) internal returns (uint256 shares) {
        pusdc.deliverTokens(_b32(user), assets);
        vm.startPrank(user);
        pusdc.approve(address(vault), assets);
        shares = vault.deposit(assets, user);
        vm.stopPrank();
    }

    function test_default_is_par_and_fee_free() public {
        assertEq(_deposit(100e6), 100e6);
        assertEq(vault.convertToAssets(100e6), 100e6);
        vm.prank(user);
        assertEq(vault.redeem(100e6, user, user), 100e6);
    }

    function test_nav_prices_both_directions() public {
        vault.setConversion(address(conversion));
        conversion.setValue(1.05e18);
        assertEq(vault.convertToAssets(100e6), 105e6);
        assertEq(vault.convertToShares(105e6), 100e6);
    }

    function test_percentage_fee_matches_the_fork_measurement() public {
        vault.setFee(false, vault.FEE_PERCENT(), 0.005e18);
        uint256 shares = _deposit(10e6);
        vm.prank(user);
        uint256 net = vault.redeem(shares, user, user);
        assertEq(net, 9_950_248, "executor side of the Track A 10-share row");
        assertEq(pusdc.balanceOf(feeTo), 49_752, "fee side of the same row");
    }

    function test_fixed_fee_larger_than_assets_panics() public {
        vault.setFee(false, vault.FEE_FIXED(), 15e6);
        uint256 shares = _deposit(10e6);
        vm.prank(user);
        vm.expectRevert(stdError.arithmeticError);
        vault.redeem(shares, user, user);
    }

    function test_fixed_entry_fee_is_taken_before_minting() public {
        vault.setFee(true, vault.FEE_FIXED(), 15e6);
        assertEq(_deposit(20e6), 5e6);
        assertEq(pusdc.balanceOf(feeTo), 15e6);
    }

    function test_percentage_above_100_percent_is_rejected() public {
        uint8 kind = vault.FEE_PERCENT();
        vm.expectRevert(MockRWAToken.FeePercentageTooHigh.selector);
        vault.setFee(true, kind, 1e18 + 1);
    }

    function test_withdrawals_blocked_reverts_redeem() public {
        uint256 shares = _deposit(10e6);
        vault.setWithdrawalsBlocked(true);
        vm.prank(user);
        vm.expectRevert(MockRWAToken.WithdrawalsBlocked.selector);
        vault.redeem(shares, user, user);
    }

    function test_adminBurn_removes_shares() public {
        _deposit(10e6);
        vault.adminBurn(user, 1);
        assertEq(vault.balanceOf(user), 10e6 - 1);
    }

    function test_share_decimals_scale_conversion() public {
        vault.setShareDecimals(18);
        assertEq(vault.convertToShares(1e6), 1e18);
        assertEq(vault.convertToAssets(1e18), 1e6);
    }
}
