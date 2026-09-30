// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {REXRegistryV2} from "../src/REXRegistryV2.sol";

/// @notice Deploys the global home-chain REXRegistryV2 (ADR-032). One instance per home chain,
/// deployed once -- not per fund.
///
/// No constructor arguments: the DEPLOYER becomes owner. Hand it over afterwards with the
/// Ownable2Step pair if a different key should hold it; `renounceOwnership` reverts, because an
/// ownerless directory could never be corrected.
///
/// After deploying, record the address in the home chain's chain-facts file under the top-level
/// `rexRegistryV2` key (`config/networks.<home>.json`) -- nothing writes it automatically, and both
/// the ops verbs and the backend's discovery fail closed until it is filled in.
contract DeployRegistryV2 is Script {
    function run() external returns (REXRegistryV2 registry) {
        registry = deploy();
    }

    /// @dev Test seam: the same deploy path, callable without a broadcast context.
    function deploy() public returns (REXRegistryV2 registry) {
        vm.startBroadcast();
        registry = new REXRegistryV2();
        vm.stopBroadcast();

        console.log("REXRegistryV2 deployed at:", address(registry));
        console.log("owner:", registry.owner());
    }
}
