// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @dev The emptiness predicate's only failure mode of its own. Every other guard REUSES the
/// vocabulary already frozen in IREXRegistry.sol (FundAlreadyRegistered / FundNotRegistered /
/// NotAContract / InvalidStatus / IndexOutOfBounds) and Errors.sol (InvalidState /
/// UnenrolledRemote / RenounceDisabled), so a v1 client's decoder still understands v2.
error FundNotEmpty(address rexPrimary);

/// @notice The frozen discovery surface of REXRegistryV2 (ADR-032, amending ADR-021).
///
/// A FLAT directory keyed by the REXPrimary address. There is no version chain: `rwaToken` is an
/// attribute, several funds may share one, and a superseded deployment is marked `Retired` rather
/// than pushed down a chain.
///
/// Discovery-only and OFF the money path (ADR-019): no money-path contract reads it, and REXPrimary
/// behaves identically whether or not a fund is registered. `Retired` does NOT stop anything on
/// chain and does NOT mean "stop indexing" — ADR-011 keeps a superseded deployment's receipts
/// claimable forever, so a consumer indexes every registered contract regardless of status.
interface IREXRegistryV2 {
    /// @notice Coarse listing state. `None` means "not registered" and is never settable.
    enum FundStatus {
        None,
        Pending,
        Active,
        Retired
    }

    /// @notice One directory row. Returned whole so a client resolves a fund in one call.
    struct Fund {
        address rexPrimary;
        address rwaToken;
        address issuer;
        FundStatus status;
    }

    event FundRegistered(address indexed rexPrimary, address indexed rwaToken, address issuer);
    event FundUnregistered(address indexed rexPrimary);
    event FundStatusChanged(address indexed rexPrimary, uint8 status);
    event FundIssuerChanged(address indexed rexPrimary, address issuer);

    function register(address rexPrimary, address rwaToken, address issuer) external;

    /// @notice Removes a deployment from the directory. Reverts `FundNotEmpty` unless the target
    /// owes nobody anything: `state()` is ShutDown AND all four reserve counters and both
    /// outstanding-batch counters read zero. The contract enforces it so the judgement is never a
    /// human's. Reverts if the target does not expose those getters — failing closed is intended.
    function unregister(address rexPrimary) external;

    function setStatus(address rexPrimary, FundStatus status) external;
    function setIssuer(address rexPrimary, address issuer) external;

    /// @notice Increments on EVERY mutating call, including one that stores a value already there.
    /// A poller reads this one word and re-reads `allFunds()` only when it moves.
    function revision() external view returns (uint256);

    /// @notice The stored row. An unregistered address reads back all-zero with status `None`;
    /// it never reverts.
    function fund(address rexPrimary) external view returns (Fund memory);

    function statusOf(address rexPrimary) external view returns (FundStatus);

    /// @notice The whole directory in ONE call — the path for a client with only an RPC endpoint.
    function allFunds() external view returns (Fund[] memory);

    /// @notice Single-index accessor for a directory large enough to strain an eth_call gas cap.
    /// @dev Indices are NOT stable: `unregister` swaps the last row into the removed slot, so a
    /// client paginating across separate calls can miss a fund. Read `allFunds()` in one call, or
    /// pin a block.
    function fundAt(uint256 index) external view returns (Fund memory);

    function fundCount() external view returns (uint256);
}
