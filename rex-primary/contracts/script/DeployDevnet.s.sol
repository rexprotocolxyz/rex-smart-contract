// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {DeployPruv} from "./DeployPruv.s.sol";
import {DeployHome} from "./DeployHome.s.sol";
import {DeployLens} from "./DeployLens.s.sol";
import {PruvExecutor} from "../src/PruvExecutor.sol";
import {REXPrimary} from "../src/REXPrimary.sol";
import {NavOracleConsumer} from "../src/NavOracleConsumer.sol";
import {REXLens} from "../src/REXLens.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockRWAToken.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import "../test/mocks/MockERC20.sol";
import "../test/mocks/MockMessageRecipient.sol";
import {MockRWAConversion} from "../test/mocks/MockRWAConversion.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice SC8a Task 7: single-anvil local devnet deploy. Deploys fresh mock Hyperlane infra
/// -- topology mirrors real PRUV testnet (verified on-chain: the fund USDC warp route's
/// `wrappedToken()` returns the plain PRUV USDC token and holds a collateral pool -- it is
/// NOT a mint/burn synthetic route): two `MockMailbox`es (one per logical domain), home
/// `usdc`=collateral/`wrwa`=synthetic, fund `usdc`=collateral/`wrwa`=collateral, one shared
/// 6-decimals FakeUSDC, one `MockRWAToken` --
/// then runs the SAME `DeployPruv.deploy` / `DeployHome.deploy` test-seam logic Tasks 4/5 use
/// against real testnet config, just pointed at these mocks via in-memory JSON instead of a
/// committed file. `ops/src/devnet/deploy-devnet.ts` runs this via `forge script --broadcast`
/// and parses the resulting broadcast artifact for every address logged below.
///
/// `rexPrimary.feeRecipient` resolves via the SAME `${DEPLOYER_ADDRESS}`
/// env-placeholder mechanism `DeployConfig.getAddressOrEnv` already supports (see
/// config/deploy/testnet-dev.params.json) -- `deploy-devnet.ts` sets `DEPLOYER_ADDRESS` to
/// anvil's well-known default account #0 before invoking this script, the same account it
/// later signs `postDeploy`'s wiring txs with (both must be the deployed contracts' owner).
///
/// One extra mock beyond the real spine: `MockMessageRecipient`, a no-op `IMessageRecipient`
/// used ONLY by the devnet e2e's relayer smoke check (SC8a acceptance (c)). `MockMailbox`
/// delivers on the SAME instance `dispatch` was called on -- `process(id)` calls `handle()`
/// with `msg.sender` = that mailbox and `origin` = that mailbox's own `localDomain`,
/// regardless of which "chain" the recipient conceptually lives on. A real recipient's
/// `BridgeAdapter.handle` / `NavOracleConsumer.handle` origin+sender rendezvous check cannot be
/// satisfied by an arbitrary synthetic test message under that model without also faking a
/// full, correctly-enrolled cross-chain round trip (SC8b's job, not this harness's).
/// `MockMessageRecipient` accepts anything, decoupling the relayer's delivery MECHANISM (watch
/// `Dispatch` -> call `process`) from that business-logic correctness.
contract DeployDevnet is Script {
    uint32 internal constant HOME_DOMAIN = 11155111;
    uint32 internal constant PRUV_DOMAIN = 7336;
    /// @dev The devnet's single fund key. Must equal `DEVNET_FUND_KEY` in
    /// `ops/src/devnet/deploy-devnet.ts` -- both files describe the same one fund.
    string internal constant DEVNET_FUND_KEY = "local-fund";

    // AT-190: WithFee fee on both fund routes (0.75 USDC/leg, matches live PRUV) + the
    // executor's USDC float to pay it from (100 USDC ~= 130 legs). `@rex/ops` scenario
    // conservation assertions mirror these exact values (`ops/src/scenarios/shared.ts`).
    uint256 internal constant WITHFEE_FEE_AMOUNT = 750000; // 0.75 USDC (6 decimals)
    address internal constant WITHFEE_FEE_COLLECTOR = address(0xFEE);
    uint256 internal constant EXECUTOR_USDC_FLOAT = 100_000000; // 100 USDC

    struct DevnetAddresses {
        address homeMailbox;
        address fundMailbox;
        address usdc;
        address homeUsdcRoute;
        address homeWrwaRoute;
        address fundUsdcRoute;
        address fundWrwaRoute;
        address rwaToken;
        address testRecipient;
        address pruvExecutor;
        address navOracleConsumer;
        address rexPrimary;
        address rexLens;
    }

    function run() external returns (DevnetAddresses memory addrs) {
        vm.startBroadcast();
        MockMailbox homeMailbox = new MockMailbox(HOME_DOMAIN);
        MockMailbox fundMailbox = new MockMailbox(PRUV_DOMAIN);

        MockERC20 usdc = new MockERC20("FakeUSDC", 6);
        MockCollateralWarpRoute homeUsdcRoute = new MockCollateralWarpRoute(IERC20(address(usdc)));
        MockSyntheticWarpRoute homeWrwaRoute = new MockSyntheticWarpRoute("wRWA", 6);

        MockRWAToken rwaToken = new MockRWAToken(address(usdc));
        MockCollateralWarpRoute fundUsdcRoute = new MockCollateralWarpRoute(IERC20(address(usdc)));
        MockCollateralWarpRoute fundWrwaRoute = new MockCollateralWarpRoute(IERC20(address(rwaToken)));
        // ADR-026: PruvExecutor now reads its NAV source locally -- the devnet still deploys no
        // NavReporter, but the executor's constructor requires a live IRWAConversion regardless.
        MockRWAConversion rwaConversion = new MockRWAConversion(1e18);

        MockMessageRecipient testRecipient = new MockMessageRecipient();
        vm.stopBroadcast();

        string memory networksJson = _networksJson(
            address(homeMailbox),
            address(fundMailbox),
            address(usdc),
            address(homeUsdcRoute),
            address(homeWrwaRoute),
            address(fundUsdcRoute),
            address(fundWrwaRoute),
            address(rwaToken)
        );
        string memory paramsJson =
            _paramsJson(address(rwaToken), address(fundWrwaRoute), address(homeWrwaRoute), address(rwaConversion));

        // Same deploy() test seam DeployPruv.t.sol/DeployHome.t.sol already exercise -- each
        // internally wraps its own vm.startBroadcast/stopBroadcast, so these run sequentially
        // as real broadcasted transactions in this same script's run-latest.json.
        DeployPruv pruvScript = new DeployPruv();
        PruvExecutor executor = pruvScript.deploy(networksJson, paramsJson);

        // AT-190: the fund routes are the executor's own `usdcRoute`/`wrwaRoute` -- every return
        // leg (sub success via wrwaRoute, abort/redeem via usdcRoute, redeem-abort via wrwaRoute)
        // now models a real WithFee PRUV route charging 0.75 USDC per leg to a fee collector, and
        // the executor needs a USDC float to pay it out of (`_approveForRoute` reverts
        // `FeeTokenInsufficient` if its own usdc balance can't cover the quoted fee).
        vm.startBroadcast();
        fundUsdcRoute.setFee(IERC20(address(usdc)), WITHFEE_FEE_AMOUNT, WITHFEE_FEE_COLLECTOR);
        fundWrwaRoute.setFee(IERC20(address(usdc)), WITHFEE_FEE_AMOUNT, WITHFEE_FEE_COLLECTOR);
        usdc.mint(address(executor), EXECUTOR_USDC_FLOAT);
        vm.stopBroadcast();

        DeployHome homeScript = new DeployHome();
        (NavOracleConsumer navOracleConsumer, REXPrimary rexPrimary) =
            homeScript.deploy(networksJson, paramsJson, address(executor));

        // SC13 §2.2: one REXLens per chain. Devnet is single-chain (one anvil), so one deploy
        // covers it; `ops/src/devnet/deploy-devnet.ts` finds it in the broadcast artifact by
        // contract name.
        REXLens lens = new DeployLens().run();

        addrs = DevnetAddresses({
            homeMailbox: address(homeMailbox),
            fundMailbox: address(fundMailbox),
            usdc: address(usdc),
            homeUsdcRoute: address(homeUsdcRoute),
            homeWrwaRoute: address(homeWrwaRoute),
            fundUsdcRoute: address(fundUsdcRoute),
            fundWrwaRoute: address(fundWrwaRoute),
            rwaToken: address(rwaToken),
            testRecipient: address(testRecipient),
            pruvExecutor: address(executor),
            navOracleConsumer: address(navOracleConsumer),
            rexPrimary: address(rexPrimary),
            rexLens: address(lens)
        });

        console.log("DEVNET_HOME_MAILBOX", addrs.homeMailbox);
        console.log("DEVNET_FUND_MAILBOX", addrs.fundMailbox);
        console.log("DEVNET_USDC", addrs.usdc);
        console.log("DEVNET_HOME_USDC_ROUTE", addrs.homeUsdcRoute);
        console.log("DEVNET_HOME_WRWA_ROUTE", addrs.homeWrwaRoute);
        console.log("DEVNET_FUND_USDC_ROUTE", addrs.fundUsdcRoute);
        console.log("DEVNET_FUND_WRWA_ROUTE", addrs.fundWrwaRoute);
        console.log("DEVNET_RWA_TOKEN", addrs.rwaToken);
        console.log("DEVNET_TEST_RECIPIENT", addrs.testRecipient);
        console.log("DEVNET_PRUV_EXECUTOR", addrs.pruvExecutor);
        console.log("DEVNET_NAV_ORACLE_CONSUMER", addrs.navOracleConsumer);
        console.log("DEVNET_REX_PRIMARY", addrs.rexPrimary);
        console.log("DEVNET_REX_LENS", addrs.rexLens);
    }

    function _networksJson(
        address homeMailbox,
        address fundMailbox,
        address usdc,
        address homeUsdcRoute,
        address homeWrwaRoute,
        address fundUsdcRoute,
        address fundWrwaRoute,
        address rwaToken
    ) internal pure returns (string memory) {
        return string.concat(
            '{"defaultFund":"',
            DEVNET_FUND_KEY,
            '","home":{"hyperlaneDomain":',
            vm.toString(uint256(HOME_DOMAIN)),
            ',"contracts":{"mailbox":"',
            vm.toString(homeMailbox),
            '","usdc":"',
            vm.toString(usdc),
            '","usdcWarpRoute":"',
            vm.toString(homeUsdcRoute),
            '","wrwaWarpRoute":"',
            vm.toString(homeWrwaRoute),
            '"}},"fund":{"hyperlaneDomain":',
            vm.toString(uint256(PRUV_DOMAIN)),
            ',"contracts":{"mailbox":"',
            vm.toString(fundMailbox),
            '","usdc":"',
            vm.toString(usdc),
            '","usdcWarpRoute":"',
            vm.toString(fundUsdcRoute),
            '","wrwaWarpRoute":"',
            vm.toString(fundWrwaRoute),
            '","rwaToken":"',
            vm.toString(rwaToken),
            '"}}}'
        );
    }

    /// @dev Numeric defaults mirror config/deploy/testnet-dev.params.json (values already
    /// proven to construct + run by the Forge suite). ADR-025 dropped the keeper role and
    /// requires a `schedule.epochDuration` field instead -- `DeployHome.deploy` derives
    /// `epochStart` as launchpadStart + launchpadPeriod + epochDuration (RULING 8: one full
    /// period after the launchpad closes, not the close instant itself). `key` +
    /// `contracts` are the fund-file half (SC7b-1): the devnet is one fund, named as the
    /// `defaultFund` above so the drift gate actually runs here instead of being skipped.
    /// `rwaConversion` points at a `MockRWAConversion` -- the devnet still deploys no
    /// NavReporter, but `PruvExecutor` (ADR-026) requires a live NAV source regardless.
    function _paramsJson(address rwaToken, address fundWrwaRoute, address homeWrwaRoute, address rwaConversion)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '{"key":"',
            DEVNET_FUND_KEY,
            '","contracts":{"rwaToken":"',
            vm.toString(rwaToken),
            '","fundWrwaRoute":"',
            vm.toString(fundWrwaRoute),
            '","homeWrwaRoute":"',
            vm.toString(homeWrwaRoute),
            '","rwaConversion":"',
            vm.toString(rwaConversion),
            '"},',
            '"rexPrimary":{"minSub":"0","launchpadStart":300,"launchpadPeriod":86400,',
            '"launchpadMinimum":"0","cancelFeeBps":0,"feeRecipient":"${DEPLOYER_ADDRESS}",',
            // I1: the caps must EXCEED epochDuration (3x, mirroring testnet-dev.params.json) --
            // at equality a below-minimum batch is released at the very next scheduled close.
            // SC13 D12: redeemFulfillTimeout must EXCEED pruvExecutor's own (950400, matching
            // testnet-dev/launchpad-demo.params.json's convention) -- 864000 on both sides was
            // the pre-SC13 devnet value and no longer validates against ops' loadDeployParams.
            '"sc3Params":{"minRedeem":"0","redeemCancelFeeBps":0,',
            '"subFulfillTimeout":7776000,"redemptionFeeBps":0,',
            '"redeemFulfillTimeout":950400,"windDownWindow":777600}},',
            '"pruvExecutor":{"subFulfillTimeout":3600,"executorSlippageBps":100,',
            '"redeemFulfillTimeout":864000,"redeemDelay":0,"minRedeemDelay":0},',
            '"navOracleConsumer":{"reporterDomain":',
            vm.toString(uint256(PRUV_DOMAIN)),
            ',"stalenessWindow":3600,"maxNavMoveBps":500},',
            // ADR-029: windowLength == epochDuration reproduces pre-ADR-029 behaviour (the window
            // never closes) -- devnet keeps the same schedule shape it always exercised.
            '"schedule":{"epochDuration":2592000,"windowLength":2592000}}'
        );
    }
}
