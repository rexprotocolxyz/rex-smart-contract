// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import "@openzeppelin/contracts/token/ERC1155/IERC1155Receiver.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import "./BridgeAdapter.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/Wire.sol";
import "@rex-shared/Errors.sol";
import {IPruvExecutor} from "@rex-shared/IPruvExecutor.sol";
import {IRWAConversion} from "./NavReporter.sol";
import "./libraries/State.sol";

/// @notice Minimal Pruv vault deposit surface PruvExecutor needs.
interface IRWAToken {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);
    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);
    function convertToAssets(uint256 shares) external view returns (uint256);
}

/// @notice PRUV-side relayer handle-direct entrypoint: on a delivered Subscribe
/// instruction, deposits the bridged USDC into the Pruv vault and bridges the
/// resulting wRWA shares back home, paired with a return instruction leg.
/// @dev Redeem is fully wired: a delivered Redeem instruction is recorded, then resolved exactly
/// once - either completed by executeRedeem (sells wRWA into the vault, bridges the net USDC home)
/// or recovered by abortRedeem (bridges the wRWA back home after the deadline).
contract PruvExecutor is BridgeAdapter, IERC1155Receiver, IPruvExecutor {
    IWarpRoute public immutable wrwaRoute;
    uint32 public immutable homeDomain;
    address public immutable rwaToken;
    IERC20 public immutable usdc;
    IWarpRoute public immutable usdcRoute;
    uint256 public immutable subFulfillTimeout;
    uint256 public immutable executorSlippageBps;
    /// @notice PRUV NAV source (RWAConversion / RWAFixedConversion, ADR-026): the executor reads
    /// this directly instead of trusting a price that crossed the bridge and came back.
    IRWAConversion public immutable rwaConversion;

    /// @dev ADR-028 D1/D3: one micro-unit of each asset in its local units, read from the token.
    uint256 internal immutable usdcUnit;
    uint256 internal immutable rwaUnit;

    Leg public lastReturnLeg;

    /// @notice A subscribe leg recorded on delivery (ADR-015 Decision 9). Recording
    /// before attempting is what makes `executeDeposit` implementable at all: a
    /// reverting handler stores nothing, so a fallback keyed by batchId would have
    /// no state to poke. `deadline` and `aborted` are now in use (SC4b).
    struct PendingDeposit {
        uint256 amount;
        uint256 navAtInitiate;
        bool exists;
        bool executed;
        uint64 deadline; // stamped block.timestamp + subFulfillTimeout at record (spec §7.5)
        bool aborted; // set by abortDeposit; an aborted leg is inert to any poke
    }

    mapping(uint64 => PendingDeposit) public pending;

    uint256 public immutable redeemFulfillTimeout;

    /// @notice A redeem leg recorded on delivery (mirror of PendingDeposit). Recording reserves
    /// the bridged shares against pendingRedeemShares so parallel batches cannot cannibalise each
    /// other's shares (design §4.1). Resolves exactly once via executeRedeem or abortRedeem.
    struct PendingRedeem {
        uint256 shares;
        uint256 navAtInitiate;
        uint256 grossAssets; // record-time usdc estimate = mulDiv(shares, nav, 1e18); the funding
        // target is redeemTarget(), read live from the vault, not this field
        uint64 deadline; // authoritative PRUV clock: block.timestamp + redeemFulfillTimeout at record
        bool exists;
        bool executed;
        bool aborted;
        uint64 notBefore; // ADR-030 D1: record time + redeemDelay
    }

    mapping(uint64 => PendingRedeem) public pendingRedeem;
    uint256 public pendingRedeemShares; // vault shares committed to recorded-not-resolved redeem batches
    uint256 public pendingDepositAssets; // USDC committed to recorded-not-resolved deposit legs (H-1/M-2)

    /// @notice ADR-030 D2: the wait between a redemption's anchors and its execution. Owner-settable
    /// within [minRedeemDelay, redeemFulfillTimeout).
    uint64 public redeemDelay;
    /// @notice ADR-030 D3: the floor Pruv relies on; fixed at deploy.
    uint64 public immutable minRedeemDelay;
    /// @notice ADR-030 D1 (OQ-1 = b): no redemption executes before this -- the last successful
    /// subscription deposit plus the delay in force when it landed.
    uint64 public depositUnlockAt;
    /// @dev ADR-030 D10: recorded redeem batch ids in record order; `redeemHead` indexes the oldest
    /// entry that may still be open.
    uint64[] internal redeemQueue;
    uint256 internal redeemHead;

    /// @dev Vault filled below the initiate→execute slippage floor. Never surfaces to a caller —
    /// it is always caught by `_tryDeposit`'s try/catch, which rolls the deposit back and defers.
    error SlippageFloorBreached();

    /// @notice The executor's held balance of a WithFee-route fee token is below the quoted fee
    /// (the USDC float is empty/short). Fails loud at the call site for `executeRedeem` and both
    /// aborts' own sends; on the subscribe path it is instead caught inside `_tryDeposit`'s
    /// try/catch around `_depositChecked` and swallowed into `SubDepositDeferred` (or
    /// `NotReadyToExecute` from `executeDeposit`). Refill and retry (AT-190).
    error FeeTokenInsufficient(address token, uint256 needed, uint256 have);

    constructor(
        IMailbox mailbox,
        IWarpRoute wrwaRoute_,
        uint32 homeDomain_,
        address rwaToken_,
        address usdc_,
        IWarpRoute usdcRoute_,
        uint256 subFulfillTimeout_,
        uint256 executorSlippageBps_,
        uint256 redeemFulfillTimeout_,
        IRWAConversion rwaConversion_,
        uint64 redeemDelay_,
        uint64 minRedeemDelay_
    ) BridgeAdapter(mailbox) {
        // Immutable + deploy-once for mainnet (ADR-011). ADR-026 D5: `>=`, not `>` -- at exactly
        // 1e4 the slippage floor computes to zero, and the floor is the ONLY guard on the vault's
        // output in either direction (no separate zero check), so a 0-share deposit or a 0-USDC
        // redeem would be accepted and latched.
        if (executorSlippageBps_ >= 1e4) revert InvalidState();
        if (address(rwaConversion_) == address(0)) revert InvalidState();
        // ADR-030 D3/D5: the floor bounds the knob from below; a delay at or above the abort deadline
        // would make every batch abortable before it is executable.
        if (minRedeemDelay_ > redeemDelay_ || redeemDelay_ >= redeemFulfillTimeout_) revert InvalidState();
        wrwaRoute = wrwaRoute_;
        homeDomain = homeDomain_;
        rwaToken = rwaToken_;
        usdc = IERC20(usdc_);
        usdcRoute = usdcRoute_;
        subFulfillTimeout = subFulfillTimeout_;
        executorSlippageBps = executorSlippageBps_;
        redeemFulfillTimeout = redeemFulfillTimeout_;
        rwaConversion = rwaConversion_;
        usdcUnit = _unit(usdc_);
        rwaUnit = _unit(rwaToken_);
        minRedeemDelay = minRedeemDelay_;
        redeemDelay = redeemDelay_;
    }

    function _unit(address token) internal view returns (uint256) {
        uint8 d = IERC20Metadata(token).decimals();
        if (d < 6 || d > 18) revert InvalidState();
        return 10 ** (d - 6);
    }

    /// @notice ADR-030 D2. Affects only legs recorded, and deposits landed, after the call (D4).
    function setRedeemDelay(uint64 d) external override onlyOwner {
        if (d < minRedeemDelay || d >= redeemFulfillTimeout) revert InvalidState();
        redeemDelay = d;
        emit RedeemDelaySet(d);
    }

    /// @notice ADR-030 D10: the only redeem batch `executeRedeem` will accept now (0 = none open).
    function oldestOpenRedeem() public view override returns (uint64) {
        for (uint256 i = redeemHead; i < redeemQueue.length; i++) {
            PendingRedeem storage r = pendingRedeem[redeemQueue[i]];
            if (!r.executed && !r.aborted) return redeemQueue[i];
        }
        return 0;
    }

    /// @dev Called after every execute or abort; each entry is skipped at most once.
    function _advanceRedeemHead() internal {
        uint256 i = redeemHead;
        uint256 n = redeemQueue.length;
        while (i < n) {
            PendingRedeem storage r = pendingRedeem[redeemQueue[i]];
            if (!r.executed && !r.aborted) break;
            i++;
        }
        redeemHead = i;
    }

    /// @dev Recovery splits by failure mode (ADR-015 D9).
    /// TOKENS NOT HERE YET -> revert. Hyperlane writes its delivery mark before calling
    /// `handle`, in the same tx, with no try/catch (`Mailbox.sol:225` then `:241`), so the
    /// revert rolls it back and `delivered()` reads false again (`:361`); `process` has no
    /// access control (`:202`). The message therefore stays re-processable by ANYONE,
    /// forever, at no cost - that is the retry, and it needs no state here.
    /// TOKENS HERE -> record BEFORE attempting, so a deposit that can never succeed is
    /// still recoverable by executeDeposit / abortDeposit.
    function _onInstruction(uint32, Instruction memory instr) internal override {
        if (instr.kind == RequestKind.Subscribe) {
            PendingDeposit storage p = pending[instr.legId];
            if (p.exists) return; // idempotent at the handler (Art 4.1), not just at the mailbox

            uint256 amount = instr.amount * usdcUnit;
            if (usdc.balanceOf(address(this)) < pendingDepositAssets + amount) revert NotReadyToExecute();

            p.amount = amount;
            p.navAtInitiate = instr.navAtInitiate;
            p.exists = true;
            p.deadline = uint64(block.timestamp + subFulfillTimeout);
            pendingDepositAssets += amount; // committed until executed or aborted

            if (!_tryDeposit(instr.legId)) emit SubDepositDeferred(instr.legId);
            return;
        }
        if (instr.kind == RequestKind.Redeem) {
            _recordRedeem(instr.legId, instr.amount * rwaUnit);
            return;
        }
        revert InvalidState();
    }

    /// @dev Record a net-redeem batch whose wRWA shares have arrived. Rendezvous on the executor's
    /// OWN vault-share balance minus what is already committed to other recorded-not-resolved
    /// batches (pendingRedeemShares) — a naive balance check would let batch B record against batch
    /// A's still-held shares (false rendezvous -> executeRedeem(B) later burns A's shares). Not
    /// latched: an instruction-before-shares delivery reverts and stays re-processable by anyone.
    function _recordRedeem(uint64 legId, uint256 shares) internal {
        PendingRedeem storage r = pendingRedeem[legId];
        if (r.exists) return; // idempotent at the handler
        if (IERC20(rwaToken).balanceOf(address(this)) < pendingRedeemShares + shares) {
            revert NotReadyToExecute();
        }
        r.shares = shares;
        // Record-time local read (ADR-026): this is the number the issuer must fund before the
        // redeem can run. Fixed on purpose -- recomputing it at execute time would turn the
        // issuer's funding target into a moving one it can never hit. Guarded against 0: an
        // uninitialised or mis-pointed source must never record a leg with a zero funding target
        // (the rendezvous gate in executeRedeem would then pass trivially).
        uint256 navAtRecord = rwaConversion.value();
        if (navAtRecord == 0) revert ZeroNav();
        r.navAtInitiate = navAtRecord;
        r.grossAssets = Math.mulDiv(shares * usdcUnit, navAtRecord, 1e18 * rwaUnit);
        r.deadline = uint64(block.timestamp + redeemFulfillTimeout);
        r.exists = true;
        r.notBefore = uint64(block.timestamp) + redeemDelay;
        redeemQueue.push(legId);
        pendingRedeemShares += shares;
        emit RedeemRecorded(legId, shares, r.grossAssets);
    }

    /// @notice Permissionless poke that completes a recorded leg. Loud: it reverts so a
    /// keeper learns why nothing happened.
    function executeDeposit(uint64 batchId) external override nonReentrant {
        PendingDeposit storage p = pending[batchId];
        // separate the two failure modes so a keeper learns which one it hit
        if (!p.exists || p.executed || p.aborted) revert InvalidState();
        if (usdc.balanceOf(address(this)) < p.amount) revert NotReadyToExecute();
        if (!_tryDeposit(batchId)) revert NotReadyToExecute(); // the deposit call itself reverted
    }

    /// @notice Permissionless recovery for a recorded-but-unexecutable leg past its deadline
    /// (spec §7.5). Try-then-abort: attempts the deposit once more — the KYC/canDeposit gate may
    /// have reopened, in which case the subscriber gets wRWA (the better outcome, no abort); only
    /// if it still cannot deposit does the USDC go home for a refund. Loud: reverts so a keeper
    /// learns why nothing happened.
    function abortDeposit(uint64 batchId) external override nonReentrant {
        PendingDeposit storage p = pending[batchId];
        if (!p.exists || p.executed || p.aborted) revert BatchAlreadyResolved();
        if (block.timestamp < p.deadline) revert AbortBeforeDeadline();
        if (_tryDeposit(batchId)) return; // gate reopened — deposit completed, no abort

        p.aborted = true; // latch before the outbound send (a send revert rolls it back → still abortable)
        pendingDepositAssets -= p.amount; // the USDC leaves home over the route
        Instruction memory ret = Instruction({
            legId: batchId, kind: RequestKind.SubAborted, amount: p.amount / usdcUnit, navAtInitiate: p.navAtInitiate
        });
        // usdcRoute bridges p.amount of USDC back, unlocking the original Sepolia USDC to REXPrimary.
        // approveToken = usdc so _sendPair forceApproves the route: a collateral route pulls via
        // safeTransferFrom (needs the allowance); a synthetic route burns and ignores it (harmless).
        // A recorded-not-executed leg always still holds its USDC (Task 2 keeps the floor-breach path
        // from removing it), so this send is always funded.
        lastReturnLeg = _sendPair(homeDomain, usdcRoute, usdc, p.amount, ret);
        emit SubDepositAborted(batchId);
    }

    /// @notice Permissionless poke that completes the oldest recorded redeem once its wait is over and
    /// the vault can pay it (ADR-030). Loud: every refusal reverts with its reason.
    function executeRedeem(uint64 batchId) external override nonReentrant {
        PendingRedeem storage r = pendingRedeem[batchId];
        if (!r.exists || r.executed || r.aborted) revert InvalidState();
        this._redeemSelf(batchId);
    }

    /// @notice Permissionless recovery past the deadline (ADR-030 D11): attempt the redemption first --
    /// every gate included -- and send the shares home only if the attempt fails. No balance forecast
    /// decides between the two endings. If the attempt runs out of gas, the 1/64 left cannot pay for
    /// this send, so a caller cannot force a payable batch into abort -- true for the batch at the
    /// head; a non-head batch past its deadline always fails its `_redeemSelf` attempt on the head
    /// check and is aborted regardless of payability, by design (ADR-030 D10).
    function abortRedeem(uint64 batchId) external override nonReentrant {
        PendingRedeem storage r = pendingRedeem[batchId];
        if (!r.exists || r.executed || r.aborted) revert BatchAlreadyResolved();
        if (block.timestamp < r.deadline) revert AbortBeforeDeadline();
        try this._redeemSelf(batchId) {
            return;
        } catch {}

        r.aborted = true;
        pendingRedeemShares -= r.shares;
        _advanceRedeemHead();
        Instruction memory ret = Instruction({
            legId: batchId, kind: RequestKind.RedeemAborted, amount: r.shares / rwaUnit, navAtInitiate: r.navAtInitiate
        });
        lastReturnLeg = _sendPair(homeDomain, wrwaRoute, IERC20(rwaToken), r.shares, ret);
        emit RedeemBatchAborted(batchId);
    }

    /// @notice ADR-030 D9: what the vault will charge for this batch right now.
    function redeemTarget(uint64 batchId) external view override returns (uint256) {
        return IRWAToken(rwaToken).convertToAssets(pendingRedeem[batchId].shares);
    }

    /// @dev Self-only: the whole redemption as one frame, so a failure anywhere -- a gate, the vault, the
    /// floor, or the send home -- rolls everything back.
    function _redeemSelf(uint64 batchId) external {
        if (msg.sender != address(this)) revert UnauthorizedSender();
        PendingRedeem storage r = pendingRedeem[batchId];
        if (batchId != oldestOpenRedeem()) revert NotReadyToExecute(); // D10
        if (block.timestamp < r.notBefore || block.timestamp < depositUnlockAt) revert NotReadyToExecute(); // D1
        // D7: ask the vault what it will charge, live -- never the record-time figure.
        if (usdc.balanceOf(rwaToken) < IRWAToken(rwaToken).convertToAssets(r.shares)) revert NotReadyToExecute();

        uint256 navNow = rwaConversion.value(); // D8: the floor stays on the oracle
        if (navNow == 0) revert ZeroNav();
        uint256 usdcOut = IRWAToken(rwaToken).redeem(r.shares, address(this), address(this));
        uint256 floor =
            Math.mulDiv(Math.mulDiv(r.shares * usdcUnit, navNow, 1e18 * rwaUnit), 1e4 - executorSlippageBps, 1e4);
        uint256 sendable = usdcOut - usdcOut % usdcUnit;
        if (sendable == 0) revert SlippageExceeded();
        if (usdcOut < floor) revert SlippageExceeded();

        r.executed = true;
        pendingRedeemShares -= r.shares;
        _advanceRedeemHead();
        Instruction memory ret = Instruction({
            legId: batchId, kind: RequestKind.Redeem, amount: sendable / usdcUnit, navAtInitiate: r.navAtInitiate
        });
        lastReturnLeg = _sendPair(homeDomain, usdcRoute, usdc, sendable, ret);
        emit RedeemBatchFulfilled(batchId, sendable);
    }

    /// @notice Local mirror of `IREXGovernance.Swept` -- kept off `IPruvExecutor` so `/shared`
    /// stays 0-diff for this executor-only backstop.
    event Swept(address indexed token, address indexed to, uint256 amount);

    /// @notice SC6b: admin backstop for stray/mis-sent tokens (design §7). `usdc` is recoverable
    /// down to its committed floor (`pendingDepositAssets`, H-1/M-2/M-6) -- the float above every
    /// recorded-not-resolved deposit leg's escrow is provably free. `rwaToken` stays fully excluded.
    /// @dev `rwaToken` shares can transiently exceed their accounted reservation during an
    /// unordered bridge rendezvous (spec §3.4), and the executor has no signal for an
    /// incoming-but-unrecorded redeem -- so its "free above pendingRedeemShares" slice can't be
    /// safely bounded (cf. Aave `AToken.rescueTokens`'s `UNDERLYING_CANNOT_BE_RESCUED`). `usdc` has
    /// no such blind spot: every USDC leg is recorded before its money can be spent, so
    /// `pendingDepositAssets` always accounts for the full committed slice.
    function sweep(address token, address to, uint256 amount) external onlyOwner nonReentrant {
        if (token == rwaToken) revert InvalidState();
        uint256 free = IERC20(token).balanceOf(address(this));
        if (token == address(usdc)) free -= pendingDepositAssets; // M-6: float no longer write-only
        if (amount > free) revert InvalidState();
        SafeERC20.safeTransfer(IERC20(token), to, amount);
        emit Swept(token, to, amount);
    }

    /// @dev AT-190: approve every token the WithFee `route` pulls (quotes[1..]), grouped by token
    /// so a token appearing twice (amount + same-token fee) is approved once for its total.
    /// quotes[0] is native gas (paid as msg.value). Reverts FeeTokenInsufficient if the held
    /// balance (USDC float) is short. `approveToken`/`amount` are unused: the quote array is
    /// authoritative for what the route will pull.
    function _approveForRoute(IWarpRoute route, Quote[] memory quotes, IERC20, uint256) internal override {
        for (uint256 i = 1; i < quotes.length; i++) {
            address token = quotes[i].token;
            if (token == address(0)) continue;
            bool seen;
            for (uint256 j = 1; j < i; j++) {
                if (quotes[j].token == token) {
                    seen = true;
                    break;
                }
            }
            if (seen) continue;
            uint256 total;
            for (uint256 k = i; k < quotes.length; k++) {
                if (quotes[k].token == token) total += quotes[k].amount;
            }
            uint256 held = IERC20(token).balanceOf(address(this));
            uint256 reserved =
                token == address(usdc) ? pendingDepositAssets : token == rwaToken ? pendingRedeemShares : 0;
            // Saturating: after a Pruv adminBurn the reserve can exceed the balance; fail as a shortfall,
            // not as a panic (SC13 §3.5).
            held = held > reserved ? held - reserved : 0;
            if (held < total) revert FeeTokenInsufficient(token, total, held);
            SafeERC20.forceApprove(IERC20(token), address(route), total);
        }
    }

    /// @dev Returns false instead of reverting so callers keep the leg recoverable.
    function _tryDeposit(uint64 batchId) internal returns (bool) {
        PendingDeposit storage p = pending[batchId];
        if (!p.exists || p.executed || p.aborted) return false;
        if (usdc.balanceOf(address(this)) < p.amount) return false;
        try this._depositChecked(batchId) {
            return true;
        } catch {
            return false;
        }
    }

    /// @dev Self-only: deposit, floor, latch, the D1 stamp AND the send home in one frame (ADR-030 D11,
    /// F-B4-1). A failed send rolls the deposit back, so `abortDeposit` can still refund the USDC.
    function _depositChecked(uint64 batchId) external {
        if (msg.sender != address(this)) revert UnauthorizedSender();
        PendingDeposit storage p = pending[batchId];
        SafeERC20.forceApprove(usdc, rwaToken, p.amount);
        uint256 shares = IRWAToken(rwaToken).deposit(p.amount, address(this));
        uint256 navNow = rwaConversion.value();
        uint256 floor =
            Math.mulDiv(Math.mulDiv(p.amount * rwaUnit, 1e18, navNow * usdcUnit), 1e4 - executorSlippageBps, 1e4);
        // The sub-unit remainder of shares stays here; it is below one micro-unit.
        uint256 sendable = shares - shares % rwaUnit;
        if (sendable == 0) revert SlippageFloorBreached();
        if (shares < floor) revert SlippageFloorBreached();

        p.executed = true;
        pendingDepositAssets -= p.amount;
        depositUnlockAt = uint64(block.timestamp) + redeemDelay;
        Instruction memory ret = Instruction({
            legId: batchId, kind: RequestKind.Subscribe, amount: sendable / rwaUnit, navAtInitiate: p.navAtInitiate
        });
        lastReturnLeg = _sendPair(homeDomain, wrwaRoute, IERC20(rwaToken), sendable, ret);
        emit SubDepositExecuted(batchId, p.amount, sendable);
    }

    function onERC1155Received(address, address, uint256, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC1155Received.selector;
    }

    function onERC1155BatchReceived(address, address, uint256[] calldata, uint256[] calldata, bytes calldata)
        external
        pure
        returns (bytes4)
    {
        return this.onERC1155BatchReceived.selector;
    }

    function supportsInterface(bytes4 id) public pure override returns (bool) {
        return id == type(IERC1155Receiver).interfaceId || id == type(IERC165).interfaceId;
    }

    /// @dev Accept native so ops can fund a gas float. PRUV gas is 0
    /// (`config-values.md`), so the outbound quote is expected to be ~0 — this exists
    /// only so the executor is not a dead end if that assumption turns out false.
    receive() external payable {}
}
