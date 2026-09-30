// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {Codec} from "@rex-shared/Codec.sol";
import {Instruction, RequestKind} from "@rex-shared/Wire.sol";

contract CodecTest is Test {
    /// @dev External boundary so vm.expectRevert catches the revert inside the
    /// inlined internal Codec.decode at a subcall depth.
    function decodeExternal(bytes memory body) external pure returns (Instruction memory) {
        return Codec.decode(body);
    }

    function test_round_trip_preserves_every_field() public pure {
        Instruction memory a = Instruction({legId: 7, kind: RequestKind.Redeem, amount: 123e6, navAtInitiate: 1.05e18});
        Instruction memory b = Codec.decode(Codec.encode(a));
        assertEq(b.legId, a.legId);
        assertEq(uint8(b.kind), uint8(a.kind));
        assertEq(b.amount, a.amount);
        assertEq(b.navAtInitiate, a.navAtInitiate);
    }

    function test_codec_roundtrips_subAborted() public pure {
        Instruction memory i = Instruction({legId: 7, kind: RequestKind.SubAborted, amount: 1e6, navAtInitiate: 1e18});
        Instruction memory o = Codec.decode(Codec.encode(i));
        assertEq(uint8(o.kind), uint8(RequestKind.SubAborted));
        assertEq(o.legId, 7);
    }

    function test_encode_leads_with_version_two() public pure {
        Instruction memory a = Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 1, navAtInitiate: 1e18});
        (uint8 version,) = abi.decode(Codec.encode(a), (uint8, Instruction));
        assertEq(version, Codec.WIRE_VERSION_V2);
    }

    function test_decode_rejects_an_unknown_version() public {
        Instruction memory a = Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 1, navAtInitiate: 1e18});
        bytes memory forged = abi.encode(uint8(3), a); // a future/unknown version
        vm.expectRevert(abi.encodeWithSelector(Codec.UnknownWireVersion.selector, uint8(3)));
        this.decodeExternal(forged);
    }

    function test_encode_writes_version_2() public pure {
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 1, navAtInitiate: 0}));
        (uint8 version,) = abi.decode(body, (uint8, Instruction));
        assertEq(version, 2);
    }

    function test_decode_rejects_version_1() public {
        bytes memory v1 =
            abi.encode(uint8(1), Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 1, navAtInitiate: 0}));
        vm.expectRevert(abi.encodeWithSelector(Codec.UnknownWireVersion.selector, uint8(1)));
        this.decodeExternal(v1);
    }
}
