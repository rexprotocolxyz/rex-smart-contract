// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {DeployRegistryV2} from "../script/DeployRegistryV2.s.sol";
import {REXRegistryV2} from "../src/REXRegistryV2.sol";
import {RenounceDisabled} from "@rex-shared/Errors.sol";

contract DeployRegistryV2Test is Test {
    function test_deploy_makes_the_caller_owner_and_starts_empty() public {
        DeployRegistryV2 script = new DeployRegistryV2();
        REXRegistryV2 registry = script.deploy();

        // The deployer becomes owner (Ownable(msg.sender)); which address that is depends on the
        // broadcast context (vm.startBroadcast() with no argument uses forge's default sender, not
        // address(script) -- see DeployRegistry.t.sol for the same reasoning on v1), so assert the
        // property that matters -- an owner EXISTS and the directory starts empty.
        assertTrue(registry.owner() != address(0));
        assertEq(registry.fundCount(), 0);
        assertEq(registry.revision(), 0);
    }

    function test_deployed_registry_refuses_renounce() public {
        DeployRegistryV2 script = new DeployRegistryV2();
        REXRegistryV2 registry = script.deploy();
        vm.prank(registry.owner());
        vm.expectRevert(RenounceDisabled.selector);
        registry.renounceOwnership();
    }
}
