// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC1155/ERC1155.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "@openzeppelin/contracts/utils/Pausable.sol";
import "./BridgeAdapter.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/Wire.sol";
import "@rex-shared/Errors.sol";
import "./libraries/State.sol";
import "@rex-shared/Receipt.sol";
import {IREXSubscribe, ILaunchpad, IREXMatching, IREXRedeem, IREXGovernance} from "@rex-shared/IREXPrimary.sol";
import {INavOracle} from "@rex-shared/INavOracle.sol";
import {IEpochSchedule} from "@rex-shared/IEpochSchedule.sol";

struct SC3Params {
    INavOracle navOracle;
    uint256 minRedeem;
    uint16 redeemCancelFeeBps;
    uint16 redemptionFeeBps; // SC5a: fee on USDC redeem proceeds @ claim
    uint64 redeemFulfillTimeout; // SC5a: indicative deadline for the redeemBatch view (PRUV holds the authoritative one)
    // ADR-027: the home-side bridge-liveness deadline for a subscribe batch, mirroring
    // `PruvExecutor.subFulfillTimeout`. It replaces `maxSubWait` in `recoverStuckBatch` only --
    // the accrual caps themselves went with the lock they used to excuse.
    uint64 subFulfillTimeout;
    uint64 windDownWindow; // SC6b: redeem grace period once wind-down is triggered
    // SC11/ADR-025: the epoch calendar. In the struct, not a fourteenth positional parameter --
    // SC3Params exists to keep the constructor off the codegen stack limit.
    IEpochSchedule schedule;
}

/// @notice Home-chain entrypoint. A holder's position IS their ERC-1155 balance of
/// `SUB_EPOCH|epochId` (ADR-013) — there is no per-request struct, so the epoch is
/// O(1) aggregates and settlement never walks a queue.
contract REXPrimary is
    ERC1155,
    BridgeAdapter,
    Pausable,
    IREXSubscribe,
    IREXRedeem,
    ILaunchpad,
    IREXMatching,
    IREXGovernance
{
    using SafeERC20 for IERC20;

    /// @notice ADR-011: no upgradeable proxy — logic changes ship as a new deployment.
    /// The per-version deployment registry (BE5) reads this to record one entry per version.
    string public constant VERSION = "1.4.0";

    /// @notice Pool lifecycle (spec §5). `Initialized` is the launch window; close
    /// branches to `EpochBased` (raised ≥ minimum) or `LaunchpadFail`.
    /// `WindDown`/`ShutDown` are reserved for SC6.
    enum LifecycleState {
        Initialized,
        EpochBased,
        LaunchpadFail,
        WindDown,
        ShutDown
    }

    /// @notice SC6a: adjustable cap validated against every fee bps at deploy time (Task 6 adds
    /// a timelocked setter). Set to 200 (2%) at construction, before validation runs.
    uint16 public feeCapBps;

    /// @notice SC6a Task 6 (Art 8.2 honest fees): `setFees`/`setFeeCap` proposals only take
    /// effect this long after proposing, so a public `FeesProposed`/`FeeCapProposed` event
    /// gives users advance notice of any change.
    uint64 public constant CONFIG_TIMELOCK = 48 hours;

    /// @dev How far out the NEXT close may sit after a schedule swap. `applySchedule` refuses a new
    /// calendar whose `dueAt(lastClosedPeriod + 1)` is beyond this, because `lastClosedPeriod`
    /// indexes the OLD grid and a coarser new grid can push that moment decades away with no setter
    /// to rebase it and no later swap able to recover -- a permanent, silent brick of the only path
    /// funds take to Pruv. A year is far wider than any real calendar change needs and still
    /// refuses the brick decisively.
    uint64 public constant SCHEDULE_SWAP_HORIZON = 365 days;

    struct PendingFees {
        uint16 subCancel;
        uint16 redeemCancel;
        uint16 redemption;
        uint64 effectiveAt;
        bool set;
    }

    PendingFees internal _pendingFees;
    uint16 internal _pendingCap;
    uint64 internal _pendingCapAt;
    bool internal _pendingCapSet;

    /// @notice The epoch calendar (ADR-025). Storage, not immutable: the calendar's SHAPE is
    /// governable behind `CONFIG_TIMELOCK` (`setSchedule`/`applySchedule`) because a schedule says
    /// WHEN, never HOW MUCH -- it cannot misprice and cannot move funds. That is the SAFETY half
    /// only: a coarsening swap could otherwise strand `lastClosedPeriod` permanently, so
    /// `applySchedule` guards it (see there).
    IEpochSchedule public schedule;
    /// @dev The period we last closed an epoch in. Lives HERE, not in the schedule: a swap must
    /// change the calendar's SHAPE and never our POSITION in it (ADR-025 decision 4, spec 1.3).
    /// It is also why a skipped period is a genuine skip -- the floor compares a period DERIVED
    /// FROM TIME against the period last closed, so nothing accumulates into a burst.
    uint64 public lastClosedPeriod;

    struct PendingSchedule {
        address schedule;
        uint64 effectiveAt;
        bool exists;
    }

    PendingSchedule internal _pendingSchedule;

    event ScheduleProposed(address schedule, uint64 effectiveAt);
    event ScheduleChanged(address schedule);

    IERC20 public immutable usdc;
    IWarpRoute public immutable usdcRoute;
    IWarpRoute public immutable wrwaRoute;
    /// @dev ADR-028 D1/D3: one micro-unit (1e-6) of each asset in its local units, read from the token.
    /// Internal to save bytes; deploy checks read the tokens' own `decimals()`.
    uint256 internal immutable usdcUnit;
    uint256 internal immutable wrwaUnit;
    uint32 public immutable pruvDomain;
    /// @dev Pruv's minimum subscription. The skeleton deploys 0, so every residual
    /// bridges immediately; a non-zero value exercises the accrual branch (§7.4 step 4).
    uint256 public immutable minSub;

    /// @notice Pool lifecycle (spec §5, ADR-008). Only `EpochBased` admits subscribe.
    LifecycleState public state;
    /// @dev Launch window — immutable, no setters (ADR-011). feeRecipient likewise immutable;
    /// cancelFeeBps is governable storage (SC6a).
    uint64 public immutable launchpadStart;
    uint64 public immutable launchpadPeriod;
    uint256 public immutable launchpadMinimum;
    uint16 public cancelFeeBps;
    address public immutable feeRecipient;

    INavOracle public immutable navOracle;
    uint256 public immutable minRedeem;
    uint16 public redeemCancelFeeBps;
    uint64 public immutable subFulfillTimeout;
    uint16 public redemptionFeeBps;
    uint64 public immutable redeemFulfillTimeout;
    /// @notice SC6b: redeem grace period once wind-down is triggered (spec §5/SC6b lifecycle).
    uint64 public immutable windDownWindow;
    /// @notice SC6b: block.timestamp of `triggerWindDown` (later task); 0 while not wound down.
    uint64 public windDownStart;
    /// @notice SC6a circuit breaker: may `pause()` the four capital-inflow entrypoints (never
    /// exit/claim/cancel/settle/refund/handle). Zero address (nobody can pause) until `setGuardian`.
    address public guardian;

    /// @dev keyed by the receipt id itself; `epochSide(epochId, class)` is the spec-shaped view
    mapping(uint256 => EpochSide) internal epochSideById;
    /// @dev raw storage stays internal; `subBatch(batchId)` is the stable §3.1 projection and
    /// `batchLeg(batchId, false)` a flat diagnostic — neither leaks the provisional `Batch` struct.
    mapping(uint64 => Batch) internal _subBatch;

    uint64 public currentEpochId;
    uint64 public nextSubBatchId;
    uint64 public openSubBatchId;
    mapping(uint64 => Batch) internal _redeemBatch;
    uint64 public nextRedeemBatchId;
    uint64 public openRedeemBatchId;
    /// @notice SC6b: count of subscribe/redeem batches that have left {Accumulating, Bridged}
    /// (reached Settled, Released, or Aborted), bumped exactly once per batch at its terminal
    /// write. Feeds the shut-down gate (later task) via `outstandingSubBatches`/
    /// `outstandingRedeemBatches` below -- shut-down must refuse while either leg still has a
    /// batch holding user funds.
    uint64 internal subBatchesTerminated;
    uint64 internal redeemBatchesTerminated;
    /// @notice net USDC returned from Fulfilled redeem batches, awaiting claim (SC5a). The USDC analogue of settledUnclaimed.
    uint256 public settledRedeemUSDC;
    /// @dev wRWA already owed to a settled-but-unclaimed batch; excluded from the
    /// rendezvous check in `_onInstruction` so a later batch's arriving instruction
    /// cannot be satisfied by an earlier batch's unclaimed pot.
    uint256 public settledUnclaimed;
    /// @notice wRWA escrowed by redeemers, still held. Reserved OUT of the subscribe rendezvous check
    /// so a redeemer's wRWA can never satisfy a subscribe batch's return (D6). Decremented on redeem
    /// cancel, when the net redeem leg bridges, and on a Released redeem claim.
    /// @dev ADR-024 D5 demanded this reserve be re-argued, not deleted by association with matching.
    /// It is KEPT on its own mechanism: a subscribe batch's wRWA return must be credited to
    /// subscribers, never borrowed from wRWA sitting in escrow for redeemers (spec section 14) --
    /// a hazard that exists with zero matching. It is also a term in `_reservedBalance`, which
    /// `sweep` and `recoverStuckBatch` depend on.
    uint256 public liveRedeemEscrow;
    /// @notice USDC escrowed across every open request (subscribe + launchpad), still held. The
    /// USDC-leg analogue of `liveRedeemEscrow`. Invariant: `usdc.balanceOf(address(this)) >=
    /// heldEscrowUSDC` always; abort recovery (SC4a) detects unlocked collateral via the gap.
    uint256 public heldEscrowUSDC;
    /// @notice Per-leg replay latch (SC4a Task 4, constitution Art 4.1): keyed by
    /// `keccak256(legId, kind)`, checked FIRST in `_onInstruction` — before any status guard —
    /// so a duplicate delivery of an already-processed leg is a silent no-op. Set only after
    /// that leg's processing fully succeeds, so a reverted (not-yet-processable) delivery never
    /// latches and stays re-processable.
    mapping(bytes32 => bool) internal processedLeg;

    modifier onlyGuardian() {
        if (msg.sender != guardian) revert NotGuardian();
        _;
    }

    constructor(
        IERC20 stablecoin,
        IMailbox mailbox,
        IWarpRoute usdcRoute_,
        IWarpRoute wrwaRoute_,
        uint32 pruvDomain_,
        uint256 minSub_,
        uint64 launchpadStart_,
        uint64 launchpadPeriod_,
        uint256 launchpadMinimum_,
        uint16 cancelFeeBps_,
        address feeRecipient_,
        SC3Params memory p
    ) ERC1155("") BridgeAdapter(mailbox) {
        feeCapBps = 200;
        usdc = stablecoin;
        usdcUnit = _unit(address(stablecoin));
        wrwaUnit = _unit(address(wrwaRoute_));
        usdcRoute = usdcRoute_;
        wrwaRoute = wrwaRoute_;
        pruvDomain = pruvDomain_;
        minSub = minSub_;
        currentEpochId = 1;
        nextSubBatchId = 1;

        if (cancelFeeBps_ > feeCapBps) revert FeeCapExceeded();
        if (
            launchpadStart_ < block.timestamp || launchpadPeriod_ == 0 || feeRecipient_ == address(0)
                || feeRecipient_ == address(this) || launchpadMinimum_ < minSub_
        ) revert InvalidLaunchpadConfig();
        launchpadStart = launchpadStart_;
        launchpadPeriod = launchpadPeriod_;
        launchpadMinimum = launchpadMinimum_;
        cancelFeeBps = cancelFeeBps_;
        feeRecipient = feeRecipient_;
        state = LifecycleState.Initialized;

        if (p.redeemCancelFeeBps > feeCapBps) revert FeeCapExceeded();
        if (address(p.navOracle) == address(0)) revert InvalidLaunchpadConfig();
        navOracle = p.navOracle;
        // The constructor takes the initial calendar DIRECTLY while only the setter is timelocked:
        // without that split the contract would be dead for CONFIG_TIMELOCK after deployment.
        if (address(p.schedule) == address(0)) revert InvalidLaunchpadConfig();
        schedule = p.schedule;
        minRedeem = p.minRedeem;
        redeemCancelFeeBps = p.redeemCancelFeeBps;

        if (p.redemptionFeeBps > feeCapBps) revert FeeCapExceeded();
        // Guarded HERE, not only in the deploy script: a zero would make every bridged subscribe
        // batch instantly `recoverStuckBatch`-able, and a live deploy by raw `cast` bypasses the
        // script's asserts entirely (the way NavReporter was deployed in 2026-08).
        if (p.subFulfillTimeout == 0) revert InvalidLaunchpadConfig();
        subFulfillTimeout = p.subFulfillTimeout;
        redemptionFeeBps = p.redemptionFeeBps;
        redeemFulfillTimeout = p.redeemFulfillTimeout;
        windDownWindow = p.windDownWindow;
        nextRedeemBatchId = 1;
    }

    function _unit(address token) internal view returns (uint256) {
        uint8 d = IERC20Metadata(token).decimals();
        if (d < 6 || d > 18) revert InvalidLaunchpadConfig();
        return 10 ** (d - 6);
    }

    /// @dev ADR-028 D5: every amount that can reach a batch total is a whole micro-unit, so the wire
    /// conversion is exact and no dust is created.
    function _requireQuantized(uint256 amount, uint256 unit) internal pure {
        if (amount % unit != 0) revert AmountNotQuantized();
    }

    /// @notice Spec §3.1 view — encodes the id and reads the one aggregate map.
    function epochSide(uint64 epochId, uint8 class_)
        external
        view
        override
        returns (uint256 totalIn, uint256 matchedOut, uint256 netAmount, uint64 batchId, bool locked)
    {
        EpochSide storage s = epochSideById[encodeId(class_, epochId)];
        // `matchedOut` is a permanent 0: matching was removed (ADR-024) but this five-tuple is a
        // FROZEN signature in shared/src/IREXPrimary.sol, so the shape is kept and the value is
        // honest -- there is no matched amount.
        return (s.totalIn, 0, s.netAmount, s.batchId, s.locked);
    }

    /// @notice Spec §3.1 view — a stable projection of a subscribe batch. `status` is a
    /// plain `uint8` (never the internal `BatchStatus`/`Batch`, both provisional), so the
    /// frozen ABI cannot shift when SC3/SC5 add fields; symmetric with `redeemBatch`.
    function subBatch(uint64 batchId)
        external
        view
        override
        returns (uint8 status, uint256 netIn, uint64 accrualStart)
    {
        return _batchCore(_subBatch[batchId]);
    }

    /// @dev Shared prefix of `subBatch`/`redeemBatch`'s tuple -- both external signatures/selectors
    /// are unchanged, only the identical (status, netIn, accrualStart) prefix is factored out.
    function _batchCore(Batch storage b) internal view returns (uint8, uint256, uint64) {
        return (uint8(b.status), b.netIn, b.accrualStart);
    }

    /// @dev Shared body for `batchLeg` -- both sub and redeem batches share this (identical) body.
    function _batchLeg(Batch storage b) internal view returns (bytes32, bytes32, uint256, bool) {
        return (b.leg.tokenMsgId, b.leg.instrMsgId, b.returnedAmount, b.leg.returnReceived);
    }

    /// @notice Diagnostic view of a batch's bridge leg: the two message ids, the pot recorded on the
    /// return, and whether the return has arrived. NOT part of the frozen `/shared` surface.
    function batchLeg(uint64 batchId, bool isRedeem)
        external
        view
        returns (bytes32 tokenMsgId, bytes32 instrMsgId, uint256 returnedAmount, bool returnReceived)
    {
        return _batchLeg(isRedeem ? _redeemBatch[batchId] : _subBatch[batchId]);
    }

    /// @notice Spec §3.1 redeem projection (frozen). `deadline` is INDICATIVE (home clock + timeout);
    /// the authoritative one is on PRUV (§7.5). 0 until the batch bridges.
    function redeemBatch(uint64 batchId)
        external
        view
        override
        returns (uint8 status, uint256 netIn, uint64 accrualStart, uint64 deadline)
    {
        Batch storage b = _redeemBatch[batchId];
        (status, netIn, accrualStart) = _batchCore(b);
        deadline = b.bridgedAt == 0 ? 0 : b.bridgedAt + redeemFulfillTimeout;
    }

    /// @notice SC6b: subscribe batches created but not yet terminal (Settled/Released/Aborted).
    /// `nextSubBatchId - 1` is the count ever created (ids start at 1, ctor-set) -- checked 0.8
    /// arithmetic reverts here if a batch were ever double-counted into `subBatchesTerminated`.
    function outstandingSubBatches() public view returns (uint64) {
        return (nextSubBatchId - 1) - subBatchesTerminated;
    }

    /// @notice SC6b: the redeem-leg analogue of `outstandingSubBatches`.
    function outstandingRedeemBatches() public view returns (uint64) {
        return (nextRedeemBatchId - 1) - redeemBatchesTerminated;
    }

    /// @inheritdoc IREXRedeem
    function redemptionFeeOf(uint64 epochId) external view override returns (uint16) {
        return epochSideById[encodeId(CLASS_RED_EPOCH, epochId)].redemptionFeeBps;
    }

    /// @dev Shared guard for `settleSubBatch`/`settleRedeemBatch`: the batch must be Bridged, and
    /// its return leg must have already recorded (`_onInstruction`) before it can settle.
    function _requireBridgedReceived(Batch storage b) internal view {
        if (b.status != BatchStatus.Bridged) revert InvalidState();
        if (!b.leg.returnReceived) revert NotReadyToExecute();
    }

    /// @notice Flip a redeem batch to Settled once its return has recorded (spec §7.5/§7.6).
    /// @dev The USDC/wRWA pot is credited at RECORD time (`_onInstruction`'s `Redeem`/
    /// `RedeemAborted` branches), NOT here: redeem batches are PARALLEL (no single-in-flight), so
    /// crediting only on settle would leave a recorded-but-unsettled batch's return sitting in
    /// the raw balance uncounted by any reserve, letting a second in-flight batch's rendezvous
    /// "borrow" it (spec §14). This function only flips status and emits -- a redeem batch never
    /// reaches `Aborted` (only `Settled`, disambiguated by `Leg.retKind`), unlike `SubAborted`
    /// (settled inline in `_onInstruction`, no separate step).
    function settleRedeemBatch(uint64 batchId) external override nonReentrant {
        Batch storage b = _redeemBatch[batchId];
        _requireBridgedReceived(b);
        b.status = BatchStatus.Settled;
        redeemBatchesTerminated++;
        emit RedeemBatchSettled(batchId, b.leg.retKind == RequestKind.Redeem ? b.returnedAmount : 0);
    }

    /// @dev Shared gate for `depositToLaunchpad`/`cancelLaunchpad`: both only admit calls inside
    /// the launch window.
    function _requireLaunchpadOpen() internal view {
        if (block.timestamp < launchpadStart || block.timestamp >= launchpadStart + launchpadPeriod) {
            revert LaunchpadNotOpen();
        }
    }

    /// @dev Shared by `depositToLaunchpad`/`requestDeposit`: escrow the USDC then mint the receipt
    /// 1:1 against it. Mint LAST -- it calls `onERC1155Received` on a contract receiver.
    function _escrowAndMintUsdc(uint256 id, uint256 usdcAmount) internal {
        _requireQuantized(usdcAmount, usdcUnit);
        usdc.safeTransferFrom(msg.sender, address(this), usdcAmount);
        heldEscrowUSDC += usdcAmount;
        epochSideById[id].totalIn += usdcAmount;
        _mint(msg.sender, id, usdcAmount, "");
    }

    /// @notice Deposit USDC during the launch window; mint LAUNCHPAD receipts 1:1 (spec §7.1).
    function depositToLaunchpad(uint256 usdcAmount) external override nonReentrant whenNotPaused returns (uint256 id) {
        if (usdcAmount == 0) revert ZeroAmount();
        _requireLaunchpadOpen();
        id = encodeId(CLASS_LAUNCHPAD, LAUNCHPAD_ID);
        _escrowAndMintUsdc(id, usdcAmount);
        emit LaunchpadDeposited(msg.sender, usdcAmount);
    }

    /// @dev Shared by `cancelLaunchpad`/`refundLaunchpad`: burn the launchpad receipt, release its
    /// escrow reservation, and return its id for the caller's own transfer/event.
    function _burnLaunchpad(uint256 amount) internal returns (uint256 id) {
        _requireQuantized(amount, usdcUnit);
        id = encodeId(CLASS_LAUNCHPAD, LAUNCHPAD_ID);
        _burn(msg.sender, id, amount);
        epochSideById[id].totalIn -= amount;
        heldEscrowUSDC -= amount;
    }

    /// @notice Cancel during the launch window: burn receipts, refund USDC minus the cancel fee (§10).
    function cancelLaunchpad(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _requireLaunchpadOpen();
        uint256 id = _burnLaunchpad(amount);
        uint256 net = _chargeFee(amount, cancelFeeBps, usdc);
        usdc.safeTransfer(msg.sender, net);
        emit Cancelled(id, msg.sender, amount);
    }

    /// @dev Send `bps` of `gross` in `token` to `feeRecipient`; return the net owed to the caller.
    /// Unifies the cancel/redeem-cancel/redemption fee sites (spec §10, ADR-014) — they differ only
    /// in the bps source and the token, never in shape.
    function _chargeFee(uint256 gross, uint16 bps, IERC20 token) internal returns (uint256 net) {
        uint256 fee = Math.mulDiv(gross, bps, 10_000);
        if (fee > 0) {
            token.safeTransfer(feeRecipient, fee);
            emit FeeCharged(msg.sender, fee);
        }
        net = gross - fee;
    }

    /// @notice Permissionless, deadline-gated, idempotent close (spec §7.1). Branches by state:
    /// raised >= minimum -> EpochBased + bridge (Task 5); else -> LaunchpadFail.
    function closeLaunchpad() external payable override nonReentrant {
        if (state != LifecycleState.Initialized) revert AlreadyClosed();
        if (block.timestamp < launchpadStart + launchpadPeriod) revert LaunchpadNotClosed();

        // Snapshot before any branch so every exit refunds unspent native — only the
        // success-bridge path consumes gas, but a caller who over-funds fail/vacuous is
        // still made whole (no-stranded-funds).
        uint256 balanceBefore = address(this).balance - msg.value;
        uint256 id = encodeId(CLASS_LAUNCHPAD, LAUNCHPAD_ID);
        uint256 raised = epochSideById[id].totalIn;

        if (raised < launchpadMinimum) {
            state = LifecycleState.LaunchpadFail;
            emit LaunchpadClosed(false);
        } else if (raised == 0) {
            // vacuous success — only reachable when launchpadMinimum == 0; nothing to bridge.
            state = LifecycleState.EpochBased;
            emit LaunchpadClosed(true);
        } else {
            state = LifecycleState.EpochBased;
            EpochSide storage s = epochSideById[id];
            s.netAmount = raised;
            s.locked = true;

            uint64 batchId = nextSubBatchId++;
            Batch storage b = _subBatch[batchId];
            b.accrualStart = uint64(block.timestamp);
            b.netIn = raised;
            s.batchId = batchId;

            // No price here: ADR-026 (amended -- `closeLaunchpad` is a third `_bridgeBatch` call
            // site the ADR's site list missed). `navAtInitiate` is now only ECHOED on PRUV
            // (`PruvExecutor` stores it and reflects it into the return messages; the deposit floor
            // reads the local price), so this read was load-bearing before the executor went local
            // and is inert after it. Reading it here would let a NAV relay outage block a
            // permissionless, deadline-gated state transition -- exactly the failure D2 removed
            // from `initiateSubEpoch`. Every other quantity in this function is USDC-on-USDC.
            b.leg = _bridgeBatch(b, batchId, usdcRoute, usdc, 0, false);
            emit LaunchpadClosed(true);
            emit SubBatchBridged(batchId, raised, b.leg.instrMsgId);
        }

        _refundNative(balanceBefore);
    }

    /// @notice After LaunchpadFail: burn receipts, refund 100% USDC (no fee, no bridge — spec §7.1).
    function refundLaunchpad(uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        if (state != LifecycleState.LaunchpadFail) revert WrongLifecycleState();
        uint256 id = _burnLaunchpad(amount);
        usdc.safeTransfer(msg.sender, amount);
        emit Refunded(id, msg.sender, amount);
    }

    /// @dev Shared gate reused by `requestRedeem`/`initiateSubEpoch`/`releaseStaleRedeemBatch`: the
    /// redeem book stays open through wind-down (spec §7.7 step 3), so all three admit either state.
    function _requireEpochOpenOrWindDown() internal view {
        if (state != LifecycleState.EpochBased && state != LifecycleState.WindDown) revert WrongLifecycleState();
    }

    /// @dev Shared gate reused by `requestDeposit`/`initiateSubEpoch`'s WrongLifecycleState checks.
    function _requireEpochBased() internal view {
        if (state != LifecycleState.EpochBased) revert WrongLifecycleState();
    }

    /// @notice Escrow USDC and mint `SUB_EPOCH|currentEpochId` receipts 1:1 with it.
    function requestDeposit(uint256 usdcAmount) external override nonReentrant whenNotPaused returns (uint256 id) {
        _requireEpochBased();
        if (usdcAmount == 0) revert ZeroAmount();
        id = encodeId(CLASS_SUB_EPOCH, currentEpochId);
        _escrowAndMintUsdc(id, usdcAmount);

        emit Requested(id, msg.sender, usdcAmount);
    }

    /// @notice Escrow wRWA and mint `RED_EPOCH|currentEpochId` receipts 1:1 (spec §7.3). The redeem
    /// book is always-open; the position joins this epoch's netting (matching = SC3b).
    function requestRedeem(uint256 wrwa) external override nonReentrant whenNotPaused returns (uint256 id) {
        _requireEpochOpenOrWindDown();
        if (wrwa == 0) revert ZeroAmount();
        id = encodeId(CLASS_RED_EPOCH, currentEpochId);

        _requireQuantized(wrwa, wrwaUnit);
        IERC20(address(wrwaRoute)).safeTransferFrom(msg.sender, address(this), wrwa);
        EpochSide storage e = epochSideById[id];
        // Art 8.2: the epoch's first requester freezes the live rate onto it, so a later
        // owner-raised fee (Task 6, 48h-timelocked) can never retroactively charge a rate this
        // holder never saw at request time; a legitimate 0 rate is snapshotted just as faithfully.
        if (e.totalIn == 0) e.redemptionFeeBps = redemptionFeeBps;
        e.totalIn += wrwa;
        liveRedeemEscrow += wrwa; // reserve: redeemer wRWA must not satisfy a subscribe return (D6)
        _mint(msg.sender, id, wrwa, "");

        emit RedeemRequested(id, msg.sender, wrwa);
    }

    /// @notice Burn receipts and take the USDC back (net of the cancel fee), while the epoch is still unlocked.
    /// @dev No owner check: the ERC-1155 balance is the authority (ADR-013 retires
    /// `NotRequestOwner`), so `_burn` reverts if the caller does not hold `amount`.
    /// @dev Refund is net of the §7.2/§10 cancellation fee (`_chargeFee` → `FeeCharged`),
    /// the same fee `cancelLaunchpad` withholds.
    function cancelRequest(uint256 id, uint256 amount) external override nonReentrant {
        if (amount == 0) revert ZeroAmount();
        // Launchpad receipts must exit via cancelLaunchpad (which charges the fee, spec §10);
        // this fee-free subscribe path must not touch them.
        if (classOf(id) == CLASS_LAUNCHPAD) revert InvalidState();
        _requireQuantized(amount, classOf(id) == CLASS_RED_EPOCH ? wrwaUnit : usdcUnit);
        EpochSide storage s = epochSideById[id];
        // ADR-027. `locked` is not the question -- the question is whether the money is still
        // here. A consumed side's escrow does not move until its batch bridges, so for as long as
        // that batch is `Accumulating` the holder may still walk away with their own share; past
        // it, the USDC/wRWA has physically left and only the deferred claim can pay them.
        //
        // The decrement below is what makes this safe, and it is the whole of the fix. The hazard
        // ADR-015 froze the side to avoid is a batch counter drifting away from the escrow that
        // backs it: leave `netIn` at its old value and the batch later bridges against escrow
        // belonging to a DIFFERENT epoch's holders (spec §14, `lockOnConsume`'s Alice/Bob case).
        // Shrinking all three terms together keeps the counter honest -- and keeps every remaining
        // holder's fraction identical, because `_returnSlice` divides `s.netAmount` by `b.netIn`
        // and both moved by the same amount. That symmetry is only available because ADR-024
        // deleted `matchedOut`, the fixed term ADR-015 could not have shrunk against.
        if (s.locked) {
            Batch storage cb = classOf(id) == CLASS_RED_EPOCH ? _redeemBatch[s.batchId] : _subBatch[s.batchId];
            if (cb.status != BatchStatus.Accumulating) revert EpochLocked();
            cb.netIn -= amount;
            s.netAmount -= amount;
            // An emptied batch has to leave `Accumulating`, or it stays counted in
            // `outstanding*Batches` for the pool's operating life -- and those counters gate
            // `sweep` as well as `triggerShutDown`, so the owner's mis-sent-token backstop would
            // be held shut by a batch nobody is in. Releasing is safe here and only here: there is
            // no holder left to strand, which is not true of a batch that is merely below its
            // minimum. Idempotent by construction -- `netIn` can only reach 0 once, since the next
            // accrual opens a fresh batch.
            if (cb.netIn == 0) _releaseBatch(s.batchId, classOf(id) == CLASS_RED_EPOCH);
        }

        _burn(msg.sender, id, amount);
        s.totalIn -= amount;

        if (classOf(id) == CLASS_RED_EPOCH) {
            liveRedeemEscrow -= amount; // the whole gross leaves escrow (refund + fee)
            uint256 net = _chargeFee(amount, redeemCancelFeeBps, IERC20(address(wrwaRoute)));
            IERC20(address(wrwaRoute)).safeTransfer(msg.sender, net);
        } else {
            heldEscrowUSDC -= amount; // the whole gross leaves escrow (net-to-user + fee, unless waived)
            // SC6b: subscribe is OFF in WindDown/ShutDown, so an unlocked sub side sitting here
            // never chose to exit early -- the product turned itself off under it. Make it whole
            // at 100% (no cancel fee) rather than charging an exit fee for a decision it didn't
            // make. Redeem-side cancel (above) is unaffected -- redemption stays open, so its fee
            // still applies normally.
            bool free = state == LifecycleState.WindDown || state == LifecycleState.ShutDown;
            uint256 net = free ? amount : _chargeFee(amount, cancelFeeBps, usdc);
            usdc.safeTransfer(msg.sender, net);
        }

        emit Cancelled(id, msg.sender, amount);
    }

    /// @notice SC6a circuit breaker: assign who may `pause()` (owner-only).
    function setGuardian(address g) external onlyOwner {
        if (g == address(0)) revert InvalidState();
        guardian = g;
        emit GuardianChanged(g);
    }

    /// @dev Shared guard for `setFees`/`applyFees`: none of the 3 proposed fee bps may exceed
    /// the current `feeCapBps`.
    function _requireWithinFeeCap(uint16 s, uint16 rc, uint16 r) internal view {
        if (s > feeCapBps || rc > feeCapBps || r > feeCapBps) revert FeeCapExceeded();
    }

    /// @notice SC6a Task 6 (Art 8.2 honest fees): propose the 3 fee bps, effective after
    /// `CONFIG_TIMELOCK` so users see the change coming before it applies.
    function setFees(uint16 s, uint16 rc, uint16 r) external onlyOwner {
        _requireWithinFeeCap(s, rc, r);
        uint64 at = uint64(block.timestamp) + CONFIG_TIMELOCK;
        _pendingFees = PendingFees(s, rc, r, at, true);
        emit FeesProposed(s, rc, r, at);
    }

    /// @dev Shared guard for `applyFees`/`applyFeeCap`: a pending proposal must exist and its
    /// `CONFIG_TIMELOCK` must have elapsed.
    function _requireTimelockElapsed(bool isSet, uint64 effectiveAt) internal view {
        if (!isSet) revert InvalidState();
        if (block.timestamp < effectiveAt) revert TimelockNotElapsed();
    }

    /// @notice Apply a pending `setFees` proposal once its timelock has elapsed.
    function applyFees() external onlyOwner {
        PendingFees memory p = _pendingFees;
        _requireTimelockElapsed(p.set, p.effectiveAt);
        // cap may have dropped between propose and apply -- re-check at apply time
        _requireWithinFeeCap(p.subCancel, p.redeemCancel, p.redemption);
        cancelFeeBps = p.subCancel;
        redeemCancelFeeBps = p.redeemCancel;
        redemptionFeeBps = p.redemption;
        delete _pendingFees;
        emit FeesChanged(p.subCancel, p.redeemCancel, p.redemption);
    }

    /// @notice Propose a new epoch calendar, effective after `CONFIG_TIMELOCK` (ADR-025 D4).
    /// @dev Timelocked because nobody should be able to move the calendar silently. The dependency
    /// is LIVENESS, not safety: a schedule says WHEN, never HOW MUCH, so a wrong one can trigger
    /// early, late or never but cannot misprice or move funds. Note the limit of that framing --
    /// an UNRECOVERABLE stall is not the same risk class as a stall, and a coarsening swap would
    /// produce one; `applySchedule` is where that is refused, not here.
    function setSchedule(IEpochSchedule s) external onlyOwner {
        if (address(s) == address(0)) revert InvalidState();
        uint64 at = uint64(block.timestamp) + CONFIG_TIMELOCK;
        _pendingSchedule = PendingSchedule(address(s), at, true);
        emit ScheduleProposed(address(s), at);
    }

    /// @notice Apply the proposed calendar once `CONFIG_TIMELOCK` has elapsed.
    /// @dev `lastClosedPeriod` is deliberately NOT reset: the new calendar changes the shape of the
    /// grid, never our position in it. But the counter holds an index from the OLD grid and the gate
    /// compares it against an index from the NEW one, and those two numbers are NOT on the same
    /// scale -- so a swap to a COARSER grid can leave the stored index unreachable and brick
    /// `initiateSubEpoch` permanently, with no setter for the counter and no later swap able to
    /// recover it (a 1-day grid closing in period 400, swapped to 30 days, needs ~32 years to pass
    /// 400 again). The degenerate `EpochSchedule(1, 1)` shape is the sharp case: its first close
    /// stores `block.timestamp`, after which only a one-second grid can ever advance the counter.
    /// So refuse exactly the swaps that would strand the position, loudly, at propose-apply time
    /// rather than silently at the next epoch. This keeps ADR-025's "change the shape, never the
    /// position" and makes it enforceable.
    function applySchedule() external onlyOwner {
        PendingSchedule memory p = _pendingSchedule;
        _requireTimelockElapsed(p.exists, p.effectiveAt);
        // Ask the ONE question that separates a temporary stall from a permanent brick: when would
        // the new calendar next let us close? `dueAt(lastClosedPeriod + 1)` is exactly that moment.
        // A stranding swap puts it decades out (a 1-day grid closed at period 400, swapped to 30
        // days, needs ~32 years). Refusing on `periodOf(now) <= lastClosedPeriod` instead would ALSO
        // refuse the legitimate case of a grid that has not started yet but catches up shortly, so
        // the horizon is the right test.
        //
        // OPERATOR NOTE, because this is not obvious and the naive attempt fails: `lastClosedPeriod`
        // is an ABSOLUTE index into the grid being replaced, so a same-origin COARSENING is refused
        // as soon as `lastClosedPeriod * (newDuration - oldDuration)` exceeds the horizon -- 30d ->
        // 90d is refused after only ~12 closes. A coarsening swap must therefore anchor its
        // `epochStart` far enough in the PAST that the new grid's current period already exceeds
        // `lastClosedPeriod`. Such a schedule always exists (see `docs/decisions/ADR-025`), so no
        // state here is a dead end -- but the recipe is required, not optional.
        if (IEpochSchedule(p.schedule).dueAt(lastClosedPeriod + 1) > uint64(block.timestamp) + SCHEDULE_SWAP_HORIZON) {
            revert ScheduleWouldStrand();
        }
        schedule = IEpochSchedule(p.schedule);
        delete _pendingSchedule;
        emit ScheduleChanged(p.schedule);
    }

    /// @notice SC6a Task 6: propose a new `feeCapBps`, effective after `CONFIG_TIMELOCK`.
    /// @dev No ceiling on `cap` below 100% (ADR-007 A1) -- the honest-fee guarantee (Art 8.2) is
    /// the 48h timelock + public `FeeCapProposed`/`FeeCapChanged` events + the per-epoch fee
    /// snapshot, not a hardcoded max on the cap.
    function setFeeCap(uint16 cap) external onlyOwner {
        // M-3: >100% has no meaning and bricks gross-fee (ADR-007 A1 keeps no ceiling BELOW 100%)
        if (cap > 10_000) revert FeeCapExceeded();
        uint64 at = uint64(block.timestamp) + CONFIG_TIMELOCK;
        _pendingCap = cap;
        _pendingCapAt = at;
        _pendingCapSet = true;
        emit FeeCapProposed(cap, at);
    }

    /// @notice Apply a pending `setFeeCap` proposal once its timelock has elapsed.
    function applyFeeCap() external onlyOwner {
        _requireTimelockElapsed(_pendingCapSet, _pendingCapAt);
        feeCapBps = _pendingCap;
        _pendingCapSet = false;
        emit FeeCapChanged(feeCapBps);
    }

    /// @notice Halt the four capital-inflow entrypoints (guardian-only). Never gates
    /// exit/claim/cancel/settle/refund/handle -- a paused system must not trap user funds.
    function pause() external onlyGuardian {
        _pause(); // event: OZ Paused
    }

    /// @notice Resume inflow (owner-only, deliberately NOT the guardian -- separation of powers).
    function unpause() external onlyOwner {
        _unpause(); // event: OZ Unpaused
    }

    /// @notice SC6b: admin backstop for stray/mis-sent tokens (spec §7, design §7). Never lets a
    /// tracked protocol token's reserved balance move -- USDC nets out heldEscrowUSDC +
    /// settledRedeemUSDC; wRWA nets out liveRedeemEscrow + settledUnclaimed. Any other token has no
    /// reservation and sweeps in full.
    /// @dev Gated on quiescence (both leg counters at 0) for the two protocol tokens: a bridge
    /// return only ever arrives for a still-Bridged batch, which keeps outstandingSubBatches/
    /// outstandingRedeemBatches != 0 for its whole unordered-rendezvous window (spec §3.4). Without
    /// this gate, a return that has physically landed but whose instruction hasn't processed yet
    /// sits in `balanceOf` outside every reserve counter -- indistinguishable from a stray token --
    /// and sweeping it would leave the later instruction reverting `NotReadyToExecute` forever
    /// (cf. Uniswap V2 `skim` / Aave `AToken.rescueTokens`'s `UNDERLYING_CANNOT_BE_RESCUED`).
    /// @dev ADR-031 D2: a protocol token's free balance may go ONLY to the immutable `feeRecipient`
    /// -- the destination `recoverStuckBatch` used to hardwire before its payout moved here.
    /// `to` stays free for a foreign/stray token, so a mis-sent third-party token can still be
    /// returned to whoever sent it; USDC and wRWA cannot be directed anywhere by the owner.
    function sweep(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        uint256 free;
        if (token == address(usdc) || token == address(wrwaRoute)) {
            if (outstandingSubBatches() != 0 || outstandingRedeemBatches() != 0) revert InvalidState();
            if (to != feeRecipient) revert InvalidState();
            uint256 bal = IERC20(token).balanceOf(address(this));
            uint256 reserved = _reservedBalance(token);
            free = bal > reserved ? bal - reserved : 0; // no raw underflow -> InvalidState below
        } else {
            free = IERC20(token).balanceOf(address(this)); // foreign/stray token: full balance, anytime
        }
        if (amount > free) revert InvalidState();
        IERC20(token).safeTransfer(to, amount);
        emit Swept(token, to, amount);
    }

    /// @dev The reserved (non-sweepable) balance of a tracked protocol token -- shared by `sweep`
    /// and `recoverStuckBatch`. USDC nets out heldEscrowUSDC + settledRedeemUSDC; wRWA nets out
    /// liveRedeemEscrow + settledUnclaimed (see `sweep`'s notice above for why).
    function _reservedBalance(address token) internal view returns (uint256) {
        return token == address(usdc) ? heldEscrowUSDC + settledRedeemUSDC : liveRedeemEscrow + settledUnclaimed;
    }

    /// @dev The epoch's slice of its batch's return (`_claim`/`_claimRedeem`'s identical
    /// `s.netAmount == 0 ? 0 : Math.mulDiv(s.netAmount, b.returnedAmount, b.netIn)` expression).
    /// Both storage refs flow in as inputs only; the expression itself is unchanged.
    function _returnSlice(EpochSide storage s, Batch storage b) internal view returns (uint256) {
        return s.netAmount == 0 ? 0 : Math.mulDiv(s.netAmount, b.returnedAmount, b.netIn);
    }

    /// @notice Local mirror pattern of `PruvExecutor.Swept` -- kept off `IREXGovernance` so
    /// `/shared` stays 0-diff for this REX-only backstop (M-1, spec section 11 audit finding).
    /// @param residual the contract's WHOLE unreserved balance at this moment, left in place --
    /// never a transfer (see `recoverStuckBatch`). It is a snapshot, not an entitlement: while
    /// another batch is still in flight it also contains that batch's landed-but-unrecorded return,
    /// which `sweep`'s quiescence gate is what keeps from being taken. Read it as "this much is
    /// unattributed right now", and let `sweep` decide what is actually free.
    event StuckBatchRecovered(uint64 indexed batchId, bool isRedeem, uint256 residual);

    /// @notice M-1: last-resort recovery of a batch stuck `Bridged` because its return leg is
    /// un-processable (e.g. an under-delivered/short return). Scoped to a provably-dead batch
    /// only: `Bridged`, return not received, and past its bridge deadline -- a live batch can
    /// never satisfy this gate. Marks the batch terminated so `outstanding*` decrements and
    /// `triggerShutDown` can complete. It moves NO tokens: the stranded residual is left for
    /// `sweep`, which is the one place allowed to judge an unreserved balance -- and which gates on
    /// quiescence for exactly the reason this verb must not skim (ADR-031). A return that
    /// has physically landed while its paired instruction is still in flight sits in `balanceOf`
    /// outside every reserve counter, indistinguishable from a stray token; paying out
    /// `balance - reserved` here took a HEALTHY parallel batch's money to the fee recipient and left
    /// its instruction reverting `NotReadyToExecute` forever, its holders claiming zero
    /// (`REXPrimary.recover.t.sol`'s `test_recover_leaves_a_parallel_batchs_landed_return_alone`).
    /// The two-step is the fix: this verb unsticks the accounting at any time, `sweep` takes the
    /// money once nothing is in flight.
    /// @dev Terminal status is `Settled`, NOT `Released`/`Aborted`: at bridge time this batch's
    /// net leg already left its escrow reserve (`heldEscrowUSDC`/`liveRedeemEscrow` -- see
    /// `initiateSubEpoch`), so `Released`'s and (for a redeem batch) `Aborted`'s claim branches in
    /// `_claim`/`_claimRedeem` would try to refund from a reserve that no longer holds this
    /// batch's funds -- either underflowing or, worse, silently draining OTHER batches' escrow.
    /// `Settled` with `returnedAmount` left at its default 0 is safe: the claim's slice zeroes out
    /// (its value is exactly the residual left behind here, which cannot be fairly pro-rated from a
    /// short/partial return). Flipping status away from `Bridged` also permanently blocks
    /// `_onInstruction`/`settleSubBatch`/`settleRedeemBatch` (both gate on `status == Bridged`)
    /// from ever re-processing this leg, so `*BatchesTerminated` can never double-increment.
    function recoverStuckBatch(uint64 batchId, bool isRedeem) external onlyOwner nonReentrant {
        Batch storage b = isRedeem ? _redeemBatch[batchId] : _subBatch[batchId];
        _requireBridgedUnreturned(b);
        uint64 deadline = b.bridgedAt + (isRedeem ? redeemFulfillTimeout : subFulfillTimeout);
        if (block.timestamp < deadline) revert AbortBeforeDeadline();

        b.status = BatchStatus.Settled;
        if (isRedeem) {
            redeemBatchesTerminated++;
        } else {
            subBatchesTerminated++;
        }

        address token = isRedeem ? address(usdc) : address(wrwaRoute);
        uint256 bal = IERC20(token).balanceOf(address(this));
        uint256 reserved = _reservedBalance(token);
        emit StuckBatchRecovered(batchId, isRedeem, bal > reserved ? bal - reserved : 0);
    }

    /// @notice SC6b: start the wind-down grace window (spec §5/§7.7). Also releases any open
    /// below-MIN_SUB subscribe batch (Task 4); the 100%-refund cancel branch lives in
    /// `cancelRequest`.
    function triggerWindDown() external onlyOwner {
        _requireEpochBased();
        state = LifecycleState.WindDown;
        windDownStart = uint64(block.timestamp);
        // Finding 2 (Lead ruling 2026-08-15): the subscribe leg is now OFF, so an open below-
        // MIN_SUB batch can never fill -> release it now (design section 5 step 4 / spec section
        // 7.7 step 5). Its holders' side is `locked` in the batch, so the 100%-refund cancel path
        // (`cancelRequest`) cannot reach it; without this it strands and outstandingSubBatches
        // never reaches 0 -> triggerShutDown deadlocks.
        // (openSubBatchId != 0 implies Accumulating & below-min: a batch that reached MIN_SUB
        // bridged in-tx and reset openSubBatchId to 0.) Redeem is NOT released here -- it stays
        // open and can still fill mid-window, so that leg drains via `releaseStaleRedeemBatch`
        // once stale (Task 3).
        uint64 sb = openSubBatchId;
        if (sb != 0) _releaseBatch(sb, false);
        emit WindDownTriggered(uint64(block.timestamp) + windDownWindow);
    }

    /// @notice SC6b: end wind-down and enter the terminal claims-only state (spec §5/§7.7, RS9).
    /// @dev The batch clause is load-bearing: even after the window elapses, a batch still
    /// `Accumulating`/`Bridged` on EITHER leg holds user funds this contract cannot otherwise
    /// return once `ShutDown` (no inflow, and `claim`/`cancelRequest` cannot reach an unsettled
    /// batch) -- refusing here, not gating claim/settle, is what prevents the strand.
    function triggerShutDown() external onlyOwner {
        if (state != LifecycleState.WindDown) revert WrongLifecycleState();
        if (block.timestamp < windDownStart + windDownWindow) revert WindDownNotComplete();
        if (outstandingSubBatches() != 0 || outstandingRedeemBatches() != 0) revert WindDownNotComplete();
        state = LifecycleState.ShutDown;
        emit ShutDown();
    }

    /// @notice The epoch trigger (spec §7.4). ADR-024 removed matching, so the whole side IS the
    /// residual: it is accrued into the leg's batch, which bridges only once it reaches its
    /// minimum (`minSub` / `minRedeem`).
    /// @dev PERMISSIONLESS (ADR-025): what used to be an address check on a privileged trigger
    /// role is now a `schedule` check -- anyone may fire the epoch, but not before its scheduled
    /// moment and never twice in the same period.
    /// @dev `payable`: the caller funds the quoted interchain gas for both outbound legs
    /// and the unspent remainder is refunded (`hyperlane-bridge.md` §"Gas / IGP").
    function initiateSubEpoch() external payable override nonReentrant whenNotPaused {
        _requireEpochOpenOrWindDown();
        // ADR-029: gated on a WINDOW at the start of each period -- rejected before it opens, and
        // again once it closes, not open indefinitely after the moment. `periodIfOpen` returns 0
        // for any timestamp outside the window, which fails the `<= lastClosedPeriod` test below
        // exactly like an already-closed period does, so no separate zero-check is needed.
        // Skipped in WindDown: spec section 7.7 step 3 keeps redemption open while subscribe is
        // off, so the calendar (which exists to batch inflow) has nothing left to do there.
        if (state != LifecycleState.WindDown) {
            uint64 period = schedule.periodIfOpen(uint64(block.timestamp));
            if (period <= lastClosedPeriod) revert TooEarly();
            lastClosedPeriod = period;
        }
        uint256 balanceBefore = address(this).balance - msg.value;

        uint64 epochId = currentEpochId;
        EpochSide storage sub = epochSideById[encodeId(CLASS_SUB_EPOCH, epochId)];
        EpochSide storage red = epochSideById[encodeId(CLASS_RED_EPOCH, epochId)];
        // SC6b spec §7.7 step 3: subscribe is OFF in wind-down -- force the side empty so no
        // subscribe batch opens; a leftover unlocked sub side (deposited but not yet initiated
        // when wind-down triggered) never locks and refunds 100% via cancelRequest (Task 4).
        uint256 S = state == LifecycleState.WindDown ? 0 : sub.totalIn;
        uint256 Rwrwa = red.totalIn;
        if (S == 0 && Rwrwa == 0) revert NothingToSettle();

        // --- record both aggregates (held, raw reassignment, no token move — spec §7.4 step 2) ---
        // ADR-024: matching is removed, so the WHOLE side is the net that routes to Pruv. There is
        // no `x`, no zone classifier and no matched pot; `matchedOut` is gone from `EpochSide`.
        sub.netAmount = S;
        red.netAmount = Rwrwa;

        if (S > 0) sub.locked = true;
        // Lock the redeem side whenever this epoch consumes it (Rwrwa > 0), mirroring sub.locked above
        // (spec 7.3 / 7.4 step 2: consume -> lock -> no cancel).
        //
        // ADR-024 decision 7 -- THE NAMED TRAP. This comment used to say the side locks "matched or
        // not", and that phrasing is why the line survived the matching removal: the hazard is created
        // by ADR-015 BATCH ACCRUAL, which SC11 keeps, and not by matching at all. Once a residual is
        // folded into `_redeemBatch[batchId].netIn`, a LATER epoch's escrow physically backs it, and
        // cancelRequest checks only EpochSide.locked -- so leaving this unlocked would let a redeemer
        // cancel against a DIFFERENT epoch's (or a later redeemer's) escrow: a cross-epoch
        // double-spend (spec 14, found in review of SC5a Task 3). Deleting this line by adjacency
        // while removing matching would have reintroduced that Critical, which is why it carries its
        // own mutation-checked regression test (REXPrimary.lockOnConsume.t.sol) rather than relying on
        // a passing suite. The locked side's exit is the deferred claim (`_claimRedeem`) for Settled
        // or Released batches -- never cancelRequest. (There is no longer any "fully-matched immediate
        // claim"; that branch went with ADR-024.)
        if (Rwrwa > 0) red.locked = true;

        currentEpochId = epochId + 1;

        // --- subscribe side -> its batch (redeem side recorded above; its batch below) ---
        if (S > 0) {
            uint64 batchId = openSubBatchId;
            if (batchId == 0) {
                batchId = nextSubBatchId++;
                openSubBatchId = batchId;
                _subBatch[batchId].status = BatchStatus.Accumulating;
                _subBatch[batchId].accrualStart = uint64(block.timestamp);
            }
            Batch storage b = _subBatch[batchId];
            b.netIn += S;
            sub.batchId = batchId;
            emit SubEpochInitiated(epochId, batchId, S);

            if (b.netIn >= minSub) {
                b.leg = _bridgeBatch(b, batchId, usdcRoute, usdc, 0, false);
                emit SubBatchBridged(batchId, b.netIn, b.leg.instrMsgId);
            }
            // ADR-027: below min -> stays Accumulating, indefinitely and safely. There is no cap
            // to expire against, because there is nothing to compensate for: its holders keep
            // `cancelRequest` for as long as the batch accrues, and the batch fills or they leave.
        } else {
            // empty subscribe side (or wind-down): no batch to open.
            emit SubEpochInitiated(epochId, 0, 0);
        }

        // --- redeem side -> its batch (mirror of the subscribe block; PARALLEL, no single-in-flight) ---
        if (Rwrwa > 0) {
            uint64 rBatchId = openRedeemBatchId;
            if (rBatchId == 0) {
                rBatchId = nextRedeemBatchId++;
                openRedeemBatchId = rBatchId;
                _redeemBatch[rBatchId].status = BatchStatus.Accumulating;
                _redeemBatch[rBatchId].accrualStart = uint64(block.timestamp);
            }
            Batch storage rb = _redeemBatch[rBatchId];
            rb.netIn += Rwrwa;
            red.batchId = rBatchId;
            emit RedeemEpochAccrued(epochId, rBatchId, rb.netIn);

            // minRedeem is denominated in wRWA (ADR-026 D2): the batch accrues wRWA and the
            // threshold is wRWA, so the gate needs no price. This is what lets initiateSubEpoch read
            // no NAV at all -- audit fix H-2's re-valuation existed only to bridge the unit
            // mismatch, and with it goes the cross-epoch re-pricing drift it documented.
            if (rb.netIn >= minRedeem) {
                // synthetic wRWA route: approveToken = address(0) (burns rex's wRWA, no allowance)
                rb.leg = _bridgeBatch(rb, rBatchId, wrwaRoute, IERC20(address(0)), 0, true);
                emit RedeemBatchBridged(rBatchId, rb.netIn, rb.leg.instrMsgId);
            }
            // else: below min -> stays Accumulating, its holders still able to cancel (ADR-027).
        }

        _refundNative(balanceBefore);
    }

    /// @dev Shared native-gas-refund tail for `closeLaunchpad`/`initiateSubEpoch`: both snapshot
    /// `balanceBefore` up front (before any branch) so every exit path refunds unspent native,
    /// even a branch that never bridges (no-stranded-funds). Pure statement extraction.
    function _refundNative(uint256 balanceBefore) internal {
        uint256 refund = address(this).balance - balanceBefore;
        if (refund > 0) {
            (bool ok,) = msg.sender.call{value: refund}("");
            if (!ok) revert RefundFailed();
        }
    }

    /// @dev Shared "cross the bridge" sequence for a batch that just reached its minimum (spec
    /// §7.4/§7.5, reused by `closeLaunchpad` and `initiateSubEpoch`'s two near-identical residual
    /// blocks): flip to `Bridged`, release the batch's own escrow reservation (net wRWA/USDC
    /// physically leaves escrow to Pruv -- seam #98), stamp `bridgedAt`, clear the caller's
    /// open-batch pointer, and send the paired token+instruction legs. Pure statement extraction: every call site still owns and emits its own
    /// (`SubBatchBridged`/`RedeemBatchBridged`) event; `isRedeem` selects which pair of storage
    /// slots (escrow accumulator + open-batch pointer) this leg touches AND the `RequestKind`
    /// (`Subscribe` iff not redeem, `Redeem` iff redeem -- true at every current call site, so
    /// deriving it here instead of threading it as a separate param changes no value), so
    /// behavior is byte-identical to the pre-extraction inline code.
    /// @param navForWire The `Instruction.navAtInitiate` field. EVERY call site passes `0` after
    /// ADR-026 (`initiateSubEpoch` on both legs, and `closeLaunchpad`): the field stays in the
    /// frozen wire format (D4, so `/shared` needs no ADR-016 version bump) but PRUV derives nothing
    /// from it -- it reads the price locally and only echoes this back. `0` is deliberately a
    /// fail-loud sentinel rather than a plausible `1e18`: `PruvExecutor` used to DIVIDE by this
    /// value, so any surviving dependency panics instead of computing quietly. Kept as a parameter
    /// rather than inlined so the single place that writes the wire field stays explicit. The
    /// matching HOME STORAGE field (`Batch.navAtInitiate`) is gone: it was written here and read
    /// nowhere, so it was an SSTORE of a constant 0 on every bridge and a misleading struct field.
    function _bridgeBatch(
        Batch storage b,
        uint64 batchId,
        IWarpRoute route,
        IERC20 approveToken,
        uint256 navForWire,
        bool isRedeem
    ) internal returns (Leg memory) {
        b.status = BatchStatus.Bridged;
        if (isRedeem) {
            liveRedeemEscrow -= b.netIn;
            openRedeemBatchId = 0;
        } else {
            heldEscrowUSDC -= b.netIn;
            openSubBatchId = 0;
        }
        b.bridgedAt = uint64(block.timestamp);
        RequestKind kind = isRedeem ? RequestKind.Redeem : RequestKind.Subscribe;
        return _sendPair(
            pruvDomain,
            route,
            approveToken,
            b.netIn,
            Instruction({
                legId: batchId,
                kind: kind,
                amount: b.netIn / (isRedeem ? wrwaUnit : usdcUnit),
                navAtInitiate: navForWire
            })
        );
    }

    /// @notice SC6b: single canonical batch release site for BOTH legs (never bridged -- a
    /// subscribe refund is via the deferred claim's Released branch, spec §7.6; a redeem release
    /// moves no escrow, redeemers reclaim their wRWA via the deferred claim, spec §7.5). Routed
    /// through by the in-epoch cap-release (`initiateSubEpoch`, both legs), `triggerWindDown`'s
    /// open-batch release (subscribe), and the permissionless stale-drain
    /// (`releaseStaleRedeemBatch`, redeem), so a batch reaches `Released` -- and
    /// `subBatchesTerminated`/`redeemBatchesTerminated` increments -- exactly once regardless of
    /// which caller triggers it.
    /// @dev Safe to unconditionally zero the open-batch pointer: an `Accumulating` batch is
    /// always the single currently-open one on its leg (`openSubBatchId`/`openRedeemBatchId ==
    /// batchId` from creation until it leaves `Accumulating` for `Bridged` or `Released`), so
    /// this never clobbers a different batch's open slot.
    function _releaseBatch(uint64 batchId, bool isRedeem) internal {
        Batch storage b = isRedeem ? _redeemBatch[batchId] : _subBatch[batchId];
        b.status = BatchStatus.Released;
        if (isRedeem) {
            openRedeemBatchId = 0;
            redeemBatchesTerminated++;
        } else {
            openSubBatchId = 0;
            subBatchesTerminated++;
        }
        emit BatchReleased(batchId, uint8(isRedeem ? RequestKind.Redeem : RequestKind.Subscribe), b.netIn);
    }

    /// @notice SC6b (BLOCKING-1 fix), narrowed by ADR-027: the permissionless drain that keeps
    /// `triggerShutDown` reachable. The redeem book stays open through wind-down (spec §7.7 step
    /// 3), so unlike the subscribe leg -- which `triggerWindDown` clears at entry -- a redeem
    /// batch can still be `Accumulating` when the grace window ends, and `outstandingRedeemBatches`
    /// would never reach 0.
    /// @dev ADR-027 removed this function's other trigger, the `maxRedeemWait` accrual cap. That
    /// cap existed to bound how long a locked-out holder waited; holders are no longer locked out,
    /// so draining a live batch on a clock would now END a position its holders could simply have
    /// cancelled. Decommissioning is the only remaining reason to force a batch closed, and the
    /// wind-down window is exactly that moment.
    function releaseStaleRedeemBatch(uint64 batchId) external nonReentrant {
        _requireEpochOpenOrWindDown();
        Batch storage rb = _redeemBatch[batchId];
        if (rb.status != BatchStatus.Accumulating) revert InvalidState();
        if (state != LifecycleState.WindDown || block.timestamp < windDownStart + windDownWindow) {
            revert InvalidState();
        }
        _releaseBatch(batchId, true);
    }

    /// @notice Flip a subscribe batch to Settled once its return has recorded (spec §7.6).
    /// @dev The wRWA pot is credited at RECORD time (`_onInstruction`'s `Subscribe` branch), NOT
    /// here: subscribe batches are PARALLEL (ADR-018, no single-in-flight), so crediting only on
    /// settle would leave a recorded-but-unsettled batch's return sitting in the raw balance
    /// uncounted by any reserve, letting a later batch's rendezvous "borrow" it (spec §14). O(1) —
    /// nothing is pushed to holders; they pull with `claim` (spec §7.6). Mirrors `settleRedeemBatch`.
    function settleSubBatch(uint64 batchId) external override nonReentrant {
        Batch storage b = _subBatch[batchId];
        _requireBridgedReceived(b);

        b.status = BatchStatus.Settled;
        subBatchesTerminated++;

        emit SubBatchSettled(batchId);
    }

    /// @notice Claim the subscribe payout (wRWA) for the epoch receipts of `id`.
    function claim(uint256 id, uint256 amount) external override nonReentrant {
        _claim(id, amount);
    }

    /// @notice Claim the launchpad payout (wRWA), pro-rata, after the return settles (spec §7.6).
    function claimLaunchpad(uint256 amount) external override nonReentrant {
        _claim(encodeId(CLASS_LAUNCHPAD, LAUNCHPAD_ID), amount);
    }

    /// @dev Shared "openable" gate for `_claim`/`_claimRedeem`: a side with NO BATCH is openable
    /// once locked (after ADR-024 removed matching, an unlocked-and-empty side is simply one no
    /// epoch has consumed yet, so this rejects it); every side that names a batch must wait for
    /// that batch to be Settled, or (`allowReleased`, redeem only) Released.
    /// @dev The no-batch test used to read `netAmount == 0`, which meant the same thing only
    /// because `locked` implied `netAmount > 0`: the net was set to the whole side at initiate and
    /// nothing could reduce it. ADR-027's cancel reduces it, so a locked side with a LIVE batch can
    /// now read zero, and the old shortcut let it past this gate entirely. Nothing is stealable
    /// through that today -- `netAmount` and `totalIn` fall together, so a zero net means no
    /// receipts remain and no one is left to claim -- but the guard would be open for whatever
    /// next separates those two numbers. Test the thing actually meant.
    function _requireClaimable(EpochSide storage s, BatchStatus status, bool allowReleased) internal view {
        if (s.batchId == 0) {
            if (!s.locked) revert NotSettled();
        } else if (status != BatchStatus.Settled && !(allowReleased && status == BatchStatus.Released)) {
            revert NotSettled();
        }
    }

    /// @notice The one deferred claim (ADR-014). Two divisions: the epoch takes its
    /// slice of the batch, then the holder takes their slice of the epoch.
    /// @dev The only caller-supplied input is `amount`; everything else is looked up
    /// from `id`, which is why a receipt bought on the open market and a partial claim
    /// both settle identically. `totalIn` is NOT decremented — it is the denominator.
    function _claim(uint256 id, uint256 amount) internal {
        if (amount == 0) revert ZeroAmount();

        EpochSide storage s = epochSideById[id];
        Batch storage b = _subBatch[s.batchId];

        // The redeem claim pays USDC, so it dispatches to `_claimRedeem` and returns immediately:
        // a RED_EPOCH id must NEVER reach the wRWA payout below -- it draws on different reserves
        // (`settledRedeemUSDC`/`liveRedeemEscrow`) and charges the redemption fee.
        if (classOf(id) == CLASS_RED_EPOCH) {
            _claimRedeem(id, amount);
            return;
        }

        // Released (never bridged) or Aborted (bridged then returned) subscribe batch -> refund USDC.
        if (s.netAmount != 0 && (b.status == BatchStatus.Released || b.status == BatchStatus.Aborted)) {
            uint256 refundUsdc = Math.mulDiv(amount, s.netAmount, s.totalIn);
            _burn(msg.sender, id, amount);
            heldEscrowUSDC -= refundUsdc;
            usdc.safeTransfer(msg.sender, refundUsdc);
            emit Claimed(id, msg.sender, amount, refundUsdc);
            return;
        }

        // Otherwise pay wRWA from a Settled batch's return.
        _requireClaimable(s, b.status, false);

        // ADR-024: one reserve, ONE floor. The matched leg is gone, so the payout is only this
        // epoch's slice of the batch's return, drawn from the bridge-return pot (`settledUnclaimed`).
        uint256 payout = Math.mulDiv(amount, _returnSlice(s, b), s.totalIn);

        _burn(msg.sender, id, amount);
        settledUnclaimed -= payout;
        IERC20(address(wrwaRoute)).safeTransfer(msg.sender, payout);
        emit Claimed(id, msg.sender, amount, payout);
    }

    /// @notice The redeem deferred claim (spec §7.6, design §3.7b). ADR-024 removed the matched leg,
    /// so there is one case each way: Fulfilled pays the USDC slice @ nav1 (fee'd); Aborted and
    /// Released pay the wRWA refund (no fee), from `settledUnclaimed` and `liveRedeemEscrow`.
    function _claimRedeem(uint256 id, uint256 q) internal {
        EpochSide storage s = epochSideById[id];
        Batch storage b = _redeemBatch[s.batchId];

        // openable: the batch must be Settled or Released
        _requireClaimable(s, b.status, true);

        _burn(msg.sender, id, q);

        // wRWA-refund cases: Released (never bridged) or Aborted (came back).
        if (
            b.status == BatchStatus.Released
                || (b.status == BatchStatus.Settled && b.leg.retKind == RequestKind.RedeemAborted)
        ) {
            uint256 refundWrwa = Math.mulDiv(q, s.netAmount, s.totalIn);
            if (refundWrwa > 0) {
                if (b.status == BatchStatus.Released) {
                    liveRedeemEscrow -= refundWrwa; // never bridged; still in escrow
                } else {
                    settledUnclaimed -= refundWrwa; // aborted; reserved at settle
                }
                IERC20(address(wrwaRoute)).safeTransfer(msg.sender, refundWrwa);
            }
            emit Claimed(id, msg.sender, q, 0);
            return;
        }

        // Fulfilled (Settled, retKind == Redeem): all USDC, from settledRedeemUSDC.
        uint256 slicePaid = Math.mulDiv(q, _returnSlice(s, b), s.totalIn);
        settledRedeemUSDC -= slicePaid;
        uint256 net = _chargeFee(slicePaid, s.redemptionFeeBps, usdc);
        usdc.safeTransfer(msg.sender, net);
        emit Claimed(id, msg.sender, q, net);
    }

    /// @dev Return leg, keyed by `batchId` (ADR-015). The token leg and the instruction
    /// leg arrive independently with NO ordering guarantee (spec §3.4), so record the
    /// return only once the covering wRWA is actually here — otherwise `settleSubBatch`
    /// would open claims against tokens that have not arrived. Reverting leaves the
    /// message retryable.
    /// @dev Per-leg replay latch (SC4a Task 4, constitution Art 4.1): checked first, before any
    /// status guard, so a duplicate delivery of an already-processed leg is a silent no-op. Set
    /// only after the Subscribe rendezvous succeeds, so a premature delivery (before the
    /// covering wRWA arrives) reverts `NotReadyToExecute` WITHOUT latching and stays
    /// re-processable. Task 5 adds the `SubAborted` branch below (inline settle, no separate
    /// `settleSubBatch` step); Task 6 extends `_claim` to refund its re-reserved USDC.
    /// @dev USDC on hand not already reserved by an open pot -- the "did the bridged USDC leg
    /// actually arrive yet" rendezvous check shared by the SubAborted and Redeem branches below.
    function _usdcFresh() internal view returns (uint256) {
        return usdc.balanceOf(address(this)) - heldEscrowUSDC - settledRedeemUSDC;
    }

    /// @dev wRWA on hand not already reserved by an open pot -- the same rendezvous check as
    /// `_usdcFresh`, shared by the Subscribe and RedeemAborted branches below.
    function _wrwaFresh() internal view returns (uint256) {
        return IERC20(address(wrwaRoute)).balanceOf(address(this)) - settledUnclaimed - liveRedeemEscrow;
    }

    /// @dev Shared guard for all four `_onInstruction` branches: the leg must be Bridged and not
    /// already returned. `|| b.leg.returnReceived` is defense-in-depth -- not reachable via the
    /// executor's own latches, but rejects a duplicate different-kind return outright rather than
    /// relying solely on `processedLeg`.
    function _requireBridgedUnreturned(Batch storage b) internal view {
        if (b.status != BatchStatus.Bridged || b.leg.returnReceived) revert InvalidState();
    }

    /// @dev Shared by the Subscribe/Redeem/RedeemAborted branches below: latch the leg and record
    /// its return. `SubAborted` differs (a status flip, not a `returnReceived` mark) so stays inline.
    function _recordReturn(Batch storage b, bytes32 legKey, uint256 amount) internal {
        processedLeg[legKey] = true;
        b.leg.returnReceived = true;
        b.returnedAmount = amount;
    }

    function _onInstruction(uint32, Instruction memory instr) internal override {
        bytes32 legKey = keccak256(abi.encode(instr.legId, instr.kind));
        if (processedLeg[legKey]) return; // Art 4.1 — idempotent at the handler, before any status revert

        // ADR-028 D3: the wire carries micro-units; convert once, in the returned asset's own units.
        uint256 amt = instr.amount
            * (instr.kind == RequestKind.Subscribe || instr.kind == RequestKind.RedeemAborted ? wrwaUnit : usdcUnit);

        if (instr.kind == RequestKind.Subscribe) {
            Batch storage b = _subBatch[instr.legId];
            _requireBridgedUnreturned(b);
            uint256 available = _wrwaFresh();
            if (available < amt) revert NotReadyToExecute(); // not latched — stays re-processable
            _recordReturn(b, legKey, amt);
            // Credit at RECORD, not at settle: subscribe batches are PARALLEL (ADR-018) -- deferring to
            // settleSubBatch would leave a returned-but-unsettled batch's wRWA uncounted by any reserve, so a
            // later batch's return could borrow it (spec section 14 insolvency). Mirrors settledRedeemUSDC below.
            settledUnclaimed += amt;
            emit SubReturnReceived(instr.legId, amt);
        } else if (instr.kind == RequestKind.SubAborted) {
            Batch storage b = _subBatch[instr.legId];
            _requireBridgedUnreturned(b);
            // SC5a: reserve out the redeem-side USDC pot too, or a SubAborted return could
            // falsely rendezvous against USDC that is actually owed to redeemers (spec §14).
            uint256 usdcFresh = _usdcFresh();
            if (usdcFresh < amt) revert NotReadyToExecute(); // USDC leg not here yet — re-processable
            processedLeg[legKey] = true;
            b.status = BatchStatus.Aborted;
            subBatchesTerminated++;
            b.returnedAmount = amt;
            heldEscrowUSDC += amt;
            emit SubBatchAborted(instr.legId);
        } else if (instr.kind == RequestKind.Redeem) {
            // fulfilled USDC return
            Batch storage b = _redeemBatch[instr.legId];
            _requireBridgedUnreturned(b);
            uint256 usdcFresh = _usdcFresh();
            if (usdcFresh < amt) revert NotReadyToExecute(); // USDC not here yet -> re-processable
            _recordReturn(b, legKey, amt);
            b.leg.retKind = RequestKind.Redeem;
            // Credit at RECORD, not at settle: redeem batches are PARALLEL (no single-in-flight),
            // so deferring this to settleRedeemBatch would leave a recorded-but-unsettled batch's
            // USDC sitting in the raw balance uncounted by any reserve -- a second in-flight
            // batch's rendezvous could then "borrow" it as if it were its own fresh arrival
            // (spec §14 insolvency). Mirrors SubAborted's inline credit of heldEscrowUSDC above.
            settledRedeemUSDC += amt;
        } else if (instr.kind == RequestKind.RedeemAborted) {
            // wRWA refund return
            Batch storage b = _redeemBatch[instr.legId];
            _requireBridgedUnreturned(b);
            uint256 wrwaFresh = _wrwaFresh();
            if (wrwaFresh < amt) revert NotReadyToExecute();
            _recordReturn(b, legKey, amt);
            b.leg.retKind = RequestKind.RedeemAborted;
            settledUnclaimed += amt; // credit at record, not settle -- see Redeem branch above
        } else {
            revert InvalidState(); // unreachable: all four kinds handled
        }
    }
}
