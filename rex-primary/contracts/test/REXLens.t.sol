// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./helpers/World.sol";
import {REXLens} from "../src/REXLens.sol";

abstract contract REXLensBase is World {
    REXLens internal lens;
    address internal alice = makeAddr("alice");

    function setUp() public virtual override {
        super.setUp();
        lens = new REXLens();
    }

    function test_preview_uses_nav_and_both_decimals() public view {
        (uint256 out, uint256 fee) = lens.previewRedeem(address(rex), _wrwa(100));
        assertEq(fee, 0);
        assertEq(out, Math.mulDiv(_usd(100), _config().nav, 1e18), "100 wRWA at NAV, in home USDC units");
    }

    /// @dev Art. 8.2 / SC6a Critical: once the epoch has a requester, the quote is that epoch's frozen fee,
    /// not the live one.
    function test_preview_uses_the_frozen_epoch_fee() public {
        rex.setFees(0, 0, 100);
        vm.warp(block.timestamp + rex.CONFIG_TIMELOCK());
        rex.applyFees();
        _requestRedeem(alice, _wrwa(1)); // freezes 100 bps onto the current epoch
        rex.setFees(0, 0, 150);
        vm.warp(block.timestamp + rex.CONFIG_TIMELOCK());
        rex.applyFees();
        (, uint256 fee) = lens.previewRedeem(address(rex), _wrwa(100));
        uint256 gross = Math.mulDiv(_usd(100), _config().nav, 1e18);
        assertEq(fee, gross * 100 / 10_000, "frozen 100 bps, not the live 150");
    }

    function test_shutDownBlockers_mirrors_the_old_view() public {
        (bool elapsed, uint64 s, uint64 r) = lens.shutDownBlockers(address(rex));
        assertFalse(elapsed);
        assertEq(s, 0);
        assertEq(r, 0);
        rex.triggerWindDown();
        vm.warp(block.timestamp + rex.windDownWindow());
        (elapsed,,) = lens.shutDownBlockers(address(rex));
        assertTrue(elapsed);
    }
}

contract REXLensTest is REXLensBase, DefaultConfig {
    function setUp() public override(REXLensBase, World) {
        REXLensBase.setUp();
    }
}

contract REXLensDecimals18Test is REXLensBase, Decimals18Config {
    function setUp() public override(REXLensBase, World) {
        REXLensBase.setUp();
    }
}
