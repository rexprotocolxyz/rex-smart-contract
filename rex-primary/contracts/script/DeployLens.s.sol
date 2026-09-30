// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {REXLens} from "../src/REXLens.sol";

/// @notice One REXLens per chain (SC13 §2.2). Record the address as the top-level `rexLens` key of
/// `config/networks.json`, beside `rexRegistry`.
contract DeployLens is Script {
    function run() external returns (REXLens lens) {
        vm.startBroadcast();
        lens = new REXLens();
        vm.stopBroadcast();
        console.log("REXLens deployed at:", address(lens));
    }
}
