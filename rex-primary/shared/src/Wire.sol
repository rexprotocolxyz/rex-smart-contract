// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Cross-chain payload types. FROZEN — the wire is versioned (see Codec.sol); changing or
/// removing a field, or renumbering an existing value, needs a new wire version. APPENDING a
/// `RequestKind` decoded only by the redeployable REXPrimary is byte-additive within a version and needs
/// no bump (an executor-inbound kind would; see ADR-016).
enum RequestKind {
    Subscribe,
    Redeem,
    SubAborted,     // subscribe abort return (SC4)
    RedeemAborted   // redeem abort return (reserved — SC5)
}

struct Instruction {
    uint64 legId;
    RequestKind kind;
    uint256 amount;
    uint256 navAtInitiate;
}
