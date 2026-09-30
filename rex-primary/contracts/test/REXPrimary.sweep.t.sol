// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {Codec} from "@rex-shared/Codec.sol";
import "../src/REXPrimary.sol";
import "@rex-shared/Receipt.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/INavOracle.sol";
import "@rex-shared/Errors.sol";
import "./mocks/MockERC20.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import "@rex-shared-mocks/MockNavOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {perSecondSchedule} from "./helpers/TestSchedule.sol";

/// @dev SC6b Task 6: the admin `sweep` backstop on REXPrimary -- recovers stray/mis-sent tokens
/// while never being able to touch a reserved USDC/wRWA balance (spec design section 7).
contract REXPrimarySweepTest is Test {
    event Swept(address indexed token, address indexed to, uint256 amount);

    MockMailbox mailbox;
    MockERC20 usdc;
    MockCollateralWarpRoute usdcRoute;
    MockSyntheticWarpRoute wrwaRoute;
    MockNavOracle navOracle;
    REXPrimary rex;

    address alice = makeAddr("alice");
    address executor = makeAddr("executor");
    address treasury = makeAddr("treasury");
    /// @dev The fixture's immutable `feeRecipient` -- the ONLY legal destination for a
    /// protocol token's free balance (2026-09-18: `recoverStuckBatch`'s hardwired payout moved
    /// here, so `sweep` must not widen where that money can go).
    address feeRecipient = address(0xFEE);
    uint32 constant PRUV_DOMAIN = 7336;

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
        wrwaRoute.setGasQuote(0);
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
        _toEpochBased();
    }

    /// @dev Reach EpochBased via a zero-raise vacuous launchpad close (launchpadMinimum == 0
    /// in setUp), so no bridge plumbing / msg.value is needed.
    function _toEpochBased() internal {
        vm.warp(rex.launchpadStart() + rex.launchpadPeriod());
        rex.closeLaunchpad();
    }

    function _requestDeposit(address who, uint256 amount) internal returns (uint256 id) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(rex), amount);
        id = rex.requestDeposit(amount);
        vm.stopPrank();
    }

    function _requestRedeem(address who, uint256 amount) internal returns (uint256 id) {
        wrwaRoute.deliverTokens(_b32(who), amount);
        vm.startPrank(who);
        IERC20(address(wrwaRoute)).approve(address(rex), amount);
        id = rex.requestRedeem(amount);
        vm.stopPrank();
    }

    /// @dev Drives a subscribe leg all the way to a recorded (unclaimed) return, the recipe
    /// REXPrimary.settle.t.sol uses to put wRWA into `settledUnclaimed` (E6/ADR-018: reserved
    /// at record, before settleSubBatch).
    function _recordSettledUnclaimed(uint256 usdcIn, uint256 wrwaOut) internal {
        _requestDeposit(alice, usdcIn);
        rex.initiateSubEpoch();
        wrwaRoute.deliverTokens(_b32(address(rex)), wrwaOut);
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Subscribe, amount: wrwaOut, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
    }

    function test_sweep_stray_token_full_balance() public {
        MockERC20 stray = new MockERC20("STRAY", 18);
        stray.mint(address(rex), 5e18);

        vm.expectEmit(true, true, false, true, address(rex));
        emit Swept(address(stray), treasury, 5e18);
        rex.sweep(address(stray), treasury, 5e18);

        assertEq(stray.balanceOf(treasury), 5e18);
        assertEq(stray.balanceOf(address(rex)), 0);
    }

    /// @dev 2026-09-18: `recoverStuckBatch` stopped paying its residual out, so `sweep` became the
    /// only path for a dead batch's money -- and `sweep` takes a caller-chosen `to`. Without this
    /// bound the fix would have WIDENED owner discretion over that money, from the hardwired
    /// immutable `feeRecipient` to any address. A protocol token may go only to `feeRecipient`; a
    /// stray third-party token may still be returned to whoever mis-sent it.
    function test_sweep_protocol_token_goes_only_to_feeRecipient() public {
        usdc.mint(address(rex), 7e6);
        wrwaRoute.deliverTokens(_b32(address(rex)), 3e6);

        vm.expectRevert(InvalidState.selector);
        rex.sweep(address(usdc), treasury, 7e6);
        vm.expectRevert(InvalidState.selector);
        rex.sweep(address(wrwaRoute), treasury, 3e6);
        vm.expectRevert(InvalidState.selector);
        rex.sweep(address(usdc), address(this), 7e6); // not even the owner itself

        rex.sweep(address(usdc), feeRecipient, 7e6);
        rex.sweep(address(wrwaRoute), feeRecipient, 3e6);
        assertEq(usdc.balanceOf(feeRecipient), 7e6);
        assertEq(IERC20(address(wrwaRoute)).balanceOf(feeRecipient), 3e6);

        // A stray token is unaffected: `to` stays free, so a mis-send can be made whole.
        MockERC20 stray = new MockERC20("STRAY", 18);
        stray.mint(address(rex), 5e18);
        rex.sweep(address(stray), treasury, 5e18);
        assertEq(stray.balanceOf(treasury), 5e18);
    }

    function test_sweep_usdc_respects_heldEscrowUSDC() public {
        _requestDeposit(alice, 100e6); // heldEscrowUSDC = 100e6
        usdc.mint(address(rex), 7e6); // truly free (mis-sent)

        vm.expectRevert(InvalidState.selector);
        rex.sweep(address(usdc), feeRecipient, 8e6);

        uint256 before = usdc.balanceOf(feeRecipient);
        rex.sweep(address(usdc), feeRecipient, 7e6); // exactly the free balance ok
        assertEq(usdc.balanceOf(feeRecipient), before + 7e6);
        assertEq(usdc.balanceOf(address(rex)), 100e6, "escrow untouched");
    }

    function test_sweep_wrwa_respects_liveRedeemEscrow() public {
        _requestRedeem(alice, 50e6); // liveRedeemEscrow = 50e6
        wrwaRoute.deliverTokens(_b32(address(rex)), 3e6); // truly free (mis-sent)

        vm.expectRevert(InvalidState.selector);
        rex.sweep(address(wrwaRoute), feeRecipient, 4e6);

        uint256 before = IERC20(address(wrwaRoute)).balanceOf(feeRecipient);
        rex.sweep(address(wrwaRoute), feeRecipient, 3e6);
        assertEq(IERC20(address(wrwaRoute)).balanceOf(feeRecipient), before + 3e6);
        assertEq(rex.liveRedeemEscrow(), 50e6, "redeemers' escrow untouched");
    }

    function test_sweep_wrwa_respects_settledUnclaimed() public {
        _recordSettledUnclaimed(100e6, 98e6); // settledUnclaimed = 98e6
        rex.settleSubBatch(1); // terminal -> back to quiescent (outstandingSubBatches == 0)
        assertEq(rex.settledUnclaimed(), 98e6);
        wrwaRoute.deliverTokens(_b32(address(rex)), 2e6); // truly free (mis-sent)

        vm.expectRevert(InvalidState.selector);
        rex.sweep(address(wrwaRoute), feeRecipient, 3e6);

        rex.sweep(address(wrwaRoute), feeRecipient, 2e6);
        assertEq(IERC20(address(wrwaRoute)).balanceOf(feeRecipient), 2e6);
        assertEq(rex.settledUnclaimed(), 98e6, "unclaimed pot untouched");
    }

    /// @dev The rendezvous gate (spec §3.4): a Bridged-not-yet-terminal batch keeps
    /// outstandingSubBatches/outstandingRedeemBatches != 0 for its whole in-flight window, during
    /// which its return could land (unordered) before the instruction that reserves it -- sweeping
    /// the "free" balance in that window could steal a physically-arrived-but-unrecorded return.
    function test_sweep_usdc_reverts_while_sub_batch_outstanding() public {
        _requestDeposit(alice, 100e6);
        rex.initiateSubEpoch(); // minSub == 0 -> bridges in-tx, batch 1 now Bridged
        assertEq(rex.outstandingSubBatches(), 1);
        usdc.mint(address(rex), 7e6); // truly free (mis-sent), would pass the old bound check

        vm.expectRevert(InvalidState.selector);
        rex.sweep(address(usdc), feeRecipient, 7e6);

        // settle the batch's return -> quiescent again -> sweep now succeeds
        wrwaRoute.deliverTokens(_b32(address(rex)), 98e6);
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 98e6, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
        rex.settleSubBatch(1);
        assertEq(rex.outstandingSubBatches(), 0);

        rex.sweep(address(usdc), feeRecipient, 7e6);
        assertEq(usdc.balanceOf(feeRecipient), 7e6);
    }

    function test_sweep_wrwa_reverts_while_redeem_batch_outstanding() public {
        _requestRedeem(alice, 50e6);
        rex.initiateSubEpoch(); // minRedeem == 0 -> redeem batch 1 bridges in-tx, now Bridged
        assertEq(rex.outstandingRedeemBatches(), 1);
        wrwaRoute.deliverTokens(_b32(address(rex)), 3e6); // truly free (mis-sent)

        vm.expectRevert(InvalidState.selector);
        rex.sweep(address(wrwaRoute), feeRecipient, 3e6);

        // fund + execute + settle the redeem batch's return -> quiescent again
        usdc.mint(address(usdcRoute), 50e6); // seed the collateral pool for the return leg
        usdcRoute.deliverTokens(_b32(address(rex)), 50e6);
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Redeem, amount: 50e6, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        rex.handle(PRUV_DOMAIN, _b32(executor), body);
        rex.settleRedeemBatch(1);
        assertEq(rex.outstandingRedeemBatches(), 0);

        rex.sweep(address(wrwaRoute), feeRecipient, 3e6);
        assertEq(IERC20(address(wrwaRoute)).balanceOf(feeRecipient), 3e6);
    }

    function test_sweep_stray_token_succeeds_while_batch_outstanding() public {
        _requestDeposit(alice, 100e6);
        rex.initiateSubEpoch(); // batch 1 Bridged, outstandingSubBatches() == 1
        assertEq(rex.outstandingSubBatches(), 1);

        MockERC20 stray = new MockERC20("STRAY", 18);
        stray.mint(address(rex), 5e18);

        // foreign/stray tokens carry no reservation and are not gated on quiescence
        rex.sweep(address(stray), treasury, 5e18);
        assertEq(stray.balanceOf(treasury), 5e18);
    }

    function test_sweep_non_owner_reverts() public {
        MockERC20 stray = new MockERC20("STRAY", 18);
        stray.mint(address(rex), 1e18);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(); // OwnableUnauthorizedAccount
        rex.sweep(address(stray), treasury, 1e18);
    }
}
