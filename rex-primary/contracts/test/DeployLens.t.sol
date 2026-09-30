// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {DeployLens} from "../script/DeployLens.s.sol";
import {REXLens} from "../src/REXLens.sol";

contract DeployLensTest is Test {
    function test_deploys_a_lens_with_code() public {
        REXLens lens = new DeployLens().run();
        assertGt(address(lens).code.length, 0);
    }
}
