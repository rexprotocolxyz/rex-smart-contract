// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {RequestKind} from "@rex-shared/Wire.sol";

// INTERNAL, PROVISIONAL — NOT part of the frozen /shared surface. See shared/README.md.
// ADR-024 deleted `EpochSide.matchedOut` here; `REXPrimary.epochSide()` still returns the frozen
// five-tuple with a literal 0 in that position.

struct Leg {
    bytes32 tokenMsgId;
    bytes32 instrMsgId;
    uint256 returnedAmount;
    bool returnReceived;
    // SC5a: which return arrived for a redeem batch's leg -- `Redeem` (a fulfilled redemption,
    // pays the USDC pot) or `RedeemAborted` (a wRWA refund pot); a subscribe leg is always `Subscribe`.
    RequestKind retKind;
}

/// @notice Batch lifecycle (spec §5). `None` MUST stay first — an unwritten Batch
/// would otherwise read as `Accumulating`, i.e. a batch that does not exist would
/// look open. `Aborted` is SUBSCRIBE-ONLY (ADR-015 Decision 9 said "both legs", but
/// SC5a's `settleRedeemBatch` instead disambiguates via `Leg.retKind`: a redeem
/// batch's abort return still flips to `Settled`, never `Aborted`).
enum BatchStatus {
    None,
    Accumulating,
    Bridged,
    Settled,
    Released,
    Aborted
}

/// @notice One side (subscribe or redeem) of one epoch — spec §6. There is no
/// per-request struct: a holder's position is their ERC-1155 balance (ADR-013).
struct EpochSide {
    uint256 totalIn; // escrowed into this id. THE DENOMINATOR — frozen once locked
    uint256 netAmount; // handed to the batch
    uint64 batchId; // 0 = not yet consumed (batch ids start at 1)
    bool locked;
    // SC6a Task 7 (Art 8.2): the live redemptionFeeBps, frozen onto a RED_EPOCH side by its first
    // requester (packs into this slot alongside batchId/locked — no extra storage slot). Unused on
    // the SUB_EPOCH/LAUNCHPAD sides of this same struct.
    uint16 redemptionFeeBps;
}

/// @notice One net batch — spec §6. The same shape serves both legs (ADR-015);
/// `grossAssets` is the single redeem-only field and stays 0 here.
struct Batch {
    BatchStatus status;
    uint256 netIn; // accrued amount AND the denominator splitting returnedAmount
    uint256 returnedAmount;
    // ADR-026: the home-side `navAtInitiate` is GONE -- it was write-only (stamped at bridge time,
    // read nowhere, exposed by no getter). The WIRE field `Instruction.navAtInitiate` stays in the
    // frozen `shared/src/Wire.sol` and is still sent (as a 0 sentinel); only this storage slot goes.
    uint64 accrualStart;
    uint64 bridgedAt;
    Leg leg;
    uint256 grossAssets; // REDEEM-ONLY — unused in SC1
}
