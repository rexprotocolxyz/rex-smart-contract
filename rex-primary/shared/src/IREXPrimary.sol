// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice The built subscribe + shared surface of REXPrimary. REXPrimary `is`
/// this, so the compiler enforces conformance. FROZEN (INIT-1).
interface IREXSubscribe {
    event Requested(uint256 id, address owner, uint256 amount);
    event Cancelled(uint256 id, address owner, uint256 amount);
    event SubEpochInitiated(uint64 epochId, uint64 batchId, uint256 netAmount);
    event SubBatchBridged(uint64 batchId, uint256 usdcAmount, bytes32 msgId);
    event SubReturnReceived(uint64 batchId, uint256 amount);
    event SubBatchSettled(uint64 batchId);
    event SubBatchAborted(uint64 batchId);
    event Claimed(uint256 id, address owner, uint256 burned, uint256 payout);

    function requestDeposit(uint256 usdc) external returns (uint256 id);
    function cancelRequest(uint256 id, uint256 amount) external;
    function claim(uint256 id, uint256 amount) external;
    function initiateSubEpoch() external payable;
    function settleSubBatch(uint64 batchId) external;
    function epochSide(uint64 epochId, uint8 class_)
        external
        view
        returns (uint256 totalIn, uint256 matchedOut, uint256 netAmount, uint64 batchId, bool locked);

    /// @dev A stable projection (spec §3.1), `status` as a plain uint8 — never the
    /// internal `Batch` struct. Symmetric with `IREXRedeem.redeemBatch`.
    function subBatch(uint64 batchId)
        external
        view
        returns (uint8 status, uint256 netIn, uint64 accrualStart);
}

/// @notice The redeem surface (spec §3.1). A FROZEN DECLARATION — REXPrimary
/// inherits it at SC5. The reduced `redeemBatch` view is the vault's settlement
/// signal (see docs/references/group-redemption-interface.md); it returns a
/// stable projection (`status` as a plain uint8), never the internal Batch struct.
interface IREXRedeem {
    event RedeemRequested(uint256 id, address owner, uint256 amount);
    event RedeemBatchBridged(uint64 batchId, uint256 wrwaAmount, bytes32 msgId);
    event RedeemEpochAccrued(uint64 epochId, uint64 batchId, uint256 netIn);
    event RedeemBatchSettled(uint64 batchId, uint256 usdcReturned);

    function requestRedeem(uint256 wrwa) external returns (uint256 id);
    function settleRedeemBatch(uint64 batchId) external;
    function redeemBatch(uint64 batchId)
        external
        view
        returns (uint8 status, uint256 netIn, uint64 accrualStart, uint64 deadline);

    /// @notice The redemption fee frozen onto `epochId` by its first requester (0 if none yet).
    function redemptionFeeOf(uint64 epochId) external view returns (uint16);
}

/// @notice The launchpad surface (spec §7.1). FROZEN (shared-v1.2). REXPrimary `is` this.
interface ILaunchpad {
    event LaunchpadDeposited(address owner, uint256 amount);
    event FeeCharged(address payer, uint256 fee);
    event LaunchpadClosed(bool success);
    event Refunded(uint256 id, address owner, uint256 amount);

    function depositToLaunchpad(uint256 usdc) external returns (uint256 id);
    function cancelLaunchpad(uint256 amount) external;
    function closeLaunchpad() external payable;
    function claimLaunchpad(uint256 amount) external;
    function refundLaunchpad(uint256 amount) external;
}

/// @notice The epoch-matching surface (spec §8; ADR-010 switch, ADR-014 volume-only). FROZEN
/// (shared-v1.3). REXPrimary `is` this. Events-only — the matching engine reassigns raw aggregates
/// with no user call of its own, so the indexer derives zones/NAV from these. `matchedUSDC`/
/// `matchedWRWA` are the per-epoch matched volumes; `BatchReleased(kind)` fires when a below-min
/// batch is released past its wait cap (`kind` = RequestKind — subscribe today, redeem at SC5).
interface IREXMatching {
    event MatchingToggled(bool on);
    event MatchingPerformed(uint256 matchedUSDC, uint256 matchedWRWA);
    event BatchReleased(uint64 batchId, uint8 kind, uint256 netIn);
}

/// @notice The access-control + fee-governance surface (spec §7.7 wind-down/shut-down, §10 fees;
/// ADR-007 A1 adjustable fee cap, ADR-008 wind-down/shut-down). FROZEN (shared-v1.7). Events-only;
/// `REXPrimary is IREXGovernance` (wired in SC6a, which emits the fee/keeper/guardian events); the
/// wind-down/shut-down/sweep events are declared here for SC6b.
interface IREXGovernance {
    event WindDownTriggered(uint64 windowEnd);
    event ShutDown();
    event Swept(address indexed token, address indexed to, uint256 amount);
    event FeesProposed(uint16 subCancel, uint16 redeemCancel, uint16 redemption, uint64 effectiveAt);
    event FeesChanged(uint16 subCancel, uint16 redeemCancel, uint16 redemption);
    event FeeCapProposed(uint16 feeCapBps, uint64 effectiveAt);
    event FeeCapChanged(uint16 feeCapBps);
    event KeeperChanged(address keeper);
    event GuardianChanged(address guardian);
}

/// @notice The full REXPrimary call surface — the type consumers import.
interface IREXPrimary is IREXSubscribe, IREXRedeem, ILaunchpad, IREXMatching, IREXGovernance {
    function VERSION() external view returns (string memory);
}
