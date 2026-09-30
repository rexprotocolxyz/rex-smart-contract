// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Registry-specific errors. Zero-address, unenrolled-remote and renounce guards deliberately
// REUSE the frozen vocabulary in Errors.sol (InvalidState / UnenrolledRemote / RenounceDisabled).
error FundAlreadyRegistered(address rexPrimary);
error FundNotRegistered(address rexPrimary);
error NotAContract(address target);
error InvalidStatus();
/// @dev `keyAt` was called past the end of the key list. Named rather than a bare array panic so
/// a direct-RPC client paginating the directory gets something it can decode.
error IndexOutOfBounds(uint256 index, uint256 length);
/// @dev `registerBefore`'s `successor` is not a member of that fund's version chain, so there is
/// no position to insert in front of.
error NotInChain(address successor, bytes32 key);

/// @notice The frozen discovery surface of REXRegistry (ADR-021, spec section 17.3). REXRegistry
/// `is` this, so the compiler enforces conformance. FROZEN (shared-v1.9; v1.8 plus the purely
/// ADDITIVE `registerBefore` / `latestOfToken` and two new errors -- no v1.8 signature changed,
/// so a v1.8 consumer stays valid).
///
/// The Registry is a DIRECTORY, never a gate: no money-path contract reads it, and setting a fund
/// to Retired or unregistering it does not stop anything on-chain. To halt a fund, the guardian
/// calls pause() on that REXPrimary.
interface IREXRegistry {
    /// @notice Coarse listing state. `None` means "not registered" and is never settable.
    enum FundStatus {
        None,
        Pending,
        Active,
        Retired
    }

    event FundRegistered(bytes32 indexed key, address indexed rexPrimary);
    event FundUnregistered(bytes32 indexed key, address indexed rexPrimary);
    event FundStatusChanged(address indexed rexPrimary, uint8 status);
    event FundIssuerChanged(address indexed rexPrimary, address issuer);

    function register(address rexPrimary, address rwaToken, address issuer) external;

    /// @notice `register`, but inserting immediately BEFORE `successor` in that fund's version
    /// chain instead of appending at the tail. This is the restore path: `register` always
    /// appends, so putting a mistakenly-unregistered OLDER version back would otherwise make it
    /// `latestOf` -- silently, since the home chain cannot know deploy order.
    function registerBefore(address rexPrimary, address rwaToken, address issuer, address successor) external;

    function unregister(address rexPrimary) external;
    function setStatus(address rexPrimary, FundStatus status) external;
    function setIssuer(address rexPrimary, address issuer) external;

    /// @notice The stored row. Never reverts: an unregistered address reads back as all-zero/None.
    function fund(address rexPrimary)
        external
        view
        returns (bytes32 key, address issuer, FundStatus status);
    function statusOf(address rexPrimary) external view returns (FundStatus);
    function isRegistered(address rexPrimary) external view returns (bool);

    /// @notice Every REXPrimary this fund has had, in deploy order; the last entry is the newest.
    function versionsOf(bytes32 key) external view returns (address[] memory);
    function latestOf(bytes32 key) external view returns (address);

    /// @notice `latestOf` keyed by the fund token itself, so a client never has to reproduce the
    /// `bytes32(uint256(uint160(rwaToken)))` packing by hand.
    function latestOfToken(address rwaToken) external view returns (address);

    /// @notice The whole key list in ONE call. Prefer this over paginating `keyAt`: removing a
    /// fund swaps the last key into the removed slot, so indices are not stable across
    /// transactions.
    function allKeys() external view returns (bytes32[] memory);

    /// @notice Single-index accessor into the same list. Reverts `IndexOutOfBounds` past the end.
    /// Indices shift when a fund is unregistered -- see `allKeys`.
    function keyAt(uint256 index) external view returns (bytes32);
    function fundCount() external view returns (uint256);

    /// @notice Stored row PLUS the fields read live from the REXPrimary itself. Reverts if the
    /// fund is unregistered, or if the REXPrimary no longer exposes one of the read getters --
    /// failing loudly beats serving a stale answer. It does not fail loudly on every stale
    /// condition, though: if the remote is unenrolled AFTER registration, `executor` reads back
    /// as `address(0)` rather than reverting (only `register` itself reverts `UnenrolledRemote`).
    function fundInfo(address rexPrimary)
        external
        view
        returns (
            bytes32 key,
            address issuer,
            FundStatus status,
            address executor,
            address wrwaRoute,
            address navOracle,
            string memory version
        );
}
