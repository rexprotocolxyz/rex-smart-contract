// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "@rex-shared/Receipt.sol";
import "../src/libraries/State.sol";

contract TypesTest is Test {
    function test_encodeId_packs_class_in_the_top_byte() public pure {
        uint256 id = encodeId(CLASS_SUB_EPOCH, 42);
        assertEq(classOf(id), CLASS_SUB_EPOCH);
        assertEq(seqOf(id), uint64(42));
        assertEq(id, (uint256(1) << 248) | 42);
    }

    function test_encodeId_classes_never_collide() public pure {
        assertTrue(encodeId(CLASS_SUB_EPOCH, 7) != encodeId(CLASS_RED_EPOCH, 7));
        assertTrue(encodeId(CLASS_RED_EPOCH, 7) != encodeId(CLASS_LAUNCHPAD, 7));
    }

    function testFuzz_encodeId_roundtrips(uint8 class_, uint64 seq) public pure {
        uint256 id = encodeId(class_, seq);
        assertEq(classOf(id), class_);
        assertEq(seqOf(id), seq);
    }

    /// @dev None MUST be the zero value: an unwritten Batch would otherwise read
    /// as Accumulating, i.e. a batch that does not exist would look open (spec §6).
    function test_BatchStatus_none_is_the_zero_value() public pure {
        assertEq(uint8(BatchStatus.None), 0);
        assertEq(uint8(BatchStatus.Accumulating), 1);
    }

    /// @dev An unwritten Batch in storage must read as None, not as an open batch.
    function test_unwritten_batch_reads_as_none() public {
        Holder h = new Holder();
        assertEq(uint8(h.statusOf(999)), uint8(BatchStatus.None));
    }
}

contract Holder {
    mapping(uint64 => Batch) internal batches;

    function statusOf(uint64 id) external view returns (BatchStatus) {
        return batches[id].status;
    }
}
