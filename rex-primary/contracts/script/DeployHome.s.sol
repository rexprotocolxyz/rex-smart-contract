// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {console} from "forge-std/console.sol";
import {DeployConfig} from "./lib/DeployConfig.sol";
import {REXPrimary, SC3Params} from "../src/REXPrimary.sol";
import {NavOracleConsumer} from "../src/NavOracleConsumer.sol";
import {EpochSchedule} from "../src/EpochSchedule.sol";
import {IMailbox, IWarpRoute} from "@rex-shared/IHyperlane.sol";
import {INavOracle} from "@rex-shared/INavOracle.sol";
import {IEpochSchedule} from "@rex-shared/IEpochSchedule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";

/// @notice Deploys `EpochSchedule` and `REXPrimary` on home (Sepolia), plus a `NavOracleConsumer`
/// unless the fund file names an existing one to reuse (`navOracleConsumer.reuseAddress`),
/// from `config/networks.json` (`home.contracts.*` + `fund.hyperlaneDomain`) and
/// a per-fund file (`contracts.homeWrwaRoute`, `rexPrimary.*` / `schedule.*` /
/// `navOracleConsumer.*`), then fail-loud sanity-asserts the
/// deployed wiring before logging both addresses -- plus the PRUV executor address handed in --
/// for `ops post-deploy`
/// (Task 6) to peer REXPrimary <-> PruvExecutor and enroll the NAV reporter. Neither
/// constructor here takes the PRUV executor address directly (it is not a REXPrimary ctor
/// arg -- peering is `BridgeAdapter.enrollRemote`, done post-deploy once both sides exist);
/// this script only threads it through and logs it for that next step.
///
/// Run (from `contracts/`): `PRUV_EXECUTOR=0x... forge script script/DeployHome.s.sol
/// --rpc-url sepolia --broadcast`. A SECOND fund adds
/// `FUND_PARAMS=../config/deploy/<fund>.params.json`.
contract DeployHome is DeployConfig {
    /// @dev The chain-facts file. Overridable because a second HOME CHAIN is a second file
    /// (`config/networks.bsc-testnet.json`), never an edit of the operational one -- 1.3.1 on
    /// Sepolia and staging still read `config/networks.json`. Same shape as `FUND_PARAMS`:
    ///   `NETWORKS=../config/networks.bsc-testnet.json forge script ...`
    string internal constant NETWORKS_PATH = "../config/networks.json";
    string internal constant DEFAULT_FUND_PARAMS = "../config/deploy/testnet-dev.params.json";

    function run() external returns (NavOracleConsumer navOracleConsumer, REXPrimary rexPrimary) {
        address pruvExecutor = vm.envAddress("PRUV_EXECUTOR");
        (navOracleConsumer, rexPrimary) = deploy(
            readConfig(vm.envOr("NETWORKS", NETWORKS_PATH)),
            readConfig(vm.envOr("FUND_PARAMS", DEFAULT_FUND_PARAMS)),
            pruvExecutor
        );
    }

    /// @dev Test seam: the same deploy + sanity-assert logic as `run()`, parameterized on
    /// already-loaded JSON so `test/DeployHome.t.sol` can substitute mock addresses without
    /// touching the real repo config or needing fs write permissions. `pruvExecutor` is not
    /// consumed by either constructor below -- it is only logged, for the operator to hand
    /// to `ops post-deploy` (Task 6).
    function deploy(string memory networksJson, string memory fundJson, address pruvExecutor)
        public
        returns (NavOracleConsumer navOracleConsumer, REXPrimary rexPrimary)
    {
        requireFundMatchesNetworks(networksJson, fundJson);

        address mailbox = homeMailbox(networksJson);
        address usdc = homeUsdc(networksJson);
        address usdcRoute = homeUsdcWarpRoute(networksJson);
        uint32 pruvDomain = fundHyperlaneDomain(networksJson);

        // The wRWA route is per FUND (one route pair per fund token), so it comes from the
        // fund file; USDC and the mailbox are per CHAIN and stay in networks.json.
        address wrwaRoute = contractsHomeWrwaRoute(fundJson);

        uint32 reporterDomain = navOracleConsumerReporterDomain(fundJson);
        uint256 stalenessWindow = navOracleConsumerStalenessWindow(fundJson);
        uint256 maxNavMoveBps = navOracleConsumerMaxNavMoveBps(fundJson);

        uint256 minSub = rexPrimaryMinSub(fundJson);
        // `launchpadStart` in config is a DELAY in seconds from deploy time, not an
        // absolute timestamp (a committed absolute value would go stale between commit and
        // deploy) -- REXPrimary reverts InvalidLaunchpadConfig if launchpadStart_ <
        // block.timestamp, so the real ctor arg is computed here, at broadcast time.
        uint64 launchpadStart = uint64(block.timestamp + rexPrimaryLaunchpadStartDelay(fundJson));
        uint64 launchpadPeriod = rexPrimaryLaunchpadPeriod(fundJson);
        uint256 launchpadMinimum = rexPrimaryLaunchpadMinimum(fundJson);
        uint16 cancelFeeBps = rexPrimaryCancelFeeBps(fundJson);
        address feeRecipient = rexPrimaryFeeRecipient(fundJson);

        SC3Params memory p = SC3Params({
            navOracle: INavOracle(address(0)), // patched below, once NavOracleConsumer deploys
            minRedeem: sc3ParamsMinRedeem(fundJson),
            redeemCancelFeeBps: sc3ParamsRedeemCancelFeeBps(fundJson),
            subFulfillTimeout: sc3ParamsSubFulfillTimeout(fundJson),
            redemptionFeeBps: sc3ParamsRedemptionFeeBps(fundJson),
            redeemFulfillTimeout: sc3ParamsRedeemFulfillTimeout(fundJson),
            windDownWindow: sc3ParamsWindDownWindow(fundJson),
            schedule: IEpochSchedule(address(0)) // patched below, once EpochSchedule deploys
        });

        // An unchanged `NavOracleConsumer` is REUSED across a redeploy when the fund file names one.
        // Its bytecode moving is what forces a new `NavReporter` (that contract's `consumer` is
        // immutable), which in turn needs an external mailbox-whitelist grant on PRUV before it can
        // dispatch -- so a gratuitous new consumer buys nothing and costs a NAV outage. The three
        // immutables are re-asserted below in BOTH paths, so a reused consumer with different NAV
        // guards fails the deploy instead of being silently attached.
        address reuseConsumer = navOracleConsumerReuse(fundJson);
        require(reuseConsumer == address(0) || reuseConsumer.code.length > 0, "reuseAddress has no code");

        // ADR-028 D7: checked here, before construction, so a misconfigured asset fails loud with
        // this script's own message -- REXPrimary's own `_unit` enforces the same 6-18 bound
        // internally and would otherwise revert first with its generic InvalidLaunchpadConfig.
        // wRWA is the SYNTHETIC side of the TREX01 route on home (the real RWA token is native to
        // PRUV) -- per IWarpRoute, a synthetic route IS the ERC20, so decimals() reads directly on
        // the route address, not via wrappedToken().
        requireDecimalsInRange("usdc", IERC20Metadata(usdc).decimals());
        requireDecimalsInRange("wrwaRoute", IERC20Metadata(wrwaRoute).decimals());

        vm.startBroadcast();
        navOracleConsumer = reuseConsumer == address(0)
            ? new NavOracleConsumer(IMailbox(mailbox), reporterDomain, stalenessWindow, maxNavMoveBps)
            : NavOracleConsumer(reuseConsumer);
        p.navOracle = INavOracle(address(navOracleConsumer));
        // ADR-025 / RULING 8: the epoch calendar is its own immutable contract. `epochStart` is
        // derived as the launchpad close PLUS one full `epochDuration`, not the close itself:
        // `closeLaunchpad` neither advances `currentEpochId` nor touches `lastClosedPeriod`, so at
        // `epochStart == launchpadClose`, `periodOf(now)` is already `1 > 0` the instant the
        // launchpad closes and the first depositor after close can immediately trigger epoch 1 --
        // reproducing, for epoch 1, the exact defect the schedule design exists to remove.
        EpochSchedule epochSchedule = new EpochSchedule(
            launchpadStart + launchpadPeriod + scheduleEpochDuration(fundJson),
            scheduleEpochDuration(fundJson),
            scheduleWindowLength(fundJson)
        );
        p.schedule = IEpochSchedule(address(epochSchedule));
        rexPrimary = new REXPrimary(
            IERC20(usdc),
            IMailbox(mailbox),
            IWarpRoute(usdcRoute),
            IWarpRoute(wrwaRoute),
            pruvDomain,
            minSub,
            launchpadStart,
            launchpadPeriod,
            launchpadMinimum,
            cancelFeeBps,
            feeRecipient,
            p
        );
        vm.stopBroadcast();

        // Fail-loud: an arg-order swap or wrong JSON path here must revert the deploy, never
        // hand a silently-mis-wired REXPrimary/NavOracleConsumer to Task 6's post-deploy wiring.
        requireAddressEq("REXPrimary.mailbox", mailbox, address(rexPrimary.mailbox()));
        requireAddressEq("REXPrimary.usdc", usdc, address(rexPrimary.usdc()));
        requireAddressEq("REXPrimary.usdcRoute", usdcRoute, address(rexPrimary.usdcRoute()));
        requireAddressEq("REXPrimary.wrwaRoute", wrwaRoute, address(rexPrimary.wrwaRoute()));
        requireUint32Eq("REXPrimary.pruvDomain", pruvDomain, rexPrimary.pruvDomain());
        requireAddressEq("REXPrimary.schedule", address(epochSchedule), address(rexPrimary.schedule()));
        requireUintEq("EpochSchedule.windowLength", scheduleWindowLength(fundJson), epochSchedule.windowLength());
        // RULING 8: tightened to the launchpad close PLUS one full epochDuration -- a future
        // operator editing config alone (e.g. hand-computing a raw epochStart) cannot
        // re-introduce the instant-close-on-first-depositor defect.
        require(
            epochSchedule.epochStart() >= launchpadStart + launchpadPeriod + epochSchedule.epochDuration(),
            "epochStart before launchpad close plus one period"
        );

        // ADR-027 retired the accrual caps, and with them the I1 guard that kept `maxSubWait`
        // above one cadence -- a cap equal to the period released every batch on its first epoch
        // and silently voided the accrual design. Nothing expires on a clock now, so only the
        // bridge-liveness deadline is left to get wrong, and a zero there would let
        // `recoverStuckBatch` reach a batch that is still in flight.
        require(p.subFulfillTimeout > 0, "subFulfillTimeout must be non-zero");
        requireAddressEq("REXPrimary.feeRecipient", feeRecipient, rexPrimary.feeRecipient());
        requireUintEq("REXPrimary.feeCapBps", 200, rexPrimary.feeCapBps());
        // All three are constructor immutables, so these are tautologies on a fresh deploy and the
        // real check on a reused one: they are what proves the consumer we attached to still carries
        // the NAV guards this config describes.
        requireUint32Eq("NavOracleConsumer.reporterDomain", reporterDomain, navOracleConsumer.reporterDomain());
        requireUintEq("NavOracleConsumer.stalenessWindow", stalenessWindow, navOracleConsumer.stalenessWindow());
        requireUintEq("NavOracleConsumer.maxNavMoveBps", maxNavMoveBps, navOracleConsumer.maxNavMoveBps());

        console.log(
            reuseConsumer == address(0) ? "NavOracleConsumer deployed at:" : "NavOracleConsumer REUSED at:",
            address(navOracleConsumer)
        );
        console.log("EpochSchedule deployed at:", address(epochSchedule));
        console.log("REXPrimary deployed at:", address(rexPrimary));
        console.log("PRUV executor (enroll via ops post-deploy, Task 6):", pruvExecutor);
    }
}
