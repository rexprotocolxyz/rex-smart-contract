// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {REXRegistry} from "../src/REXRegistry.sol";

/// @notice Deploys the global home-chain REXRegistry (ADR-019 / ADR-021, spec section 17.3). One
/// instance per home chain, deployed once -- not per fund.
///
/// It takes no constructor arguments: the DEPLOYER becomes owner (Ownable(msg.sender), matching
/// NavOracleConsumer). Deploying from the key that should own it is the simplest path; otherwise
/// hand it over afterwards with the Ownable2Step pair, exposed as the ops verbs
/// `transferRegistryOwnership` / `acceptRegistryOwnership`. What that key is and how it is held is
/// an operational decision outside this repo (ADR-021 amendment 2026-09-04); `renounceOwnership`
/// reverts, because an ownerless directory could never be corrected.
///
/// After deploying, record the address in `config/networks.json`'s top-level `rexRegistry` key --
/// nothing writes it automatically, and every ops registry verb fails closed until it is
/// filled in. Full sequence: `docs/testing/new-fund-runbook.md`.
///
/// Home chain only (Sepolia), so none of the PRUV build quirks (paris evm_version, legacy tx)
/// apply -- forge script --broadcast works directly.
contract DeployRegistry is Script {
    function run() external returns (REXRegistry registry) {
        registry = deploy();
    }

    /// @dev Test seam: the same deploy path, callable without a broadcast context.
    function deploy() public returns (REXRegistry registry) {
        vm.startBroadcast();
        registry = new REXRegistry();
        vm.stopBroadcast();

        console.log("REXRegistry deployed at:", address(registry));
        console.log("owner:", registry.owner());
    }
}
