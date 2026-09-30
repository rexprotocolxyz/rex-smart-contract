// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";
import {DeployConfig} from "./lib/DeployConfig.sol";
import {PruvExecutor} from "../src/PruvExecutor.sol";
import {IMailbox, IWarpRoute} from "@rex-shared/IHyperlane.sol";
import {IRWAConversion} from "../src/NavReporter.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Deploys `PruvExecutor` on PRUV from `config/networks.json` (the shared chain facts
/// -- mailbox, USDC, USDC route, `home.hyperlaneDomain`) and a per-fund file
/// (`contracts.rwaToken` + `contracts.fundWrwaRoute`, and the `pruvExecutor.*`
/// timeouts/slippage), then fail-loud sanity-asserts the deployed contract's wiring before
/// logging its address for handoff to `DeployHome` and post-deploy wiring.
///
/// Run (from `contracts/`): `forge script script/DeployPruv.s.sol --rpc-url pruv --broadcast`
/// A SECOND fund passes its own file and leaves fund #1's untouched:
/// `FUND_PARAMS=../config/deploy/<fund>.params.json forge script ... --broadcast`
contract DeployPruv is DeployConfig {
    /// @dev The chain-facts file. Overridable because a second HOME CHAIN is a second file
    /// (`config/networks.bsc-testnet.json`), never an edit of the operational one -- 1.3.1 on
    /// Sepolia and staging still read `config/networks.json`. Same shape as `FUND_PARAMS`:
    ///   `NETWORKS=../config/networks.bsc-testnet.json forge script ...`
    string internal constant NETWORKS_PATH = "../config/networks.json";
    string internal constant DEFAULT_FUND_PARAMS = "../config/deploy/testnet-dev.params.json";

    function run() external returns (PruvExecutor executor) {
        executor = deploy(
            readConfig(vm.envOr("NETWORKS", NETWORKS_PATH)), readConfig(vm.envOr("FUND_PARAMS", DEFAULT_FUND_PARAMS))
        );
    }

    /// @dev Test seam: the same deploy + sanity-assert logic as `run()`, parameterized on
    /// already-loaded JSON so `test/DeployPruv.t.sol` can substitute mock addresses
    /// without touching the real repo config or needing fs write permissions.
    function deploy(string memory networksJson, string memory fundJson) public returns (PruvExecutor executor) {
        requireFundMatchesNetworks(networksJson, fundJson);

        address mailbox = fundMailbox(networksJson);
        address usdc = fundUsdc(networksJson);
        address usdcRoute = fundUsdcWarpRoute(networksJson);
        uint32 homeDomain = homeHyperlaneDomain(networksJson);

        address wrwaRoute = contractsFundWrwaRoute(fundJson);
        address rwaToken = contractsRwaToken(fundJson);
        address rwaConversion = contractsRwaConversion(fundJson);

        uint256 subFulfillTimeout = pruvSubFulfillTimeout(fundJson);
        uint256 executorSlippageBps = pruvExecutorSlippageBps(fundJson);
        uint256 redeemFulfillTimeout = pruvRedeemFulfillTimeout(fundJson);

        // ADR-028 D7: checked here, before construction, so a misconfigured asset fails loud with
        // this script's own message -- PruvExecutor's own `_unit` enforces the same 6-18 bound
        // internally and would otherwise revert first with its generic InvalidState.
        requireDecimalsInRange("usdc", IERC20Metadata(usdc).decimals());
        requireDecimalsInRange("rwaToken", IERC20Metadata(rwaToken).decimals());

        vm.startBroadcast();
        executor = new PruvExecutor(
            IMailbox(mailbox),
            IWarpRoute(wrwaRoute),
            homeDomain,
            rwaToken,
            usdc,
            IWarpRoute(usdcRoute),
            subFulfillTimeout,
            executorSlippageBps,
            redeemFulfillTimeout,
            IRWAConversion(rwaConversion),
            pruvRedeemDelay(fundJson),
            pruvMinRedeemDelay(fundJson)
        );
        vm.stopBroadcast();

        // Fail-loud: a deployed executor that doesn't read back exactly what it was
        // constructed from means either the config parse or the constructor arg order
        // is wrong -- never hand a silently-mis-wired address to the next deploy step.
        requireUint32Eq("PruvExecutor.homeDomain", homeDomain, executor.homeDomain());
        requireAddressEq("PruvExecutor.rwaToken", rwaToken, executor.rwaToken());
        requireAddressEq("PruvExecutor.usdc", usdc, address(executor.usdc()));
        requireAddressEq("PruvExecutor.wrwaRoute", wrwaRoute, address(executor.wrwaRoute()));
        requireAddressEq("PruvExecutor.usdcRoute", usdcRoute, address(executor.usdcRoute()));
        requireAddressEq("PruvExecutor.rwaConversion", rwaConversion, address(executor.rwaConversion()));
        requireUintEq("PruvExecutor.redeemDelay", pruvRedeemDelay(fundJson), executor.redeemDelay());
        requireUintEq("PruvExecutor.minRedeemDelay", pruvMinRedeemDelay(fundJson), executor.minRedeemDelay());

        console.log("PruvExecutor deployed at:", address(executor));
    }
}
