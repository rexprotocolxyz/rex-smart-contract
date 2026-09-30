// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {DeployHome} from "../script/DeployHome.s.sol";
import {DeployConfig} from "../script/lib/DeployConfig.sol";
import {REXPrimary} from "../src/REXPrimary.sol";
import {NavOracleConsumer} from "../src/NavOracleConsumer.sol";
import {EpochSchedule} from "../src/EpochSchedule.sol";
import "./mocks/MockERC20.sol";
import {IMailbox} from "@rex-shared/IHyperlane.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice Exercises `DeployHome`'s config -> deploy path deterministically: builds an
/// in-memory JSON config pointing at freshly deployed mocks (no real network, no fs writes)
/// and asserts the deployed `REXPrimary` + `NavOracleConsumer` are wired exactly from that
/// config. A second test proves the `${VAR_NAME}` env-placeholder resolution
/// (`config/deploy/testnet-dev.params.json`'s `rexPrimary.feeRecipient` is a
/// shell-style placeholder, not a literal address) against the real `vm.envAddress`
/// cheatcode, not just a literal address path.
contract DeployHomeTest is Test {
    uint32 constant HOME_DOMAIN = 11155111;
    uint32 constant PRUV_DOMAIN = 7336;
    string constant DEFAULT_FUND = "evergreen";

    DeployHome internal script;

    MockMailbox internal mailbox;
    MockERC20 internal usdc;
    MockCollateralWarpRoute internal usdcRoute;
    MockSyntheticWarpRoute internal wrwaRoute;

    address internal keeper = makeAddr("keeper");
    address internal feeRecipient = makeAddr("feeRecipient");
    address internal pruvExecutor = makeAddr("pruvExecutor");

    function setUp() public {
        script = new DeployHome();

        mailbox = new MockMailbox(HOME_DOMAIN);
        usdc = new MockERC20("FakeUSDC", 6);
        usdcRoute = new MockCollateralWarpRoute(IERC20(address(usdc)));
        // Home's wRWA side is the SYNTHETIC leg of the TREX01 route (the real RWA token is
        // native to PRUV) -- a synthetic route IS the ERC20 (IWarpRoute), hence decimals().
        wrwaRoute = new MockSyntheticWarpRoute("wRWA", 6);
    }

    function _networksJson() internal view returns (string memory) {
        return _networksJson(address(mailbox), address(usdc), address(usdcRoute), address(wrwaRoute));
    }

    /// @dev Parameterized form so a test can swap in USDC/wRWA mocks with different decimals
    /// (SC13 §2.5's decimals-range checks) without touching the shared setUp() mocks.
    function _networksJson(address mailbox_, address usdc_, address usdcRoute_, address wrwaRoute_)
        internal
        pure
        returns (string memory)
    {
        return string.concat(
            '{"defaultFund":"',
            DEFAULT_FUND,
            '","fund":{"hyperlaneDomain":',
            vm.toString(uint256(PRUV_DOMAIN)),
            '},"home":{"contracts":{',
            '"mailbox":"',
            vm.toString(mailbox_),
            '","usdc":"',
            vm.toString(usdc_),
            '","usdcWarpRoute":"',
            vm.toString(usdcRoute_),
            '","wrwaWarpRoute":"',
            vm.toString(wrwaRoute_),
            '"}}}'
        );
    }

    uint64 constant EPOCH_DURATION = 2592000;
    uint64 constant WINDOW_LENGTH = 600;

    /// @dev `keeperStr`/`feeRecipientStr` are pre-formatted (either a literal `vm.toString`
    /// address or a `${VAR_NAME}` placeholder) so both tests below can share one builder.
    /// `fundKey`/`homeWrwaRoute_` are the per-fund half: the home wRWA route is per FUND, not
    /// per chain, so it comes from the fund file rather than `networks.json`. `roles.keeper`
    /// is a stale, no-longer-read key kept here only to prove `DeployHome` ignores it now
    /// (ADR-025 dropped the keeper role) rather than reverting on its presence.
    function _paramsJson(
        string memory keeperStr,
        string memory feeRecipientStr,
        string memory fundKey,
        address homeWrwaRoute_
    ) internal pure returns (string memory) {
        return _paramsJson(keeperStr, feeRecipientStr, fundKey, homeWrwaRoute_, address(0), 3600, 500);
    }

    /// @dev The reuse-aware form. `reuseConsumer == address(0)` omits `navOracleConsumer.reuseAddress`
    /// entirely, which is the pre-2026-09-09 file shape and must keep deploying a fresh consumer.
    /// `stalenessWindow_` / `maxNavMoveBps_` are parameterized so a test can point the config at a
    /// reused consumer built with DIFFERENT immutables and prove the deploy refuses it.
    function _paramsJson(
        string memory keeperStr,
        string memory feeRecipientStr,
        string memory fundKey,
        address homeWrwaRoute_,
        address reuseConsumer,
        uint256 stalenessWindow_,
        uint256 maxNavMoveBps_
    ) internal pure returns (string memory) {
        string memory reuseField = reuseConsumer == address(0)
            ? ""
            : string.concat(',"reuseAddress":"', vm.toString(reuseConsumer), '"');
        return string.concat(
            '{"key":"',
            fundKey,
            '","contracts":{"homeWrwaRoute":"',
            vm.toString(homeWrwaRoute_),
            '"},"roles":{"keeper":"',
            keeperStr,
            '"},"rexPrimary":{"minSub":"0","launchpadStart":300,"launchpadPeriod":86400,',
            '"launchpadMinimum":"0","cancelFeeBps":0,"feeRecipient":"',
            feeRecipientStr,
            // I1: the caps must EXCEED epochDuration (3x, mirroring the shipped config) -- at
            // equality a below-minimum batch is released at the very next scheduled close.
            '","sc3Params":{"minRedeem":"0","redeemCancelFeeBps":0,',
            '"subFulfillTimeout":7776000,"redemptionFeeBps":0,',
            '"redeemFulfillTimeout":864000,"windDownWindow":777600}},',
            '"navOracleConsumer":{"reporterDomain":7336,"stalenessWindow":',
            vm.toString(stalenessWindow_),
            ',"maxNavMoveBps":',
            vm.toString(maxNavMoveBps_),
            reuseField,
            "},",
            '"schedule":{"epochDuration":',
            vm.toString(uint256(EPOCH_DURATION)),
            ',"windowLength":',
            vm.toString(uint256(WINDOW_LENGTH)),
            "}}"
        );
    }

    /// @dev The config -> deploy path, deterministically: no real RPC, no real config file,
    /// just the script's own parsing + constructor wiring + sanity asserts against mocks.
    function test_deploy_wiresRexPrimaryAndNavOracleFromConfig() public {
        (NavOracleConsumer navOracleConsumer, REXPrimary rexPrimary) = script.deploy(
            _networksJson(),
            _paramsJson(vm.toString(keeper), vm.toString(feeRecipient), DEFAULT_FUND, address(wrwaRoute)),
            pruvExecutor
        );

        assertEq(rexPrimary.pruvDomain(), PRUV_DOMAIN, "pruvDomain");
        assertTrue(address(rexPrimary.schedule()) != address(0), "schedule");
        assertEq(rexPrimary.feeCapBps(), 200, "feeCapBps");
        assertEq(uint256(rexPrimary.state()), uint256(REXPrimary.LifecycleState.Initialized), "state");
        assertEq(navOracleConsumer.reporterDomain(), PRUV_DOMAIN, "reporterDomain");

        assertEq(address(rexPrimary.mailbox()), address(mailbox), "mailbox");
        assertEq(address(rexPrimary.usdc()), address(usdc), "usdc");
        assertEq(address(rexPrimary.usdcRoute()), address(usdcRoute), "usdcRoute");
        assertEq(address(rexPrimary.wrwaRoute()), address(wrwaRoute), "wrwaRoute");
        assertEq(rexPrimary.feeRecipient(), feeRecipient, "feeRecipient");
        assertEq(address(rexPrimary.navOracle()), address(navOracleConsumer), "navOracle");
        assertEq(EpochSchedule(address(rexPrimary.schedule())).windowLength(), WINDOW_LENGTH, "schedule.windowLength");
    }

    /// @dev SC13 §2.5: the literal `== 6` decimals check is replaced by a 6-18 range, so an
    /// 18-decimal USDC/wRWA pair (a plausible asset on another chain) must deploy cleanly.
    function test_deploy_accepts18DecimalAssets() public {
        MockERC20 usdc18 = new MockERC20("FakeUSDC18", 18);
        MockCollateralWarpRoute usdcRoute18 = new MockCollateralWarpRoute(IERC20(address(usdc18)));
        MockSyntheticWarpRoute wrwaRoute18 = new MockSyntheticWarpRoute("wRWA18", 18);

        DeployHome eighteenScript = new DeployHome();
        (, REXPrimary rexPrimary) = eighteenScript.deploy(
            _networksJson(address(mailbox), address(usdc18), address(usdcRoute18), address(wrwaRoute18)),
            _paramsJson(vm.toString(keeper), vm.toString(feeRecipient), DEFAULT_FUND, address(wrwaRoute18)),
            pruvExecutor
        );

        assertEq(address(rexPrimary.usdc()), address(usdc18), "usdc");
    }

    /// @dev SC13 §2.5: below 6 decimals reverts "decimals out of range" instead of the old
    /// literal `== 6` mismatch error.
    function test_deploy_revertsForOutOfRangeDecimals() public {
        MockERC20 usdc5 = new MockERC20("FakeUSDC5", 5);
        MockCollateralWarpRoute usdcRoute5 = new MockCollateralWarpRoute(IERC20(address(usdc5)));

        vm.expectRevert(bytes("usdc: decimals out of range"));
        script.deploy(
            _networksJson(address(mailbox), address(usdc5), address(usdcRoute5), address(wrwaRoute)),
            _paramsJson(vm.toString(keeper), vm.toString(feeRecipient), DEFAULT_FUND, address(wrwaRoute)),
            pruvExecutor
        );
    }

    /// @dev RULING 8: `epochStart` must land at least one full `epochDuration` AFTER the
    /// launchpad closes, not exactly at the close. At `epochStart == launchpadClose`,
    /// `periodOf(now)` is already `1 > 0` the instant `closeLaunchpad` runs (it neither
    /// advances `currentEpochId` nor touches `lastClosedPeriod`), so the first depositor after
    /// close could immediately trigger epoch 1 -- the exact defect ADR-025 removes.
    function test_epochStartIsAtLeastOneEpochDurationAfterLaunchpadCloses() public {
        (, REXPrimary rexPrimary) = script.deploy(
            _networksJson(),
            _paramsJson(vm.toString(keeper), vm.toString(feeRecipient), DEFAULT_FUND, address(wrwaRoute)),
            pruvExecutor
        );

        EpochSchedule s = EpochSchedule(address(rexPrimary.schedule()));
        assertGe(
            s.epochStart(),
            rexPrimary.launchpadStart() + rexPrimary.launchpadPeriod() + s.epochDuration(),
            "epochStart before launchpad close plus one period"
        );
    }

    /// @dev Proves the `${VAR_NAME}` placeholder gotcha fix: `rexPrimary.feeRecipient` in the
    /// real committed params file is a shell-style placeholder, not a literal address --
    /// `DeployConfig.getAddressOrEnv` must resolve it via `vm.envAddress`, not revert trying
    /// to parse `${DEPLOYER_ADDRESS}` as hex.
    function test_deploy_resolvesEnvPlaceholderAddresses() public {
        address deployer = makeAddr("deployer");
        vm.setEnv("DEPLOYER_ADDRESS", vm.toString(deployer));

        (, REXPrimary rexPrimary) = script.deploy(
            _networksJson(),
            _paramsJson("${DEPLOYER_ADDRESS}", "${DEPLOYER_ADDRESS}", DEFAULT_FUND, address(wrwaRoute)),
            pruvExecutor
        );

        assertEq(rexPrimary.feeRecipient(), deployer, "feeRecipient");
    }

    /// @dev A second fund's `REXPrimary` binds ITS OWN home wRWA route (each fund has its own
    /// warp-route pair), read from its own fund file against an unchanged `networks.json`.
    function test_deploy_secondFundUsesItsOwnHomeWrwaRoute() public {
        MockSyntheticWarpRoute wrwaRouteTwo = new MockSyntheticWarpRoute("wRWA2", 6);

        (, REXPrimary rexPrimary) = script.deploy(
            _networksJson(),
            _paramsJson(vm.toString(keeper), vm.toString(feeRecipient), "fund-two", address(wrwaRouteTwo)),
            pruvExecutor
        );

        assertEq(address(rexPrimary.wrwaRoute()), address(wrwaRouteTwo), "wrwaRoute");
        // Chain facts are shared, so they still come from networks.json.
        assertEq(address(rexPrimary.usdc()), address(usdc), "usdc");
        assertEq(address(rexPrimary.mailbox()), address(mailbox), "mailbox");
    }

    /// @dev The default fund's home wRWA route is duplicated in `networks.json`; drift must
    /// revert the deploy rather than let the two files disagree about the same fund.
    function test_deploy_revertsWhenDefaultFundDriftsFromNetworks() public {
        MockSyntheticWarpRoute wrongRoute = new MockSyntheticWarpRoute("wRWA-wrong", 6);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployConfig.AddressMismatch.selector,
                ".home.contracts.wrwaWarpRoute",
                address(wrwaRoute),
                address(wrongRoute)
            )
        );
        script.deploy(
            _networksJson(),
            _paramsJson(vm.toString(keeper), vm.toString(feeRecipient), DEFAULT_FUND, address(wrongRoute)),
            pruvExecutor
        );
    }

    /// @dev A redeploy binds an EXISTING `NavOracleConsumer` rather than deploying a fresh one,
    /// because `NavReporter.consumer` is immutable: a new consumer forces a new reporter, and a new
    /// reporter cannot dispatch until an external party whitelists it on the PRUV mailbox. The
    /// address the script returns must be the very one named in config -- not merely an equivalent
    /// one -- since that is what `ops post-deploy` records and what the reporter already points at.
    function test_deploy_reusesExistingNavOracleConsumer() public {
        NavOracleConsumer existing = new NavOracleConsumer(IMailbox(address(mailbox)), PRUV_DOMAIN, 3600, 500);

        (NavOracleConsumer navOracleConsumer, REXPrimary rexPrimary) = script.deploy(
            _networksJson(),
            _paramsJson(
                vm.toString(keeper),
                vm.toString(feeRecipient),
                DEFAULT_FUND,
                address(wrwaRoute),
                address(existing),
                3600,
                500
            ),
            pruvExecutor
        );

        assertEq(address(navOracleConsumer), address(existing), "consumer reused");
        assertEq(address(rexPrimary.navOracle()), address(existing), "REXPrimary.navOracle");
        // The schedule is still fresh -- reuse is scoped to the NAV consumer alone.
        assertTrue(address(rexPrimary.schedule()) != address(0), "schedule still deployed");
    }

    /// @dev Reuse must not become a way to silently attach to a consumer carrying different NAV
    /// guards. `stalenessWindow` is immutable, so config saying 3600 while the reused contract holds
    /// 7200 is a real disagreement about when a price counts as stale -- it fails the deploy.
    function test_deploy_revertsWhenReusedConsumerHasDifferentImmutables() public {
        NavOracleConsumer wrong = new NavOracleConsumer(IMailbox(address(mailbox)), PRUV_DOMAIN, 7200, 500);

        vm.expectRevert(
            abi.encodeWithSelector(
                DeployConfig.UintMismatch.selector, "NavOracleConsumer.stalenessWindow", uint256(3600), uint256(7200)
            )
        );
        script.deploy(
            _networksJson(),
            _paramsJson(
                vm.toString(keeper),
                vm.toString(feeRecipient),
                DEFAULT_FUND,
                address(wrwaRoute),
                address(wrong),
                3600,
                500
            ),
            pruvExecutor
        );
    }

    /// @dev A mistyped or stale `reuseAddress` pointing at an EOA must fail loudly here, not decode
    /// empty returndata further down.
    function test_deploy_revertsWhenReuseAddressHasNoCode() public {
        vm.expectRevert(bytes("reuseAddress has no code"));
        script.deploy(
            _networksJson(),
            _paramsJson(
                vm.toString(keeper),
                vm.toString(feeRecipient),
                DEFAULT_FUND,
                address(wrwaRoute),
                makeAddr("notAContract"),
                3600,
                500
            ),
            pruvExecutor
        );
    }

    /// @dev Absent key == deploy fresh. This is the pre-2026-09-09 file shape, and every existing
    /// fund params file still has it, so the default must not change.
    function test_deploy_withoutReuseKeyDeploysAFreshConsumer() public {
        (NavOracleConsumer first,) = script.deploy(
            _networksJson(),
            _paramsJson(vm.toString(keeper), vm.toString(feeRecipient), DEFAULT_FUND, address(wrwaRoute)),
            pruvExecutor
        );
        (NavOracleConsumer second,) = script.deploy(
            _networksJson(),
            _paramsJson(vm.toString(keeper), vm.toString(feeRecipient), DEFAULT_FUND, address(wrwaRoute)),
            pruvExecutor
        );

        assertTrue(address(first) != address(second), "two runs must not share a consumer");
    }
}
