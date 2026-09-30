// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Script} from "forge-std/Script.sol";
import {console} from "forge-std/console.sol";
import {Codec} from "@rex-shared/Codec.sol";
import {Instruction, RequestKind} from "@rex-shared/Wire.sol";

/// @notice Emits the canonical cross-chain wire test vectors from the REAL
/// `Codec.encode`/`Codec.decode` (shared/src/Codec.sol) so the TypeScript mirror
/// in `shared/ts` (the wire package, INIT-3) is asserted against Solidity output
/// rather than against a reading of it (CONTRIBUTING.md §G6).
///
/// @dev Emit-only: deploys a throwaway `CodecProbe` helper in-simulation (never broadcast), no
/// file writes (`fs_permissions` is read-only). Every line is pipe-delimited on stdout:
///   `VECTOR|name|legId|kind|amount|navAtInitiate|encodedHex`  — happy path
///   `PROBE|name|bodyHex|ok|kindOrdinal` / `PROBE|name|bodyHex|revert|errHex`
/// The generator `shared/ts/scripts/generate-vectors.mjs` parses them into
/// `shared/ts/test/fixtures/codec-vectors.json`.
///
/// Run: `forge script script/EmitCodecVectors.s.sol --target-contract EmitCodecVectors -vv`
/// (from `contracts/`; `--target-contract` disambiguates from the `CodecProbe` helper below) or
/// `yarn workspace <wire-pkg> gen:vectors` (regenerates the fixture).
contract EmitCodecVectors is Script {
    /// @dev Deployed once in `run()`. `_probe`'s external call targets this real address rather
    /// than `address(this)` — forge's script executor rejects a script calling itself ("Usage of
    /// `address(this)` detected in script contract"), even for a call that never broadcasts.
    CodecProbe private probe;

    function run() external {
        probe = new CodecProbe();
        _emitVectors();
        _probeRejections();
    }

    function _emitVectors() private pure {
        _emit("subscribe_min", Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 1, navAtInitiate: 1e18}));
        _emit(
            "subscribe_typical",
            Instruction({legId: 42, kind: RequestKind.Subscribe, amount: 1_000e6, navAtInitiate: 1.05e18})
        );
        _emit(
            "redeem_typical", Instruction({legId: 7, kind: RequestKind.Redeem, amount: 123e6, navAtInitiate: 1.05e18})
        );
        _emit(
            "redeem_max_fields",
            Instruction({
                legId: type(uint64).max,
                kind: RequestKind.Redeem,
                amount: type(uint256).max,
                navAtInitiate: type(uint256).max
            })
        );
        _emit("zero_amount", Instruction({legId: 0, kind: RequestKind.Subscribe, amount: 0, navAtInitiate: 0}));
    }

    /// @dev Ground truth for the failure path: which malformed bodies Solidity
    /// actually rejects. The TS mirror must reject exactly these and no fewer.
    function _probeRejections() private view {
        Instruction memory instr =
            Instruction({legId: 7, kind: RequestKind.Redeem, amount: 123e6, navAtInitiate: 1.05e18});
        bytes memory valid = Codec.encode(instr);

        _probe("unknown_version_1", abi.encode(uint8(1), instr));
        _probe("unknown_version_0", abi.encode(uint8(0), instr));
        _probe("kind_out_of_range", abi.encode(uint8(2), uint64(7), uint8(4), uint256(123e6), uint256(1.05e18)));
        _probe("empty_body", "");
        _probe("truncated_one_word_short", _head(valid, 128));
        _probe("truncated_odd_length", _head(valid, 159));
        _probe("trailing_extra_word", bytes.concat(valid, new bytes(32)));
        _probe("trailing_one_byte", bytes.concat(valid, hex"ff"));

        // Dirty high bits in a narrow field: does the strict decoder validate the padding, or
        // silently truncate? The TS mirror must fail closed wherever Solidity does.
        _probe("dirty_version_word", _words(0x102, 7, 1, 123e6, 1.05e18));
        _probe("dirty_legid_high_bits", _words(2, uint256(type(uint64).max) + 1, 1, 123e6, 1.05e18));
        _probe("dirty_kind_high_bits", _words(2, 7, 0x100, 123e6, 1.05e18));
    }

    function _probe(string memory name, bytes memory body) private view {
        try probe.decodeExternal(body) returns (Instruction memory got) {
            console.log(
                string.concat("PROBE|", name, "|", vm.toString(body), "|ok|", vm.toString(uint256(uint8(got.kind))))
            );
        } catch (bytes memory err) {
            console.log(string.concat("PROBE|", name, "|", vm.toString(body), "|revert|", vm.toString(err)));
        }
    }

    function _emit(string memory name, Instruction memory instr) private pure {
        console.log(
            string.concat(
                "VECTOR|",
                name,
                "|",
                vm.toString(uint256(instr.legId)),
                "|",
                vm.toString(uint256(uint8(instr.kind))),
                "|",
                vm.toString(instr.amount),
                "|",
                vm.toString(instr.navAtInitiate),
                "|",
                vm.toString(Codec.encode(instr))
            )
        );
    }

    /// @dev Raw 5-word body, bypassing the type system so a field can carry dirty padding.
    function _words(uint256 version, uint256 legId, uint256 kind, uint256 amount, uint256 nav)
        private
        pure
        returns (bytes memory)
    {
        return abi.encodePacked(version, legId, kind, amount, nav);
    }

    function _head(bytes memory src, uint256 len) private pure returns (bytes memory out) {
        out = new bytes(len);
        for (uint256 i = 0; i < len; i++) {
            out[i] = src[i];
        }
    }
}

/// @notice External boundary for `_probe`'s `try/catch` to observe the revert raised inside the
/// inlined internal `Codec.decode` (same idea as `contracts/test/Codec.t.sol:11`, which calls
/// `this.decodeExternal` from a Test contract — scripts need a genuinely separate address instead,
/// see `EmitCodecVectors.probe` above).
contract CodecProbe {
    function decodeExternal(bytes memory body) external pure returns (Instruction memory) {
        return Codec.decode(body);
    }
}
