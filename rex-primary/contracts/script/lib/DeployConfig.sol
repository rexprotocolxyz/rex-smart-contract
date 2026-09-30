// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";

/// @notice Shared config-loading helpers for the REX deploy scripts (`DeployPruv`,
/// `DeployHome`). Wraps `vm.readFile` and the `vm.parseJson*` cheatcodes with typed
/// getters keyed by jq-style JSON path, plus fail-loud sanity-check helpers that revert
/// with custom errors so a misconfigured deploy reverts instead of silently wiring the
/// wrong address.
/// @dev Deploy config lives at the repo root (`config/`), one level above the Foundry
/// root (`contracts/`) -- callers pass repo-root-relative paths (e.g.
/// "../config/networks.json") and `foundry.toml`'s `fs_permissions` must allow reading
/// them (the "./" entry alone does not).
abstract contract DeployConfig is Script {
    /// @dev A deployed contract's immutable getter did not equal the config value it was
    /// constructed from (arg-order swap or wrong JSON path).
    error AddressMismatch(string label, address expected, address actual);
    /// @dev A Hyperlane domain sanity check failed.
    error DomainMismatch(string label, uint32 expected, uint32 actual);
    /// @dev A JSON uint did not fit in uint32 (e.g. a malformed domain value).
    error Uint32Overflow(string path, uint256 value);
    /// @dev A JSON uint did not fit in uint16 (e.g. a malformed bps value).
    error Uint16Overflow(string path, uint256 value);
    /// @dev A JSON uint did not fit in uint64 (e.g. a malformed timeout/window value).
    error Uint64Overflow(string path, uint256 value);
    /// @dev A deployed contract's getter did not equal a hardcoded protocol invariant or a
    /// config value (generic uint256 form -- feeCapBps, token decimals, and similar reads
    /// that are not addresses or Hyperlane domains).
    error UintMismatch(string label, uint256 expected, uint256 actual);

    // ---------------------------------------------------------------------
    // Raw file loading
    // ---------------------------------------------------------------------

    /// @notice Reads a JSON config file at a repo-root-relative path (e.g.
    /// "../config/networks.json" from this Foundry root).
    function readConfig(string memory relativePath) internal view returns (string memory) {
        return vm.readFile(relativePath);
    }

    // ---------------------------------------------------------------------
    // Generic typed getters, keyed by jq-style JSON path (e.g. ".fund.contracts.usdc")
    // ---------------------------------------------------------------------

    function getAddress(string memory json, string memory path) internal pure returns (address) {
        return vm.parseJsonAddress(json, path);
    }

    function getUint(string memory json, string memory path) internal pure returns (uint256) {
        return vm.parseJsonUint(json, path);
    }

    function getUint32(string memory json, string memory path) internal pure returns (uint32) {
        uint256 value = vm.parseJsonUint(json, path);
        if (value > type(uint32).max) revert Uint32Overflow(path, value);
        return uint32(value);
    }

    function getUint16(string memory json, string memory path) internal pure returns (uint16) {
        uint256 value = vm.parseJsonUint(json, path);
        if (value > type(uint16).max) revert Uint16Overflow(path, value);
        return uint16(value);
    }

    function getUint64(string memory json, string memory path) internal pure returns (uint64) {
        uint256 value = vm.parseJsonUint(json, path);
        if (value > type(uint64).max) revert Uint64Overflow(path, value);
        return uint64(value);
    }

    /// @notice Some config fields are JSON *strings* holding a decimal uint256 (e.g. `"0"`),
    /// not JSON numbers -- `vm.parseJsonUint` reverts trying to parse a quoted value. Used
    /// for token-amount fields the config schema deliberately quotes to preserve uint256
    /// precision (e.g. `rexPrimary.minSub` in `config/deploy/testnet-dev.params.json`).
    function getUintString(string memory json, string memory path) internal pure returns (uint256) {
        return vm.parseUint(vm.parseJsonString(json, path));
    }

    /// @notice Some role/recipient fields are shell-style `${VAR_NAME}` placeholders (e.g.
    /// `rexPrimary.feeRecipient` in `config/deploy/testnet-dev.params.json`)
    /// so one env var supplies the same EOA to every role without editing committed JSON.
    /// Resolves the placeholder via `vm.envAddress`; a value not wrapped in `${...}` is
    /// parsed as a literal address instead (a future environment's params file may hardcode
    /// a real address for a role rather than a placeholder).
    function getAddressOrEnv(string memory json, string memory path) internal view returns (address) {
        string memory raw = vm.parseJsonString(json, path);
        bytes memory b = bytes(raw);
        if (b.length > 3 && b[0] == bytes1("$") && b[1] == bytes1("{") && b[b.length - 1] == bytes1("}")) {
            bytes memory name = new bytes(b.length - 3);
            for (uint256 i = 0; i < name.length; ++i) {
                name[i] = b[i + 2];
            }
            return vm.envAddress(string(name));
        }
        return vm.parseAddress(raw);
    }

    // ---------------------------------------------------------------------
    // config/networks.json -- fields `DeployPruv` needs. `DeployHome` reads the rest of
    // this same file's `home.*` shape via the generic getters above.
    // ---------------------------------------------------------------------

    function fundMailbox(string memory networksJson) internal pure returns (address) {
        return getAddress(networksJson, ".fund.contracts.mailbox");
    }

    function fundUsdc(string memory networksJson) internal pure returns (address) {
        return getAddress(networksJson, ".fund.contracts.usdc");
    }

    function fundUsdcWarpRoute(string memory networksJson) internal pure returns (address) {
        return getAddress(networksJson, ".fund.contracts.usdcWarpRoute");
    }

    function fundWrwaWarpRoute(string memory networksJson) internal pure returns (address) {
        return getAddress(networksJson, ".fund.contracts.wrwaWarpRoute");
    }

    function fundRwaToken(string memory networksJson) internal pure returns (address) {
        return getAddress(networksJson, ".fund.contracts.rwaToken");
    }

    function fundRwaConversion(string memory networksJson) internal pure returns (address) {
        return getAddress(networksJson, ".fund.contracts.rwaConversion");
    }

    function homeHyperlaneDomain(string memory networksJson) internal pure returns (uint32) {
        return getUint32(networksJson, ".home.hyperlaneDomain");
    }

    // ---------------------------------------------------------------------
    // config/networks.json -- `home.contracts.*` + `fund.hyperlaneDomain`, the fields
    // `DeployHome` needs (`DeployPruv`'s `fund.contracts.*` + `home.hyperlaneDomain`
    // getters are above).
    // ---------------------------------------------------------------------

    function homeMailbox(string memory networksJson) internal pure returns (address) {
        return getAddress(networksJson, ".home.contracts.mailbox");
    }

    function homeUsdc(string memory networksJson) internal pure returns (address) {
        return getAddress(networksJson, ".home.contracts.usdc");
    }

    function homeUsdcWarpRoute(string memory networksJson) internal pure returns (address) {
        return getAddress(networksJson, ".home.contracts.usdcWarpRoute");
    }

    function homeWrwaWarpRoute(string memory networksJson) internal pure returns (address) {
        return getAddress(networksJson, ".home.contracts.wrwaWarpRoute");
    }

    function fundHyperlaneDomain(string memory networksJson) internal pure returns (uint32) {
        return getUint32(networksJson, ".fund.hyperlaneDomain");
    }

    // ---------------------------------------------------------------------
    // config/deploy/<fund>.params.json -- the per-fund `key` + `contracts` block. These four
    // addresses are per FUND, not per chain: a second fund has its own RWA token, its own
    // RWAConversion NAV source, and its own wRWA warp-route pair. They are read from the fund
    // file so a second fund never has to edit the first fund's config (SC7b-1).
    //
    // `config/networks.json` still carries a copy of the DEFAULT fund's four addresses --
    // `@rex/ops` reads them there for its non-deploy verbs and `services/` mirrors that shape
    // -- so `requireFundMatchesNetworks` is the gate that stops the two copies from drifting
    // apart silently. Only the default fund is duplicated; every other fund lives in its file
    // alone.
    // ---------------------------------------------------------------------

    /// @notice The fund file's own identity, compared against `networks.json`'s `defaultFund`.
    function fundKey(string memory fundJson) internal pure returns (string memory) {
        return vm.parseJsonString(fundJson, ".key");
    }

    function contractsRwaToken(string memory fundJson) internal pure returns (address) {
        return getAddress(fundJson, ".contracts.rwaToken");
    }

    function contractsRwaConversion(string memory fundJson) internal pure returns (address) {
        return getAddress(fundJson, ".contracts.rwaConversion");
    }

    function contractsFundWrwaRoute(string memory fundJson) internal pure returns (address) {
        return getAddress(fundJson, ".contracts.fundWrwaRoute");
    }

    function contractsHomeWrwaRoute(string memory fundJson) internal pure returns (address) {
        return getAddress(fundJson, ".contracts.homeWrwaRoute");
    }

    /// @notice Fail-loud drift gate. When the fund file describes the fund `networks.json`
    /// names as `defaultFund`, its `contracts` block MUST equal the copy still carried there;
    /// a mismatch reverts `AddressMismatch` rather than letting the deploy pick a winner. For
    /// any other fund key this is a no-op -- `networks.json` holds no copy to compare against.
    /// @dev Each field is compared only if `networks.json` actually carries it, so a script
    /// that reads a subset of the four (and a test that supplies a subset) is not forced to
    /// invent the rest. A field absent from the DEFAULT fund's own file is a real error and
    /// reverts inside the fund-file getter.
    function requireFundMatchesNetworks(string memory networksJson, string memory fundJson) internal view {
        if (!vm.keyExistsJson(networksJson, ".defaultFund")) return;
        string memory defaultFund = vm.parseJsonString(networksJson, ".defaultFund");
        if (keccak256(bytes(fundKey(fundJson))) != keccak256(bytes(defaultFund))) return;

        if (vm.keyExistsJson(networksJson, ".fund.contracts.rwaToken")) {
            requireAddressEq(".fund.contracts.rwaToken", fundRwaToken(networksJson), contractsRwaToken(fundJson));
        }
        if (vm.keyExistsJson(networksJson, ".fund.contracts.rwaConversion")) {
            requireAddressEq(
                ".fund.contracts.rwaConversion", fundRwaConversion(networksJson), contractsRwaConversion(fundJson)
            );
        }
        if (vm.keyExistsJson(networksJson, ".fund.contracts.wrwaWarpRoute")) {
            requireAddressEq(
                ".fund.contracts.wrwaWarpRoute", fundWrwaWarpRoute(networksJson), contractsFundWrwaRoute(fundJson)
            );
        }
        if (vm.keyExistsJson(networksJson, ".home.contracts.wrwaWarpRoute")) {
            requireAddressEq(
                ".home.contracts.wrwaWarpRoute", homeWrwaWarpRoute(networksJson), contractsHomeWrwaRoute(fundJson)
            );
        }
    }

    // ---------------------------------------------------------------------
    // config/deploy/<fund>.params.json -- pruvExecutor block. (The rexPrimary /
    // roles / navOracleConsumer blocks in the same file are DeployHome's concern; their
    // token-amount fields are JSON strings and need different parsing.)
    // ---------------------------------------------------------------------

    function pruvSubFulfillTimeout(string memory paramsJson) internal pure returns (uint256) {
        return getUint(paramsJson, ".pruvExecutor.subFulfillTimeout");
    }

    function pruvExecutorSlippageBps(string memory paramsJson) internal pure returns (uint256) {
        return getUint(paramsJson, ".pruvExecutor.executorSlippageBps");
    }

    function pruvRedeemFulfillTimeout(string memory paramsJson) internal pure returns (uint256) {
        return getUint(paramsJson, ".pruvExecutor.redeemFulfillTimeout");
    }

    /// @dev ADR-030: the delay between recording a redeem batch (or the last successful subscribe
    /// deposit) and that batch becoming executable. Owner-settable post-deploy via
    /// `PruvExecutor.setRedeemDelay`; this is only the constructor's initial value.
    function pruvRedeemDelay(string memory paramsJson) internal pure returns (uint64) {
        return getUint64(paramsJson, ".pruvExecutor.redeemDelay");
    }

    /// @dev ADR-030: the immutable floor `setRedeemDelay` cannot go below.
    function pruvMinRedeemDelay(string memory paramsJson) internal pure returns (uint64) {
        return getUint64(paramsJson, ".pruvExecutor.minRedeemDelay");
    }

    function navReporterHeartbeat(string memory paramsJson) internal pure returns (uint256) {
        return getUint(paramsJson, ".navReporter.heartbeatSeconds");
    }

    // ---------------------------------------------------------------------
    // config/deploy/testnet-dev.params.json -- `rexPrimary` / `roles` / `navOracleConsumer`
    // blocks `DeployHome` needs. `minSub` / `launchpadMinimum` / `sc3Params.minRedeem` are
    // JSON *strings* (getUintString); every other numeric field below is a plain JSON
    // number. `rexPrimary.feeRecipient` is a
    // `${VAR_NAME}` placeholder (getAddressOrEnv), not a literal address.
    // ---------------------------------------------------------------------

    function rexPrimaryFeeRecipient(string memory paramsJson) internal view returns (address) {
        return getAddressOrEnv(paramsJson, ".rexPrimary.feeRecipient");
    }

    function rexPrimaryMinSub(string memory paramsJson) internal pure returns (uint256) {
        return getUintString(paramsJson, ".rexPrimary.minSub");
    }

    /// @dev Seconds-from-deploy DELAY, not an absolute timestamp -- the caller must add
    /// `block.timestamp` at broadcast time (REXPrimary reverts `InvalidLaunchpadConfig` if
    /// `launchpadStart_ < block.timestamp`; a committed absolute value would go stale
    /// between commit and deploy).
    function rexPrimaryLaunchpadStartDelay(string memory paramsJson) internal pure returns (uint256) {
        return getUint(paramsJson, ".rexPrimary.launchpadStart");
    }

    function rexPrimaryLaunchpadPeriod(string memory paramsJson) internal pure returns (uint64) {
        return getUint64(paramsJson, ".rexPrimary.launchpadPeriod");
    }

    function rexPrimaryLaunchpadMinimum(string memory paramsJson) internal pure returns (uint256) {
        return getUintString(paramsJson, ".rexPrimary.launchpadMinimum");
    }

    function rexPrimaryCancelFeeBps(string memory paramsJson) internal pure returns (uint16) {
        return getUint16(paramsJson, ".rexPrimary.cancelFeeBps");
    }

    function sc3ParamsMinRedeem(string memory paramsJson) internal pure returns (uint256) {
        return getUintString(paramsJson, ".rexPrimary.sc3Params.minRedeem");
    }

    function sc3ParamsRedeemCancelFeeBps(string memory paramsJson) internal pure returns (uint16) {
        return getUint16(paramsJson, ".rexPrimary.sc3Params.redeemCancelFeeBps");
    }

    function sc3ParamsSubFulfillTimeout(string memory paramsJson) internal pure returns (uint64) {
        return getUint64(paramsJson, ".rexPrimary.sc3Params.subFulfillTimeout");
    }

    function sc3ParamsRedemptionFeeBps(string memory paramsJson) internal pure returns (uint16) {
        return getUint16(paramsJson, ".rexPrimary.sc3Params.redemptionFeeBps");
    }

    function sc3ParamsRedeemFulfillTimeout(string memory paramsJson) internal pure returns (uint64) {
        return getUint64(paramsJson, ".rexPrimary.sc3Params.redeemFulfillTimeout");
    }

    function sc3ParamsWindDownWindow(string memory paramsJson) internal pure returns (uint64) {
        return getUint64(paramsJson, ".rexPrimary.sc3Params.windDownWindow");
    }

    function navOracleConsumerReporterDomain(string memory paramsJson) internal pure returns (uint32) {
        return getUint32(paramsJson, ".navOracleConsumer.reporterDomain");
    }

    function navOracleConsumerStalenessWindow(string memory paramsJson) internal pure returns (uint256) {
        return getUint(paramsJson, ".navOracleConsumer.stalenessWindow");
    }

    function navOracleConsumerMaxNavMoveBps(string memory paramsJson) internal pure returns (uint256) {
        return getUint(paramsJson, ".navOracleConsumer.maxNavMoveBps");
    }

    /// @notice An ALREADY-DEPLOYED `NavOracleConsumer` to bind this deployment to, instead of
    /// deploying a fresh one. `address(0)` -- or the key being absent entirely, which is the
    /// pre-2026-09-09 shape -- means deploy fresh.
    ///
    /// @dev This exists because of a chain of immutables, not as a convenience. `NavReporter.consumer`
    /// is immutable, so a NEW consumer forces a NEW reporter on PRUV; a new reporter has to be
    /// whitelisted on the PRUV mailbox `SenderWhitelistHook` by an external party before it can
    /// dispatch at all, and `roles.reporter` has to be re-pointed. So deploying a consumer whose
    /// bytecode did not change buys nothing and costs an external dependency plus a NAV outage for
    /// as long as the grant takes. Reuse only when the consumer's source is genuinely unchanged:
    /// `deploy` re-asserts all three of its immutables against this file, so a reused consumer
    /// carrying different NAV guards fails the deploy rather than being silently attached.
    function navOracleConsumerReuse(string memory paramsJson) internal view returns (address) {
        if (!vm.keyExistsJson(paramsJson, ".navOracleConsumer.reuseAddress")) return address(0);
        return getAddress(paramsJson, ".navOracleConsumer.reuseAddress");
    }

    /// @dev ADR-025: the epoch calendar's period length, fed into `EpochSchedule`'s constructor
    /// and into `DeployHome`'s derivation of `epochStart` (RULING 8: launchpad close + one full
    /// `epochDuration`, not the launchpad close itself). 30 days in production; testnet may use a
    /// shorter interval to exercise the gate.
    function scheduleEpochDuration(string memory paramsJson) internal pure returns (uint64) {
        return getUint64(paramsJson, ".schedule.epochDuration");
    }

    /// @dev ADR-029: the admissible-close window inside each period, fed into `EpochSchedule`'s
    /// constructor alongside `scheduleEpochDuration`. `windowLength == epochDuration` reproduces
    /// the pre-ADR-029 behaviour (the window never closes).
    function scheduleWindowLength(string memory paramsJson) internal pure returns (uint64) {
        return getUint64(paramsJson, ".schedule.windowLength");
    }

    // ---------------------------------------------------------------------
    // Fail-loud sanity helpers
    // ---------------------------------------------------------------------

    /// @notice Reverts with a descriptive message unless `expected == actual`. For
    /// post-deploy wiring checks (e.g. a deployed contract's immutable getter must equal
    /// the config value it was constructed from).
    function requireAddressEq(string memory label, address expected, address actual) internal pure {
        if (expected != actual) revert AddressMismatch(label, expected, actual);
    }

    /// @notice Reverts unless `expected == actual`. Used for Hyperlane domain sanity checks.
    function requireUint32Eq(string memory label, uint32 expected, uint32 actual) internal pure {
        if (expected != actual) revert DomainMismatch(label, expected, actual);
    }

    /// @notice Reverts unless `expected == actual`. Generic uint256 form for sanity checks
    /// against a hardcoded protocol invariant rather than a config value (e.g. feeCapBps
    /// must be 200, a token's decimals() must be 6).
    function requireUintEq(string memory label, uint256 expected, uint256 actual) internal pure {
        if (expected != actual) revert UintMismatch(label, expected, actual);
    }

    /// @notice ADR-028 D7: replaces the old literal `== 6` decimals checks. Reverts unless
    /// `d` is within the 6-18 range every asset on either chain must satisfy (`PruvExecutor._unit`
    /// enforces the same bound on-chain).
    function requireDecimalsInRange(string memory label, uint8 d) internal pure {
        require(d >= 6 && d <= 18, string.concat(label, ": decimals out of range"));
    }
}
