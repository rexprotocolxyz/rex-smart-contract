// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "../src/REXPrimary.sol";
import "@rex-shared/Receipt.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/INavOracle.sol";
import "./mocks/MockERC20.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import "@rex-shared-mocks/MockNavOracle.sol";
import {perSecondSchedule} from "./helpers/TestSchedule.sol";

contract REXPrimaryRequestTest is Test {
    MockMailbox mailbox;
    MockERC20 usdc;
    MockCollateralWarpRoute usdcRoute;
    MockSyntheticWarpRoute wrwaRoute;
    MockNavOracle navOracle;
    REXPrimary rex;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    uint32 constant PRUV_DOMAIN = 7336;

    function setUp() public {
        mailbox = new MockMailbox(PRUV_DOMAIN);
        usdc = new MockERC20("USDC", 6);
        usdcRoute = new MockCollateralWarpRoute(usdc);
        wrwaRoute = new MockSyntheticWarpRoute("wRWA", 6);
        navOracle = new MockNavOracle(1e18);
        rex = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            0, // minSub = 0 for the skeleton
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
        _reachEpochBased(rex);
    }

    function test_config_is_stored() public view {
        assertEq(address(rex.navOracle()), address(navOracle), "navOracle wired");
        assertEq(rex.minRedeem(), 0);
        assertEq(rex.redeemCancelFeeBps(), 0);
    }

    /// @dev Reach EpochBased via a zero-raise vacuous launchpad close (launchpadMinimum == 0),
    /// which creates NO batch, so subscribe batch ids still start at 1.
    function _reachEpochBased(REXPrimary r) internal {
        vm.warp(r.launchpadStart() + r.launchpadPeriod());
        r.closeLaunchpad();
    }

    function _deposit(address who, uint256 amount) internal returns (uint256 id) {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(rex), amount);
        id = rex.requestDeposit(amount);
        vm.stopPrank();
    }

    function test_requestDeposit_mints_receipts_one_for_one() public {
        uint256 id = _deposit(alice, 100e6);
        assertEq(id, encodeId(CLASS_SUB_EPOCH, 1), "first epoch id is 1");
        assertEq(rex.balanceOf(alice, id), 100e6, "receipt balance == USDC deposited");
        assertEq(usdc.balanceOf(address(rex)), 100e6, "USDC escrowed");
        (uint256 totalIn,,,, bool locked) = rex.epochSide(1, CLASS_SUB_EPOCH);
        assertEq(totalIn, 100e6);
        assertFalse(locked);
    }

    function test_requestDeposit_two_holders_share_one_id() public {
        uint256 id = _deposit(alice, 100e6);
        uint256 id2 = _deposit(bob, 400e6);
        assertEq(id, id2, "same epoch, same id");
        (uint256 totalIn,,,,) = rex.epochSide(1, CLASS_SUB_EPOCH);
        assertEq(totalIn, 500e6, "aggregate, not per-request");
    }

    function test_requestDeposit_zero_reverts() public {
        vm.expectRevert(ZeroAmount.selector);
        rex.requestDeposit(0);
    }

    function test_cancelRequest_burns_and_refunds() public {
        uint256 id = _deposit(alice, 100e6);
        vm.prank(alice);
        rex.cancelRequest(id, 40e6);
        assertEq(rex.balanceOf(alice, id), 60e6);
        assertEq(usdc.balanceOf(alice), 40e6);
        (uint256 totalIn,,,,) = rex.epochSide(1, CLASS_SUB_EPOCH);
        assertEq(totalIn, 60e6, "totalIn tracks the burn while unlocked");
    }

    /// @dev §7.2/§10: cancelling a subscribe request withholds the same cancel fee as
    /// cancelLaunchpad. setUp's `rex` uses fee 0, so this uses a fresh pool with 1%.
    function test_cancelRequest_charges_the_cancel_fee() public {
        address fee = makeAddr("feeRecipient");
        REXPrimary r = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            0,
            uint64(block.timestamp + 1),
            1 days,
            0,
            100, // cancelFeeBps = 1%
            fee,
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
        _reachEpochBased(r);

        usdc.mint(alice, 100e6);
        vm.startPrank(alice);
        usdc.approve(address(r), 100e6);
        uint256 id = r.requestDeposit(100e6);
        r.cancelRequest(id, 40e6); // 1% of 40e6 = 0.4e6 fee
        vm.stopPrank();

        assertEq(r.balanceOf(alice, id), 60e6, "unburned receipts remain");
        assertEq(usdc.balanceOf(fee), 400_000, "1% cancel fee to recipient");
        assertEq(usdc.balanceOf(alice), 39_600_000, "net refund = gross - fee");
        (uint256 totalIn,,,,) = r.epochSide(1, CLASS_SUB_EPOCH);
        assertEq(totalIn, 60e6, "totalIn tracks the gross burn");
    }

    /// @dev NotRequestOwner is retired (ADR-013): the ERC-1155 balance is the authority,
    /// so burning a balance you do not hold reverts inside the token layer.
    function test_cancelRequest_without_balance_reverts_in_the_token_layer() public {
        uint256 id = _deposit(alice, 100e6);
        vm.prank(bob);
        vm.expectRevert(); // ERC1155InsufficientBalance
        rex.cancelRequest(id, 1e6);
    }

    function test_receipts_are_transferable() public {
        uint256 id = _deposit(alice, 100e6);
        vm.prank(alice);
        rex.safeTransferFrom(alice, bob, id, 30e6, "");
        assertEq(rex.balanceOf(alice, id), 70e6);
        assertEq(rex.balanceOf(bob, id), 30e6);
    }
}
