// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";
import {DeployConfig} from "./lib/DeployConfig.sol";
import {NavReporter, IRWAConversion} from "../src/NavReporter.sol";
import {IMailbox} from "@rex-shared/IHyperlane.sol";

/// @notice Deploys the PRUV `NavReporter` from `config/networks.json` (fund.mailbox +
/// home.hyperlaneDomain) and a per-fund file (`contracts.rwaConversion` +
/// navReporter.heartbeatSeconds; override the path with `FUND_PARAMS`), with the home `NavOracleConsumer` passed as the bytes32
/// recipient (NAV_CONSUMER env var / config/deployments.json). Fail-loud sanity-asserts the
/// wiring before logging the address.
///
/// NOTE: the LIVE PRUV deploy uses `FOUNDRY_PROFILE=pruv forge build` (paris) + `cast send --create`
/// (PRUV has no EIP-1559, so `forge script --broadcast` fails fee-estimation -- see the SC8d
/// findings). This script's value on PRUV is the sanity-assert + the test seam; run() is usable for
/// a local/devnet chain that does support EIP-1559.
contract DeployNavReporter is DeployConfig {
    /// @dev The chain-facts file. Overridable because a second HOME CHAIN is a second file
    /// (`config/networks.bsc-testnet.json`), never an edit of the operational one -- 1.3.1 on
    /// Sepolia and staging still read `config/networks.json`. Same shape as `FUND_PARAMS`:
    ///   `NETWORKS=../config/networks.bsc-testnet.json forge script ...`
    string internal constant NETWORKS_PATH = "../config/networks.json";
    string internal constant DEFAULT_FUND_PARAMS = "../config/deploy/testnet-dev.params.json";

    function run() external returns (NavReporter reporter) {
        bytes32 consumer = vm.envBytes32("NAV_CONSUMER");
        reporter = deploy(
            readConfig(vm.envOr("NETWORKS", NETWORKS_PATH)),
            readConfig(vm.envOr("FUND_PARAMS", DEFAULT_FUND_PARAMS)),
            consumer
        );
    }

    /// @dev Test seam: same deploy + sanity-assert logic as run(), parameterized on already-loaded
    /// JSON + the consumer, so test/DeployNavReporter.t.sol can substitute mocks without fs writes.
    function deploy(string memory networksJson, string memory fundJson, bytes32 consumer)
        public
        returns (NavReporter reporter)
    {
        requireFundMatchesNetworks(networksJson, fundJson);

        address mailbox = fundMailbox(networksJson);
        uint32 homeDomain = homeHyperlaneDomain(networksJson);
        // The NAV source is per FUND -- each fund token has its own RWAConversion.
        address source = contractsRwaConversion(fundJson);
        uint256 heartbeat = navReporterHeartbeat(fundJson);

        vm.startBroadcast();
        reporter = new NavReporter(IMailbox(mailbox), homeDomain, consumer, IRWAConversion(source), heartbeat);
        vm.stopBroadcast();

        requireAddressEq("NavReporter.mailbox", mailbox, address(reporter.mailbox()));
        requireUint32Eq("NavReporter.homeDomain", homeDomain, reporter.homeDomain());
        requireAddressEq("NavReporter.source", source, address(reporter.source()));
        requireUintEq("NavReporter.heartbeat", heartbeat, reporter.heartbeat());
        if (reporter.consumer() != consumer) revert("NavReporter.consumer mismatch");

        console.log("NavReporter deployed at:", address(reporter));
    }
}
