// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "@openzeppelin/contracts/access/Ownable2Step.sol";
import "@rex-shared/Errors.sol";
import "@rex-shared/IREXRegistry.sol";

/// @notice The five getters REXRegistry reads off a REXPrimary. Declared HERE, consumer-side, and
/// deliberately NOT added to the frozen IREXPrimary: REXPrimary.wrwaRoute returns `IWarpRoute` and
/// navOracle returns `INavOracle`, so an interface REXPrimary `is` could not declare them as
/// `address`. At the ABI level a contract type and `address` are the same 32 bytes, so casting an
/// address to this interface and calling decodes correctly.
interface IREXPrimaryInfo {
    function wrwaRoute() external view returns (address);
    function pruvDomain() external view returns (uint32);
    function remoteRouter(uint32 domain) external view returns (bytes32);
    function navOracle() external view returns (address);
    function VERSION() external view returns (string memory);
}

/// @notice The global home-chain fund directory (ADR-019 as amended by ADR-021, spec section 17.3).
/// Discovery-only and OFF the money path: no money-path contract reads it, and REXPrimary behaves
/// identically whether or not a fund is registered.
///
/// Keyed by the PRUV `rwaToken` -- the fund's real identity, which survives both a REXPrimary
/// redeploy and a warp-route redeploy (ADR-021 decision 1). Everything derivable from a REXPrimary
/// is read LIVE at call time rather than snapshotted, because `remoteRouter` is mutable via
/// `enrollRemote` (ADR-021 decision 4).
contract REXRegistry is Ownable2Step, IREXRegistry {
    struct Fund {
        bytes32 key;
        address issuer;
        FundStatus status;
    }

    mapping(address => Fund) private _funds; // rexPrimary -> stored row
    mapping(bytes32 => address[]) private _versions; // key -> every REXPrimary, deploy order
    bytes32[] private _keys; // every registered fund, for enumeration

    constructor() Ownable(msg.sender) {}

    /// @notice Renounce would permanently freeze the directory -- the contract is immutable
    /// (ADR-011), so there is no way to restore an owner.
    function renounceOwnership() public pure override {
        revert RenounceDisabled();
    }

    /// @notice Records a deployed REXPrimary at the TAIL of its fund's version chain -- the normal
    /// path, since a newly deployed version is the newest one. Validates only `wrwaRoute`
    /// (non-zero) and `remoteRouter(pruvDomain())` (enrolled) off `rexPrimary` itself; `navOracle`
    /// and `VERSION` are never called here -- they are first exercised by `fundInfo`.
    ///
    /// To put a mistakenly-unregistered OLDER version back, use `registerBefore` instead: this
    /// function always appends, and the home chain cannot tell that the address it is appending
    /// was deployed before the one already at the tail.
    function register(address rexPrimary, address rwaToken, address issuer_) external onlyOwner {
        bytes32 key = _validateAndKey(rexPrimary, rwaToken, issuer_);

        if (_versions[key].length == 0) _keys.push(key);
        _versions[key].push(rexPrimary);
        _record(rexPrimary, key, issuer_);
    }

    /// @notice `register`, but taking the position immediately BEFORE `successor` in that fund's
    /// chain rather than the tail. The restore path for an entry removed by mistake: one
    /// transaction, and `latestOf` cannot regress. `successor` must already be in this key's
    /// chain, so the caller states exactly where the entry belongs instead of relying on call
    /// order.
    function registerBefore(address rexPrimary, address rwaToken, address issuer_, address successor)
        external
        onlyOwner
    {
        bytes32 key = _validateAndKey(rexPrimary, rwaToken, issuer_);

        address[] storage v = _versions[key];
        uint256 n = v.length;
        uint256 at = n;
        for (uint256 i; i < n; ++i) {
            if (v[i] == successor) {
                at = i;
                break;
            }
        }
        if (at == n) revert NotInChain(successor, key);

        // Grow by one, then shift the tail right so `at` is free. The chain is a handful of
        // entries per fund (one per REXPrimary version, ADR-011), so the shift is bounded.
        v.push(v[n - 1]);
        for (uint256 j = n - 1; j > at; --j) {
            v[j] = v[j - 1];
        }
        v[at] = rexPrimary;

        _record(rexPrimary, key, issuer_);
    }

    /// @dev The guards both register paths share, returning the derived key. `issuer_` is
    /// required: `rexPrimary` and `rwaToken` are already rejected when zero, and silently
    /// accepting a zero issuer would let a forgotten field read as a deliberate "unattested".
    function _validateAndKey(address rexPrimary, address rwaToken, address issuer_) private view returns (bytes32) {
        if (rexPrimary == address(0) || rwaToken == address(0) || issuer_ == address(0)) {
            revert InvalidState();
        }
        if (rexPrimary.code.length == 0) revert NotAContract(rexPrimary);
        if (_funds[rexPrimary].key != bytes32(0)) revert FundAlreadyRegistered(rexPrimary);

        IREXPrimaryInfo p = IREXPrimaryInfo(rexPrimary);
        if (p.wrwaRoute() == address(0)) revert InvalidState();
        if (p.remoteRouter(p.pruvDomain()) == bytes32(0)) revert UnenrolledRemote();

        return bytes32(uint256(uint160(rwaToken)));
    }

    function _record(address rexPrimary, bytes32 key, address issuer_) private {
        _funds[rexPrimary] = Fund({key: key, issuer: issuer_, status: FundStatus.Active});
        emit FundRegistered(key, rexPrimary);
    }

    function fund(address rexPrimary) external view returns (bytes32 key, address issuer_, FundStatus status) {
        Fund storage f = _funds[rexPrimary];
        return (f.key, f.issuer, f.status);
    }

    function isRegistered(address rexPrimary) public view returns (bool) {
        return _funds[rexPrimary].key != bytes32(0);
    }

    /// @notice Sets a fund's coarse listing state. `None` is the not-registered sentinel and is
    /// never settable. Transitions among Pending/Active/Retired are free in both directions: the
    /// contract is immutable, so locking Retired as terminal would make a mistaken retirement
    /// permanent.
    function setStatus(address rexPrimary, FundStatus status) external onlyOwner {
        Fund storage f = _funds[rexPrimary];
        if (f.key == bytes32(0)) revert FundNotRegistered(rexPrimary);
        if (status == FundStatus.None) revert InvalidStatus();
        f.status = status;
        emit FundStatusChanged(rexPrimary, uint8(status));
    }

    /// @notice Corrects the attested issuer. Attestations are admin-editable by design (ADR-021
    /// decision 2) -- the directory moves no money, and an uncorrectable typo on an immutable
    /// contract would be permanent.
    function setIssuer(address rexPrimary, address issuer_) external onlyOwner {
        Fund storage f = _funds[rexPrimary];
        if (f.key == bytes32(0)) revert FundNotRegistered(rexPrimary);
        // Same reason `register` requires it: zero must not be reachable by omission.
        if (issuer_ == address(0)) revert InvalidState();
        f.issuer = issuer_;
        emit FundIssuerChanged(rexPrimary, issuer_);
    }

    /// @notice Removes a deployment from the directory. `Retired` keeps it listed and marks it
    /// inactive; `FundRegistered` stays in the log either way, and the deployment can be
    /// registered again. Correcting a wrong `rwaToken` is unregister + register, because changing
    /// it changes the key -- i.e. moves the deployment to a different version chain.
    ///
    /// Prefer `setStatus(Retired)` for a fund that is simply finished: it keeps the entry listed
    /// AND keeps its position in the chain. Use `unregister` to remove a wrongly-registered
    /// address or to move one to a different key. If you do need to restore a removed entry that
    /// was NOT the newest, use `registerBefore` -- plain `register` appends at the tail, and the
    /// home chain cannot tell the appended address was deployed earlier, so `latestOf` would
    /// start returning a superseded deployment with no revert and no anomalous event.
    function unregister(address rexPrimary) external onlyOwner {
        bytes32 key = _funds[rexPrimary].key;
        if (key == bytes32(0)) revert FundNotRegistered(rexPrimary);

        address[] storage v = _versions[key];
        uint256 n = v.length;
        for (uint256 i; i < n; ++i) {
            if (v[i] == rexPrimary) {
                // Shift, not swap-and-pop: deploy order is meaningful (latestOf reads the last).
                for (uint256 j = i; j + 1 < n; ++j) {
                    v[j] = v[j + 1];
                }
                v.pop();
                break;
            }
        }
        if (v.length == 0) _removeKey(key);
        delete _funds[rexPrimary];

        emit FundUnregistered(key, rexPrimary);
    }

    /// @dev Swap-and-pop is fine here: `_keys` order carries no meaning.
    function _removeKey(bytes32 key) private {
        uint256 n = _keys.length;
        for (uint256 i; i < n; ++i) {
            if (_keys[i] == key) {
                _keys[i] = _keys[n - 1];
                _keys.pop();
                return;
            }
        }
    }

    function statusOf(address rexPrimary) external view returns (FundStatus) {
        return _funds[rexPrimary].status;
    }

    /// @notice Every REXPrimary this fund has had, in deploy order; the last entry is the newest.
    /// Returned whole so a caller resolves an N-version chain in ONE call.
    function versionsOf(bytes32 key) external view returns (address[] memory) {
        return _versions[key];
    }

    /// @notice The newest REXPrimary for this fund, or the zero address if the key is unknown.
    function latestOf(bytes32 key) external view returns (address) {
        address[] storage v = _versions[key];
        return v.length == 0 ? address(0) : v[v.length - 1];
    }

    /// @notice Every registered fund key. The one-call path for a client with only an RPC endpoint
    /// (spec section 17.4's direct-Registry fallback) -- a Solidity mapping is not enumerable, so
    /// without this a fallback client would have to page eth_getLogs from the deploy block.
    function allKeys() external view returns (bytes32[] memory) {
        return _keys;
    }

    /// @notice `latestOf` keyed by the fund token itself, so no caller has to reproduce the key
    /// packing by hand. Zero address for an unknown token.
    function latestOfToken(address rwaToken) external view returns (address) {
        address[] storage v = _versions[bytes32(uint256(uint160(rwaToken)))];
        return v.length == 0 ? address(0) : v[v.length - 1];
    }

    /// @notice Single-index accessor into the same key list `allKeys()` returns whole, for a fund
    /// count large enough to strain an eth_call gas cap.
    /// @dev Indices are NOT stable across transactions: `unregister` swaps the last key into the
    /// removed slot, so a client paginating this across separate calls can miss a fund entirely
    /// (the key it has not read yet moves behind its cursor). Read `allKeys()` in one call, or pin
    /// a block. Reverts a named `IndexOutOfBounds` rather than a bare array panic.
    function keyAt(uint256 index) external view returns (bytes32) {
        if (index >= _keys.length) revert IndexOutOfBounds(index, _keys.length);
        return _keys[index];
    }

    function fundCount() external view returns (uint256) {
        return _keys.length;
    }

    /// @notice The stored row PLUS the four fields read LIVE off the REXPrimary itself. Nothing
    /// derived is ever snapshotted (ADR-021 decision 4): `remoteRouter` is mutable via
    /// `enrollRemote`, so a stored executor could silently go stale. If a future REXPrimary drops
    /// one of these getters this view reverts -- failing loudly is the intended trade.
    function fundInfo(address rexPrimary)
        external
        view
        returns (
            bytes32 key,
            address issuer_,
            FundStatus status,
            address executor,
            address wrwaRoute,
            address navOracle,
            string memory version
        )
    {
        Fund storage f = _funds[rexPrimary];
        if (f.key == bytes32(0)) revert FundNotRegistered(rexPrimary);

        IREXPrimaryInfo p = IREXPrimaryInfo(rexPrimary);
        executor = address(uint160(uint256(p.remoteRouter(p.pruvDomain()))));
        return (f.key, f.issuer, f.status, executor, p.wrwaRoute(), p.navOracle(), p.VERSION());
    }
}
