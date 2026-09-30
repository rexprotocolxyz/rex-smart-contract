// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice PRUV-side executor surface. PruvExecutor `is` this. `handle` is inherited
/// from BridgeAdapter; `abortDeposit` builds at SC4b (below). `executeRedeem`/`abortRedeem`
/// are part of the surface as of shared-v1.6 (SC5b). FROZEN (INIT-1).
interface IPruvExecutor {
    event SubDepositExecuted(uint64 legId, uint256 amount, uint256 shares);
    event SubDepositDeferred(uint64 legId);
    event SubDepositAborted(uint64 legId);

    function executeDeposit(uint64 batchId) external;
    function abortDeposit(uint64 batchId) external;

    // Redeem surface (shared-v1.6, additive). RedeemRecorded.grossAssets is the RECORD-TIME USDC
    // figure — the issuer's first sell-signal; BE/FE watch it directly (SC3 seam #100). It is no
    // longer the funding target: since ADR-030 D7 the gate asks the vault live, so the amount that
    // must actually be in the vault is `redeemTarget(batchId)`, read at the moment of funding.
    event RedeemRecorded(uint64 legId, uint256 shares, uint256 grossAssets);
    event RedeemBatchFulfilled(uint64 legId, uint256 usdcOut);
    event RedeemBatchAborted(uint64 legId);

    function executeRedeem(uint64 batchId) external;
    function abortRedeem(uint64 batchId) external;

    // Redeem delay + oldest-first surface (SC13, ADR-030 D1-D5/D10, additive).
    event RedeemDelaySet(uint64 delay);

    function setRedeemDelay(uint64 delay) external;
    function redeemDelay() external view returns (uint64);
    function oldestOpenRedeem() external view returns (uint64);
    /// @notice ADR-030 D9: the USDC the vault must hold right now to pay this batch.
    function redeemTarget(uint64 batchId) external view returns (uint256);
}
