// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

// Receipt-id layout (spec §6):  id = (uint256(class) << 248) | seq
// The top byte is the class so the id is readable in a block explorer; the low
// 248 bits are the sequence, which for the epoch classes is the epoch id.
uint8 constant CLASS_SUB_EPOCH = 1; // seq = epochId
uint8 constant CLASS_RED_EPOCH = 3; // seq = epochId — reserved, never minted in SC1
uint8 constant CLASS_LAUNCHPAD = 5; // seq = LAUNCHPAD_ID (the single launchpad; SC2)
uint64 constant LAUNCHPAD_ID = 0; // the single launchpad's seq within CLASS_LAUNCHPAD

function encodeId(uint8 class_, uint64 seq) pure returns (uint256) {
    return (uint256(class_) << 248) | uint256(seq);
}

function classOf(uint256 id) pure returns (uint8) {
    // casting to 'uint8' is safe because shifting right by 248 leaves only the
    // top byte, which always fits.
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint8(id >> 248);
}

/// @dev Safe to truncate: every id is built by `encodeId` from a uint64 seq, so
/// bits 64..247 are always zero.
function seqOf(uint256 id) pure returns (uint64) {
    // casting to 'uint64' is safe because bits 64..255 are always zero (see @dev above).
    // forge-lint: disable-next-line(unsafe-typecast)
    return uint64(id);
}
