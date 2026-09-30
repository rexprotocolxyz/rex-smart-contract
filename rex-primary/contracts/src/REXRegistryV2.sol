// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@rex-shared/Errors.sol";
import "@rex-shared/IREXRegistry.sol";
import "@rex-shared/IREXRegistryV2.sol";

/// @notice The getters REXRegistryV2 reads off a REXPrimary. Declared HERE, consumer-side, and
/// deliberately NOT added to the frozen IREXPrimary: REXPrimary.wrwaRoute returns `IWarpRoute`, so
/// an interface REXPrimary `is` could not declare it as `address`. At the ABI level a contract type
/// and `address` are the same 32 bytes, so casting an address to this interface decodes correctly.
interface IREXPrimaryView {
    function wrwaRoute() external view returns (address);
    function pruvDomain() external view returns (uint32);
    function remoteRouter(uint32 domain) external view returns (bytes32);
}

/// @notice What the unregister predicate reads off a REXPrimary. `state()` returns the
/// `LifecycleState` enum, which is a `uint8` at the ABI level.
interface IREXPrimaryEmptiness {
    function state() external view returns (uint8);
    function heldEscrowUSDC() external view returns (uint256);
    function settledRedeemUSDC() external view returns (uint256);
    function liveRedeemEscrow() external view returns (uint256);
    function settledUnclaimed() external view returns (uint256);
    function outstandingSubBatches() external view returns (uint64);
    function outstandingRedeemBatches() external view returns (uint64);
}

/// @notice The global home-chain fund directory, flat (ADR-032, amending ADR-021).
///
/// Discovery-only and OFF the money path (ADR-019): no money-path contract reads it, and REXPrimary
/// behaves identically whether or not a fund is registered.
///
/// Keyed by the REXPrimary address, because a key has to be unique per fund and `rwaToken` is not —
/// several funds may share one token, which v1's version chain could only render as one superseding
/// the other. Superseding is `FundStatus.Retired`, per contract.
contract REXRegistryV2 is Ownable2Step, IREXRegistryV2 {
    Fund[] private _funds;
    /// @dev rexPrimary -> index into `_funds`, PLUS ONE, so 0 reads as "absent" without a sentinel.
    mapping(address => uint256) private _indexPlusOne;

    /// @inheritdoc IREXRegistryV2
    uint256 public revision;

    /// @dev `LifecycleState.ShutDown` — the only state in which no new money can enter. Subscribe
    /// is already off in WindDown, but redemption stays open there (REXPrimary.sol:867, spec
    /// section 7.7 step 3), so a wound-down contract with zero balances can still acquire an
    /// obligation tomorrow.
    uint8 private constant SHUT_DOWN = 4;

    constructor() Ownable(msg.sender) {}

    /// @notice Renounce would permanently freeze the directory -- the contract is immutable
    /// (ADR-011), so there is no way to restore an owner.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Records a deployed REXPrimary. Validates only `wrwaRoute` (non-zero) and
    /// `remoteRouter(pruvDomain())` (enrolled) off `rexPrimary` itself -- enough to reject an
    /// address that is not a wired REXPrimary, without snapshotting anything mutable.
    function register(address rexPrimary, address rwaToken, address issuer) external onlyOwner {
        if (rexPrimary == address(0) || rwaToken == address(0) || issuer == address(0)) {
            revert InvalidState();
        }
        if (rexPrimary.code.length == 0) revert NotAContract(rexPrimary);
        if (_indexPlusOne[rexPrimary] != 0) revert FundAlreadyRegistered(rexPrimary);

        IREXPrimaryView p = IREXPrimaryView(rexPrimary);
        if (p.wrwaRoute() == address(0)) revert InvalidState();
        if (p.remoteRouter(p.pruvDomain()) == bytes32(0)) revert UnenrolledRemote();

        _funds.push(Fund({rexPrimary: rexPrimary, rwaToken: rwaToken, issuer: issuer, status: FundStatus.Active}));
        _indexPlusOne[rexPrimary] = _funds.length;
        ++revision;

        emit FundRegistered(rexPrimary, rwaToken, issuer);
    }

    /// @dev Shared lookup for the two setters: reverts rather than returning a zero index, so a
    /// caller can never silently edit slot 0.
    function _rowOf(address rexPrimary) private view returns (Fund storage) {
        uint256 i = _indexPlusOne[rexPrimary];
        if (i == 0) revert FundNotRegistered(rexPrimary);
        return _funds[i - 1];
    }

    /// @notice Sets a fund's coarse listing state. `None` is the not-registered sentinel and is
    /// never settable. Transitions among Pending/Active/Retired are free in both directions: the
    /// contract is immutable, so locking Retired as terminal would make a mistaken retirement
    /// permanent.
    ///
    /// `Retired` never means "stop indexing" -- ADR-011 keeps a superseded deployment's receipts
    /// claimable, so a consumer watches every registered contract whatever its status.
    function setStatus(address rexPrimary, FundStatus status) external onlyOwner {
        if (status == FundStatus.None) revert InvalidStatus();
        _rowOf(rexPrimary).status = status;
        ++revision;
        emit FundStatusChanged(rexPrimary, uint8(status));
    }

    /// @notice Corrects the attested issuer. Attestations are admin-editable by design (ADR-021
    /// decision 2, unchanged by ADR-032) -- the directory moves no money, and an uncorrectable typo
    /// on an immutable contract would be permanent.
    function setIssuer(address rexPrimary, address issuer) external onlyOwner {
        // Same reason `register` requires it: zero must not be reachable by omission.
        if (issuer == address(0)) revert InvalidState();
        _rowOf(rexPrimary).issuer = issuer;
        ++revision;
        emit FundIssuerChanged(rexPrimary, issuer);
    }

    /// @notice Removes a deployment from the directory. The DEFAULT IS NEVER TO CALL THIS: a dead
    /// contract costs nothing to keep (the crawler issues one getLogs across the whole address
    /// list, and a contract that emits nothing adds no request), while removing one that still owes
    /// a holder costs them the visibility of their position permanently, and fails silently,
    /// because a dead contract is supposed to be quiet. This is a broom, not a lifecycle step.
    ///
    /// Reverts `FundNotEmpty` unless the target owes nobody anything. The contract enforces the
    /// predicate so the judgement is never a human's. A REXPrimary that does not expose all seven
    /// getters makes this revert and can never be unregistered -- failing closed is intended. So
    /// does a `LaunchpadFail` fund (`state()` == 2): `triggerWindDown` requires `EpochBased` and
    /// `triggerShutDown` requires `WindDown`, so a failed launchpad has no path to `ShutDown` and
    /// this always reverts for it -- correct fail-closed behaviour, but an operator refunding a
    /// failed launchpad may expect it to become removable.
    ///
    /// Safely reversible: `register` again -- there is no chain position to repair, which is why
    /// v1's `registerBefore` has no counterpart here. Note `register` always writes back `Active`
    /// (see above), so a re-registered fund reads Active even though its on-chain lifecycle is
    /// still `ShutDown`; follow a re-register with `setStatus(Retired)` if that is not the intent.
    function unregister(address rexPrimary) external onlyOwner {
        uint256 i = _indexPlusOne[rexPrimary];
        if (i == 0) revert FundNotRegistered(rexPrimary);
        if (!_isEmpty(rexPrimary)) revert FundNotEmpty(rexPrimary);

        uint256 last = _funds.length - 1;
        uint256 at = i - 1;
        if (at != last) {
            Fund storage moved = _funds[last];
            _funds[at] = moved;
            // Rewrite the moved row's index, or `fund()` resolves it to the slot it just left.
            _indexPlusOne[moved.rexPrimary] = at + 1;
        }
        _funds.pop();
        delete _indexPlusOne[rexPrimary];
        ++revision;

        emit FundUnregistered(rexPrimary);
    }

    /// @dev The seven conditions under which a REXPrimary owes nobody anything. The four reserve
    /// counters are exactly what `REXPrimary._reservedBalance` nets out of a sweep, so zero on all
    /// four means no holder can still claim, cancel or refund against this contract.
    function _isEmpty(address rexPrimary) private view returns (bool) {
        IREXPrimaryEmptiness p = IREXPrimaryEmptiness(rexPrimary);
        return p.state() == SHUT_DOWN && p.heldEscrowUSDC() == 0 && p.settledRedeemUSDC() == 0
            && p.liveRedeemEscrow() == 0 && p.settledUnclaimed() == 0 && p.outstandingSubBatches() == 0
            && p.outstandingRedeemBatches() == 0;
    }

    function fund(address rexPrimary) external view returns (Fund memory) {
        uint256 i = _indexPlusOne[rexPrimary];
        if (i == 0) {
            return Fund({rexPrimary: address(0), rwaToken: address(0), issuer: address(0), status: FundStatus.None});
        }
        return _funds[i - 1];
    }

    function statusOf(address rexPrimary) external view returns (FundStatus) {
        uint256 i = _indexPlusOne[rexPrimary];
        return i == 0 ? FundStatus.None : _funds[i - 1].status;
    }

    function allFunds() external view returns (Fund[] memory) {
        return _funds;
    }

    function fundAt(uint256 index) external view returns (Fund memory) {
        if (index >= _funds.length) revert IndexOutOfBounds(index, _funds.length);
        return _funds[index];
    }

    function fundCount() external view returns (uint256) {
        return _funds.length;
    }
}
