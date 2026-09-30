// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {OrderBookDeploymentBase} from "./OrderBookDeploymentBase.sol";

/// @notice Deploys the order-book infrastructure from a reviewed, chain-specific JSON configuration.
/// @dev Forge simulates unless `--broadcast` is supplied.
contract DeployOrderBookSystem is OrderBookDeploymentBase {
    function run() external returns (DeploymentAddresses memory deployed) {
        (DeploymentConfig memory config, bytes32 configHash) = _loadDeploymentConfig();
        _validateDeploymentConfig(config);
        address broadcaster = vm.envAddress("DEPLOYER_ADDRESS");
        _validateAddress("deployerAddress", broadcaster);

        vm.startBroadcast(broadcaster);
        deployed = _deploy(config);
        vm.stopBroadcast();

        _assertFreshDeployment(config, deployed);
        _writeSimulationArtifact(config, configHash, broadcaster, deployed);
    }
}
