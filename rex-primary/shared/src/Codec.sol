// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Instruction} from "./Wire.sol";

/// @notice Versioned codec for the cross-chain Instruction payload.
/// @dev ADR-011 makes PruvExecutor immutable and permanent, so it must decode
/// messages from any future REXPrimary version. Every payload leads with a
/// uint8 version discriminator: an immutable reader dispatches on it and rejects
/// an unknown version rather than misreading a re-laid-out struct (ADR-016).
library Codec {
    /// @dev ADR-028 D3/D4: v2 carries `amount` in micro-units of the asset (1e-6), so neither chain needs
    /// the other's decimals. The layout is unchanged; the version exists so a v1 reader can never
    /// misread a v2 amount. A redeployment is a new instance, so v2 contracts accept v2 only.
    uint8 internal constant WIRE_VERSION_V2 = 2;

    error UnknownWireVersion(uint8 version);

    /// @notice Encode as v2: a leading version discriminator, then the struct.
    function encode(Instruction memory instr) internal pure returns (bytes memory) {
        return abi.encode(WIRE_VERSION_V2, instr);
    }

    /// @notice Decode a v2 payload; revert UnknownWireVersion on anything else.
    function decode(bytes memory body) internal pure returns (Instruction memory instr) {
        uint8 version;
        (version, instr) = abi.decode(body, (uint8, Instruction));
        if (version != WIRE_VERSION_V2) revert UnknownWireVersion(version);
    }
}
