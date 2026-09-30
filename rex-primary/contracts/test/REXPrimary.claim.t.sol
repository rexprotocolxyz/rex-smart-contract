// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {Codec} from "@rex-shared/Codec.sol";
import "../src/REXPrimary.sol";
import "@rex-shared/Receipt.sol";
import "@rex-shared/IHyperlane.sol";
import "./mocks/MockERC20.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import "@rex-shared-mocks/MockNavOracle.sol";
import "@rex-shared/INavOracle.sol";
import {perSecondSchedule} from "./helpers/TestSchedule.sol";

contract REXPrimaryClaimTest is Test {
    MockMailbox mailbox;
    MockERC20 usdc;
    MockCollateralWarpRoute usdcRoute;
    MockSyntheticWarpRoute wrwaRoute;
    MockNavOracle navOracle;
    REXPrimary rex;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address carol = makeAddr("carol");
    address executor = makeAddr("executor");
    uint32 constant PRUV_DOMAIN = 7336;
    uint256 constant ID1 = (uint256(1) << 248) | 1;

    receive() external payable {}

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function setUp() public {
        mailbox = new MockMailbox(PRUV_DOMAIN);
        mailbox.setQuoteFee(0);
        usdc = new MockERC20("USDC", 6);
        usdcRoute = new MockCollateralWarpRoute(usdc);
        usdcRoute.setGasQuote(0);
        wrwaRoute = new MockSyntheticWarpRoute("wRWA", 6);
        navOracle = new MockNavOracle(1e18);
        rex = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            0,
            uint64(block.timestamp + 1),
            1 days,
            0,
            0,
            address(0xFEE),
            SC3Params({
                navOracle: INavOracle(address(navOracle)),
                minRedeem: 0,
                redeemCancelFeeBps: 0,
                subFulfillTimeout: 10 days,
                redemptionFeeBps: 0,
                redeemFulfillTimeout: 10 days,
                windDownWindow: 9 days,
                schedule: perSecondSchedule()
            })
        );
        rex.enrollRemote(PRUV_DOMAIN, _b32(executor));
        _reachEpochBased(rex);
    }

    /// @dev Reach EpochBased via a zero-raise vacuous launchpad close (launchpadMinimum == 0),
    /// which creates NO batch, so subscribe batch ids still start at 1.
    function _reachEpochBased(REXPrimary r) internal {
        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad();
    }

    function _deposit(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(rex), amount);
        rex.requestDeposit(amount);
        vm.stopPrank();
    }

    /// @dev Drive the epoch to Settled with `shares` wRWA returned for the batch.
    function _settleWith(uint256 shares) internal {
        rex.initiateSubEpoch();
        wrwaRoute.deliverTokens(_b32(address(rex)), shares);
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Subscribe, amount: shares, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
        rex.settleSubBatch(1);
    }

    function test_claim_before_settle_reverts() public {
        _deposit(alice, 100e6);
        rex.initiateSubEpoch();
        vm.prank(alice);
        vm.expectRevert(NotSettled.selector);
        rex.claim(ID1, 100e6);
    }

    function test_claim_pays_pro_rata_and_burns() public {
        _deposit(alice, 100e6);
        _deposit(bob, 300e6);
        _settleWith(392e6); // the fund priced 400e6 USDC at 392e6 wRWA

        vm.prank(alice);
        rex.claim(ID1, 100e6);
        assertEq(wrwaRoute.balanceOf(alice), 98e6, "100/400 of 392e6");
        assertEq(rex.balanceOf(alice, ID1), 0, "receipt burned");

        vm.prank(bob);
        rex.claim(ID1, 300e6);
        assertEq(wrwaRoute.balanceOf(bob), 294e6, "300/400 of 392e6");
        assertEq(wrwaRoute.balanceOf(address(rex)), 0, "pot fully distributed");
    }

    /// @dev totalIn is the denominator and must NOT move when a claim burns.
    function test_claim_does_not_change_totalIn() public {
        _deposit(alice, 100e6);
        _deposit(bob, 300e6);
        _settleWith(392e6);

        vm.prank(alice);
        rex.claim(ID1, 100e6);

        (uint256 totalIn,,,,) = rex.epochSide(1, CLASS_SUB_EPOCH);
        assertEq(totalIn, 400e6, "denominator frozen - bob must still get 300/400");

        vm.prank(bob);
        rex.claim(ID1, 300e6);
        assertEq(wrwaRoute.balanceOf(bob), 294e6);
    }

    function test_claim_in_two_parts_equals_one_claim() public {
        _deposit(alice, 200e6);
        _deposit(bob, 200e6);
        _settleWith(400e6);

        vm.startPrank(alice);
        rex.claim(ID1, 50e6);
        rex.claim(ID1, 150e6);
        vm.stopPrank();

        vm.prank(bob);
        rex.claim(ID1, 200e6);

        assertEq(wrwaRoute.balanceOf(alice), wrwaRoute.balanceOf(bob), "splitting a claim changes nothing");
    }

    /// @dev A receipt bought on the open market pays the same (ADR-013).
    function test_buyer_of_a_locked_receipt_claims_it() public {
        _deposit(alice, 100e6);
        rex.initiateSubEpoch();

        vm.prank(alice);
        rex.safeTransferFrom(alice, carol, ID1, 100e6, "");

        wrwaRoute.deliverTokens(_b32(address(rex)), 98e6);
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 98e6, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
        rex.settleSubBatch(1);

        vm.prank(carol);
        rex.claim(ID1, 100e6);
        assertEq(wrwaRoute.balanceOf(carol), 98e6);

        vm.prank(alice);
        vm.expectRevert(); // ERC1155InsufficientBalance — alice sold the position
        rex.claim(ID1, 1);
    }

    /// @dev Pro-rata rate uniformity (ADR-013, spec section 14). Ported from the deleted
    /// `REXPrimary.matching.t.sol` when ADR-024 removed matching: the property it measures is NOT
    /// matching-derived -- it pins `_claim`'s surviving `mulDiv(amount, _returnSlice(s, b),
    /// s.totalIn)` expression, and the original's only matching content was one incidental redeem
    /// call, dropped here. Fuzzed rather than deterministic on purpose: random amounts against a
    /// return that does not divide the epoch evenly produce REAL per-holder floor dust, which the
    /// hand-picked pair in `test_claim_pays_pro_rata_and_burns` does not. Equality is therefore
    /// asserted as a RATE (cross-multiplied) within the floor bound, not as an exact split.
    function testFuzz_two_holders_same_rate(uint256 aAmt, uint256 bAmt) public {
        aAmt = bound(aAmt, 1e6, 1_000_000e6);
        bAmt = bound(bAmt, 1e6, 1_000_000e6);

        _deposit(alice, aAmt);
        _deposit(bob, bAmt);
        // A return that does NOT divide the epoch evenly (an uneven nav uplift), so both holders'
        // slices genuinely floor and the dust bound below is not vacuously satisfied.
        uint256 totalIn = aAmt + bAmt;
        _settleWith(totalIn + totalIn / 3 + 7);

        vm.prank(alice);
        rex.claim(ID1, aAmt);
        vm.prank(bob);
        rex.claim(ID1, bAmt);

        uint256 pa = wrwaRoute.balanceOf(alice);
        uint256 pb = wrwaRoute.balanceOf(bob);
        assertGt(pa, 0);
        assertGt(pb, 0);
        // pa/aAmt == pb/bAmt up to one floored base unit each: with pa = aAmt*R/totalIn - fa and
        // fa, fb in [0,1), pa*bAmt - pb*aAmt == fb*aAmt - fa*bAmt, so |diff| < max(aAmt, bAmt).
        assertApproxEqAbs(pa * bAmt, pb * aAmt, aAmt + bAmt, "two holders of one id settle at the same rate");
    }

    function test_claim_zero_reverts() public {
        _deposit(alice, 100e6);
        _settleWith(98e6);
        vm.prank(alice);
        vm.expectRevert(ZeroAmount.selector);
        rex.claim(ID1, 0);
    }
}
