// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Stateless read helper for REXPrimary views moved out of the money-path contract to keep it
/// under EIP-170 (ADR-028 D6, SC13 levers L2/L3). One deployment per chain serves every fund.
interface IREXLens {
    /// @notice Display quote at the current NAV. The fee is the current epoch's frozen redemption fee
    /// once it has a requester, else the live one -- what `_chargeFee` will charge at claim. Does not
    /// include Pruv's own exit fee (the home chain cannot read it).
    function previewRedeem(address rex, uint256 wrwa) external view returns (uint256 usdcOut, uint256 fee);

    /// @notice Why `triggerShutDown` would revert.
    function shutDownBlockers(address rex)
        external
        view
        returns (bool windowElapsed, uint64 outstandingSub, uint64 outstandingRedeem);
}
