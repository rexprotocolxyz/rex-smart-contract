// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {DeployRegistry} from "../script/DeployRegistry.s.sol";
import {REXRegistry} from "../src/REXRegistry.sol";

contract DeployRegistryTest is Test {
    function test_deploy_startsEmptyWithAnOwner() public {
        DeployRegistry script = new DeployRegistry();
        REXRegistry registry = script.deploy();
        // The deployer becomes owner (Ownable(msg.sender)); which address that is depends on the
        // broadcast context, so assert the property that matters -- an owner EXISTS and the
        // directory starts empty. Handing ownership to the multisig is a post-deploy step.
        assertTrue(registry.owner() != address(0));
        assertEq(registry.fundCount(), 0);
        assertEq(registry.allKeys().length, 0);
    }
}
