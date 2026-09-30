// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "../src/REXPrimary.sol";
import {REXLens} from "../src/REXLens.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/Errors.sol";
import "./mocks/MockERC20.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import "@rex-shared-mocks/MockNavOracle.sol";
import "@rex-shared/INavOracle.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {perSecondSchedule} from "./helpers/TestSchedule.sol";
import {IEpochSchedule} from "@rex-shared/IEpochSchedule.sol";

contract REXPrimaryAccessTest is Test {
    MockMailbox mailbox;
    MockERC20 usdc;
    MockCollateralWarpRoute usdcRoute;
    MockSyntheticWarpRoute wrwaRoute;
    MockNavOracle navOracle;
    REXPrimary rex;
    REXLens lens;
    address newOwner = makeAddr("newOwner");
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
            makeAddr("fee"),
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
        lens = new REXLens();
    }

    function test_renounceOwnership_reverts() public {
        vm.expectRevert(RenounceDisabled.selector);
        rex.renounceOwnership();
    }

    function test_ownership_is_two_step() public {
        rex.transferOwnership(newOwner);
        assertEq(rex.owner(), address(this)); // not yet transferred
        assertEq(rex.pendingOwner(), newOwner);
        vm.prank(newOwner);
        rex.acceptOwnership();
        assertEq(rex.owner(), newOwner);
    }

    /// @dev Reach EpochBased via a zero-raise vacuous launchpad close (launchpadMinimum == 0
    /// in setUp), so no bridge plumbing / msg.value is needed.
    function _toEpochBased() internal {
        vm.warp(rex.launchpadStart() + rex.launchpadPeriod());
        rex.closeLaunchpad();
    }

    function test_guardian_pauses_admin_unpauses() public {
        address guardian = makeAddr("guardian");
        rex.setGuardian(guardian);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(NotGuardian.selector);
        rex.pause();
        vm.prank(guardian);
        rex.pause();
        assertTrue(rex.paused());
        // guardian cannot unpause (owner-only)
        vm.prank(guardian);
        vm.expectRevert(); // OwnableUnauthorizedAccount
        rex.unpause();
        rex.unpause(); // owner (this)
        assertFalse(rex.paused());
    }

    function test_pause_gates_inflow_not_exits() public {
        _toEpochBased(); // helper: warp past launchpad + closeLaunchpad

        // open a real SUB position while unpaused, so there is something to exit later.
        // Acts through an EOA (not address(this)): REXPrimaryAccessTest is a contract and
        // does not implement onERC1155Received, and the receipt mint would revert on it.
        address depositor = makeAddr("depositor");
        usdc.mint(depositor, 2e6);
        vm.startPrank(depositor);
        usdc.approve(address(rex), 2e6);
        uint256 id = rex.requestDeposit(1e6);
        vm.stopPrank();

        address g = makeAddr("g");
        rex.setGuardian(g);
        vm.prank(g);
        rex.pause();
        assertTrue(rex.paused());

        // inflow reverts while paused
        vm.prank(depositor);
        vm.expectRevert(); // EnforcedPause
        rex.requestDeposit(1e6);

        // exit is reachable while paused: cancelRequest succeeds and refunds USDC (net of
        // the cancel fee, which is 0 in this setUp) -- positively proving the exit path is
        // NOT gated by whenNotPaused, rather than merely asserting an unrelated revert.
        uint256 balBefore = usdc.balanceOf(depositor);
        vm.prank(depositor);
        rex.cancelRequest(id, 1e6);
        assertEq(usdc.balanceOf(depositor), balBefore + 1e6, "cancel refunds while paused");
        assertTrue(rex.paused(), "still paused across the exit call");
    }

    /// @dev ADR-025 deleted the keeper role: what was an address check on `initiateSubEpoch` is
    /// now a schedule check, so the trigger sits in this matrix's PERMISSIONLESS row alongside
    /// `closeLaunchpad` and `settleSubBatch`. A stranger fires a real epoch here -- the assertion
    /// is that it SUCCEEDS, not that some unrelated revert changed. (The gate's own behaviour --
    /// floor, one close per period, wind-down carve-out -- is `REXPrimary.schedule.t.sol`.)
    function test_initiateSubEpoch_is_permissionless() public {
        _toEpochBased();
        rex.enrollRemote(PRUV_DOMAIN, _b32(makeAddr("executor")));

        address depositor = makeAddr("depositor");
        usdc.mint(depositor, 1e6);
        vm.startPrank(depositor);
        usdc.approve(address(rex), 1e6);
        rex.requestDeposit(1e6);
        vm.stopPrank();

        vm.prank(makeAddr("stranger"));
        rex.initiateSubEpoch();
        assertEq(rex.currentEpochId(), 2, "a stranger closed the epoch");
    }

    /// @dev Pinned, not read from a constant: SC11 shipped without bumping `VERSION`, and
    /// `activeDeployment()` pins with `.find()` -- which returns the FIRST match, so two entries
    /// claiming one version silently point the backend at the wrong contract. ADR-027 is a new
    /// deployment (ADR-011, no proxy), so the string moves with it.
    function test_version() public view {
        assertEq(rex.VERSION(), "1.4.0");
    }

    /// @dev T2: full access matrix -- every owner-only mutator reverts with the SPECIFIC
    /// OwnableUnauthorizedAccount(stranger) selector for a non-owner caller. Ownable2Step's
    /// modifier runs before any lifecycle-state check in every one of these, so setUp's
    /// Initialized state does not need to change first.
    function test_access_matrix_owner_only_mutators_revert_for_stranger() public {
        address stranger = makeAddr("stranger");
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger);
        vm.startPrank(stranger);

        vm.expectRevert(unauthorized);
        rex.setFees(0, 0, 0);

        vm.expectRevert(unauthorized);
        rex.applyFees();

        vm.expectRevert(unauthorized);
        rex.setFeeCap(100);

        vm.expectRevert(unauthorized);
        rex.applyFeeCap();

        vm.expectRevert(unauthorized);
        rex.setGuardian(makeAddr("g"));

        vm.expectRevert(unauthorized);
        rex.setSchedule(IEpochSchedule(makeAddr("s")));

        vm.expectRevert(unauthorized);
        rex.applySchedule();

        vm.expectRevert(unauthorized);
        rex.unpause();

        vm.expectRevert(unauthorized);
        rex.sweep(address(usdc), stranger, 1);

        vm.expectRevert(unauthorized);
        rex.triggerWindDown();

        vm.expectRevert(unauthorized);
        rex.triggerShutDown();

        vm.expectRevert(unauthorized);
        rex.enrollRemote(PRUV_DOMAIN, _b32(stranger));

        vm.stopPrank();
    }

    /// @dev T2: zero-addr guards on the guardian rotation and the schedule proposal (owner-only,
    /// so called as `this`).
    function test_setGuardian_zero_address_reverts() public {
        vm.expectRevert(InvalidState.selector);
        rex.setGuardian(address(0));
    }

    function test_setSchedule_zero_address_reverts() public {
        vm.expectRevert(InvalidState.selector);
        rex.setSchedule(IEpochSchedule(address(0)));
    }

    /// @dev T2: shutDownBlockers() diagnostic -- windowElapsed is false before wind-down
    /// (windDownStart == 0), false immediately after triggering (window not yet elapsed), and
    /// true once the window has passed.
    function test_shutDownBlockers_reflects_windDown_progress() public {
        _toEpochBased();

        (bool windowElapsed, uint64 outSub, uint64 outRedeem) = lens.shutDownBlockers(address(rex));
        assertFalse(windowElapsed, "windDownStart is 0 pre-windDown");
        assertEq(outSub, 0);
        assertEq(outRedeem, 0);

        rex.triggerWindDown();
        (windowElapsed,,) = lens.shutDownBlockers(address(rex));
        assertFalse(windowElapsed, "window not yet elapsed");

        vm.warp(block.timestamp + rex.windDownWindow());
        (windowElapsed,,) = lens.shutDownBlockers(address(rex));
        assertTrue(windowElapsed, "window elapsed");
    }
}
