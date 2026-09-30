// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {DeployPruv} from "../script/DeployPruv.s.sol";
import {DeployConfig} from "../script/lib/DeployConfig.sol";
import {PruvExecutor} from "../src/PruvExecutor.sol";
import "./mocks/MockERC20.sol";
import {MockRWAConversion} from "./mocks/MockRWAConversion.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockRWAToken.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Exercises `DeployPruv`'s config -> deploy path deterministically: builds an
/// in-memory JSON config pointing at freshly deployed mocks (no real network, no fs writes)
/// and asserts the deployed `PruvExecutor` is wired exactly from that config. A second test
/// proves the `fs_permissions` widening (contracts/foundry.toml) actually lets a script read
/// the real repo-root config from the Foundry root.
contract DeployPruvTest is Test {
    uint32 constant HOME_DOMAIN = 11155111;
    uint32 constant PRUV_DOMAIN = 7336;
    string constant DEFAULT_FUND = "evergreen";

    DeployPruv internal script;

    MockMailbox internal mailbox;
    MockERC20 internal fakeUsdc;
    MockSyntheticWarpRoute internal usdcRoute;
    MockRWAToken internal rwaToken;
    MockCollateralWarpRoute internal wrwaRoute;
    MockRWAConversion internal rwaConversion;

    function setUp() public {
        script = new DeployPruv();

        mailbox = new MockMailbox(PRUV_DOMAIN);
        fakeUsdc = new MockERC20("FakeUSDC", 6);
        usdcRoute = new MockSyntheticWarpRoute("pUSDC", 6);
        rwaToken = new MockRWAToken(address(fakeUsdc));
        wrwaRoute = new MockCollateralWarpRoute(IERC20(address(rwaToken)));
        rwaConversion = new MockRWAConversion(1e18);
    }

    /// @dev Chain facts + the legacy per-fund copy `config/networks.json` still carries for the
    /// DEFAULT fund. A second fund's addresses never appear here -- they live only in its own
    /// fund file, which is why `defaultFund` gates the drift check.
    function _networksJson() internal view returns (string memory) {
        return string.concat(
            '{"defaultFund":"',
            DEFAULT_FUND,
            '","home":{"hyperlaneDomain":',
            vm.toString(uint256(HOME_DOMAIN)),
            '},"fund":{"hyperlaneDomain":',
            vm.toString(uint256(PRUV_DOMAIN)),
            ',"contracts":{',
            '"mailbox":"',
            vm.toString(address(mailbox)),
            '","usdc":"',
            vm.toString(address(fakeUsdc)),
            '","usdcWarpRoute":"',
            vm.toString(address(usdcRoute)),
            '","wrwaWarpRoute":"',
            vm.toString(address(wrwaRoute)),
            '","rwaToken":"',
            vm.toString(address(rwaToken)),
            '"}}}'
        );
    }

    /// @dev One fund file: its `key` plus the per-fund `contracts` block the executor is wired
    /// from, and the `pruvExecutor` params block that was already here. `rwaConversion_` is a
    /// parameter (not read off test state) so a second fund can be wired against its OWN NAV
    /// source, proving per-fund isolation for that field (`rwaConversion` IS per-fund --
    /// `config/networks.json` records it under `fund.contracts.rwaConversion`).
    function _fundJson(string memory key, address rwaToken_, address wrwaRoute_, address rwaConversion_)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '{"key":"',
            key,
            '","contracts":{"rwaToken":"',
            vm.toString(rwaToken_),
            '","fundWrwaRoute":"',
            vm.toString(wrwaRoute_),
            '","rwaConversion":"',
            vm.toString(rwaConversion_),
            '"},"pruvExecutor":{"subFulfillTimeout":3600,"executorSlippageBps":100,',
            '"redeemFulfillTimeout":864000,"redeemDelay":600,"minRedeemDelay":60}}'
        );
    }

    function _defaultFundJson() internal view returns (string memory) {
        return _fundJson(DEFAULT_FUND, address(rwaToken), address(wrwaRoute), address(rwaConversion));
    }

    /// @dev The config -> deploy path, deterministically: no real RPC, no real config file,
    /// just the script's own parsing + constructor wiring + sanity asserts against mocks.
    function test_deploy_wiresPruvExecutorFromConfig() public {
        PruvExecutor executor = script.deploy(_networksJson(), _defaultFundJson());

        assertEq(executor.homeDomain(), HOME_DOMAIN, "homeDomain");
        assertEq(executor.rwaToken(), address(rwaToken), "rwaToken");
        assertEq(address(executor.usdc()), address(fakeUsdc), "usdc");
        assertEq(address(executor.wrwaRoute()), address(wrwaRoute), "wrwaRoute");
        assertEq(address(executor.usdcRoute()), address(usdcRoute), "usdcRoute");
        assertEq(address(executor.rwaConversion()), address(rwaConversion), "rwaConversion");
        assertEq(executor.redeemDelay(), 600, "redeemDelay");
        assertEq(executor.minRedeemDelay(), 60, "minRedeemDelay");
    }

    /// @dev The point of SC7b-1: a SECOND fund deploys from its own fund file, against the same
    /// unchanged `networks.json`. Its RWA token, wRWA route AND NAV source (`rwaConversion`,
    /// itself per-fund per `config/networks.json`'s `fund.contracts.rwaConversion`) are its
    /// own -- nothing about fund #1's config is read or edited, and the default-fund drift
    /// gate does not apply.
    function test_deploy_secondFundUsesItsOwnAddresses() public {
        MockRWAToken rwaTokenTwo = new MockRWAToken(address(fakeUsdc));
        MockCollateralWarpRoute wrwaRouteTwo = new MockCollateralWarpRoute(IERC20(address(rwaTokenTwo)));
        MockRWAConversion rwaConversionTwo = new MockRWAConversion(2e18);

        PruvExecutor executor = script.deploy(
            _networksJson(),
            _fundJson("fund-two", address(rwaTokenTwo), address(wrwaRouteTwo), address(rwaConversionTwo))
        );

        assertEq(executor.rwaToken(), address(rwaTokenTwo), "rwaToken");
        assertEq(address(executor.wrwaRoute()), address(wrwaRouteTwo), "wrwaRoute");
        assertEq(address(executor.rwaConversion()), address(rwaConversionTwo), "rwaConversion");
        // Chain facts still come from networks.json -- they are shared, not per-fund.
        assertEq(address(executor.usdc()), address(fakeUsdc), "usdc");
        assertEq(address(executor.usdcRoute()), address(usdcRoute), "usdcRoute");
    }

    /// @dev The default fund's addresses exist in BOTH files (ops + services read the
    /// networks.json copy). Drift between them must revert the deploy, never pick a winner.
    function test_deploy_revertsWhenDefaultFundDriftsFromNetworks() public {
        MockRWAToken wrongToken = new MockRWAToken(address(fakeUsdc));

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployConfig.AddressMismatch.selector,
                ".fund.contracts.rwaToken",
                address(rwaToken),
                address(wrongToken)
            )
        );
        script.deploy(
            _networksJson(), _fundJson(DEFAULT_FUND, address(wrongToken), address(wrwaRoute), address(rwaConversion))
        );
    }

    /// @dev Proves the `fs_permissions` gotcha fix: a script rooted at `contracts/` can read
    /// the real config committed one level up at the repo root.
    function test_canReadRealNetworksConfig() public view {
        string memory json = vm.readFile("../config/networks.json");
        assertEq(vm.parseJsonUint(json, ".home.hyperlaneDomain"), HOME_DOMAIN);
    }

    /// @dev The real committed pair must agree: `config/networks.json`'s `defaultFund` names a
    /// fund file whose `contracts` block matches the legacy copy. This is the check that would
    /// have caught the 2026-08-24 warp-route swap being applied to one file and not the other.
    function test_realConfigDefaultFundMatchesNetworks() public {
        FundConfigHarness harness = new FundConfigHarness();
        string memory networksJson = vm.readFile("../config/networks.json");
        string memory fundJson = vm.readFile("../config/deploy/testnet-dev.params.json");

        // The gate is a no-op unless these two agree, so assert the comparing branch IS the one
        // under test -- otherwise this test passes vacuously if either key is ever renamed.
        assertEq(vm.parseJsonString(fundJson, ".key"), vm.parseJsonString(networksJson, ".defaultFund"));

        harness.check(networksJson, fundJson);
    }
}

/// @notice Exposes `DeployConfig`'s internal drift gate so it can be asserted directly against
/// the real committed config, without a test-only function on a deploy script.
contract FundConfigHarness is DeployConfig {
    function check(string memory networksJson, string memory fundJson) external view {
        requireFundMatchesNetworks(networksJson, fundJson);
    }
}
