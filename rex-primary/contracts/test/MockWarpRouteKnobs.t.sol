// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import "./mocks/MockERC20.sol";

contract MockWarpRouteKnobsTest is Test {
    function test_collateral_scale_and_revert_switch() public {
        MockERC20 t = new MockERC20("T", 6);
        MockCollateralWarpRoute r = new MockCollateralWarpRoute(t);
        r.setGasQuote(0);
        assertEq(r.scale(), 1);
        r.setScale(1e12);
        assertEq(r.scale(), 1e12);
        t.mint(address(this), 10);
        t.approve(address(r), 10);
        r.setRevertSends(true);
        vm.expectRevert(MockCollateralWarpRoute.SendsDisabled.selector);
        r.transferRemote(1, bytes32(0), 10);
        r.setRevertSends(false);
        r.transferRemote(1, bytes32(0), 10);
    }

    function test_synthetic_scale_and_revert_switch() public {
        MockSyntheticWarpRoute r = new MockSyntheticWarpRoute("S", 6);
        r.setGasQuote(0);
        assertEq(r.scale(), 1);
        r.deliverTokens(bytes32(uint256(uint160(address(this)))), 10);
        r.setRevertSends(true);
        vm.expectRevert(MockSyntheticWarpRoute.SendsDisabled.selector);
        r.transferRemote(1, bytes32(0), 10);
    }
}
