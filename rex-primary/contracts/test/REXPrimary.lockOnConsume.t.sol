// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {REXPrimaryTestBase} from "./REXPrimary.redeem.t.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice ADR-024 Decision 7, as amended by ADR-027. The hazard this file guards has not moved;
/// the latch that holds it has.
///
/// The hazard: once an epoch's redeem side is folded into `_redeemBatch[id].netIn`, a LATER
/// epoch's escrow physically backs that accrued total. If a consumed side could be withdrawn
/// while the batch counter kept its old value, the batch would later bridge against escrow
/// belonging to somebody else, and the last holder out would find nothing there (spec §14).
///
/// ADR-015 held that by freezing the side: `if (Rwrwa > 0) red.locked = true;`, cancellation
/// gone. ADR-027 holds it by keeping the counter honest instead -- the cancel shrinks
/// `rb.netIn` and `s.netAmount` alongside `s.totalIn`, so the batch never claims escrow that has
/// left. Same invariant, and the holder keeps their exit.
///
/// MUTATION REQUIREMENT: deleting `cb.netIn -= amount` from `cancelRequest` MUST make
/// `test_cancelCannotReachALaterEpochsEscrow` fail. Verify that by hand -- a green suite is not
/// the deliverable, this test is.
contract REXPrimaryLockOnConsumeTest is REXPrimaryTestBase {
    function test_consumedRedeemSideCanStillCancelWhileItsBatchAccrues() public {
        // minRedeem is high enough that the side is consumed into a below-minimum batch rather
        // than bridging, so nothing has left the contract and Alice's exit is still open.
        uint256 id = _requestRedeem(alice, 100e6);
        _initiate();

        vm.prank(alice);
        rex.cancelRequest(id, 100e6);

        assertEq(IERC20(address(wrwaRoute)).balanceOf(alice), 100e6, "alice was not made whole");
        (, uint256 netIn,,) = rex.redeemBatch(1);
        assertEq(netIn, 0, "the batch still claims what alice took back");
    }

    /// @notice The hazard's real shape, with the fix in place. Alice's 100 is folded into the open
    /// batch in epoch 1; Bob then redeems into epoch 2, and HIS escrow is what physically backs
    /// the accrued total. Alice must leave with exactly her own 100 and none of his -- which is
    /// true only because her cancel shrinks the batch too.
    function test_cancelCannotReachALaterEpochsEscrow() public {
        uint256 aliceId = _requestRedeem(alice, 100e6);
        _initiate();
        uint256 bobId = _requestRedeem(bob, 100e6);
        assertEq(rex.liveRedeemEscrow(), 200e6, "fixture: both escrows held");

        vm.prank(alice);
        rex.cancelRequest(aliceId, 100e6);

        assertEq(IERC20(address(wrwaRoute)).balanceOf(alice), 100e6, "alice took the wrong amount");
        (, uint256 netIn,,) = rex.redeemBatch(1);
        assertEq(netIn, 0, "MUTATION LATCH: the batch would bridge against Bob's escrow");
        assertEq(rex.liveRedeemEscrow(), 100e6, "what remains must be exactly Bob's");

        // And Bob, whose own side was never consumed, is unaffected throughout.
        vm.prank(bob);
        rex.cancelRequest(bobId, 100e6);
        assertEq(IERC20(address(wrwaRoute)).balanceOf(bob), 100e6, "bob could not exit");
        assertEq(rex.liveRedeemEscrow(), 0, "escrow fully unwound");
    }
}
