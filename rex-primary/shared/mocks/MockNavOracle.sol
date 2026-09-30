// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Test stand-in for the home NAV oracle (spec §3.3). Settable, so tests
/// can drive a non-1:1 NAV and a stale timestamp — the fixed 1e18 the skeleton
/// hardcodes cannot. SC3 wires REXPrimary to a real consumer; this unblocks that.
contract MockNavOracle {
    uint256 private _nav;
    uint64 private _lastUpdated;

    constructor(uint256 nav_) {
        _nav = nav_;
        _lastUpdated = uint64(block.timestamp);
    }

    function nav() external view returns (uint256) {
        return _nav;
    }

    function lastUpdated() external view returns (uint64) {
        return _lastUpdated;
    }

    function setNav(uint256 value) external {
        _nav = value;
        _lastUpdated = uint64(block.timestamp);
    }

    /// @dev Set NAV and an explicit timestamp, so a test can force staleness.
    function setNav(uint256 value, uint64 updatedAt) external {
        _nav = value;
        _lastUpdated = updatedAt;
    }
}
