// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Home NAV oracle consumer surface (spec §3.3) — the read surface REXPrimary depends on.
/// Additive to /shared. The production `NavOracleConsumer` ingests NAV over the bridge via
/// `handle()` (abi-decoding `(value, srcTimestamp)`), NOT a `setNav` wire; `setNav` is a test-only
/// affordance on `MockNavOracle`, so it is deliberately absent here.
interface INavOracle {
    function nav() external view returns (uint256);
    function lastUpdated() external view returns (uint64);
}
