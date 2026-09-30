// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "@openzeppelin/contracts/utils/math/Math.sol";
import "../src/REXPrimary.sol";
import "../src/libraries/State.sol";
import "@rex-shared/Receipt.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/INavOracle.sol";
import "./mocks/MockERC20.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import "@rex-shared-mocks/MockNavOracle.sol";
import {perSecondSchedule} from "./helpers/TestSchedule.sol";

/// @notice Reusable NAV-parametrized harness (audit H-2, AT-192): the NAV is a constructor-time
/// knob so a test can drive settlement at any nav, not just 1e18. The whole redeem side is the
/// residual (ADR-024). After ADR-026 this harness has the OPPOSITE job to the one it was built for:
/// it no longer proves the redeem gate prices its accrual correctly, it proves the gate does not
/// price it at all -- every other suite in the repo fixes nav at 1e18, where a wRWA threshold and a
/// USDC-value threshold are numerically indistinguishable, so this is the only place that separates
/// them.
contract NavParamHarness is Test {
    MockMailbox mailbox;
    MockERC20 usdc;
    MockCollateralWarpRoute usdcRoute;
    MockSyntheticWarpRoute wrwaRoute;
    MockNavOracle navOracle;
    REXPrimary rex;
    address executor = makeAddr("executor");
    uint32 constant PRUV_DOMAIN = 7336;
    /// @dev Denominated in **wRWA** (ADR-026 D2), and the mock wRWA route below is 6-decimal --
    /// so 10,000 wRWA. The single source of truth for both the ctor argument and the thresholds
    /// the tests assert against.
    uint256 constant MIN_REDEEM = 10_000e6;

    receive() external payable {}

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function _deployRex(uint256 navE18) internal {
        mailbox = new MockMailbox(PRUV_DOMAIN);
        mailbox.setQuoteFee(0);
        usdc = new MockERC20("USDC", 6);
        usdcRoute = new MockCollateralWarpRoute(usdc);
        usdcRoute.setGasQuote(0);
        wrwaRoute = new MockSyntheticWarpRoute("wRWA", 6);
        wrwaRoute.setGasQuote(0);
        navOracle = new MockNavOracle(navE18);

        rex = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            0, // minSub_ 0 -> vacuous launchpad
            uint64(block.timestamp + 1),
            1 days,
            0, // launchpadMinimum_
            0,
            address(0xFEE),
            SC3Params({
                navOracle: INavOracle(address(navOracle)),
                minRedeem: MIN_REDEEM,
                redeemCancelFeeBps: 0,
                subFulfillTimeout: 10 days,
                redemptionFeeBps: 0,
                redeemFulfillTimeout: 10 days,
                windDownWindow: 9 days,
                schedule: perSecondSchedule()
            })
        );
        rex.enrollRemote(PRUV_DOMAIN, _b32(executor));

        vm.warp(rex.launchpadStart() + rex.launchpadPeriod());
        rex.closeLaunchpad(); // vacuous (nothing raised) -> straight to EpochBased
    }

    function _requestRedeem(address who, uint256 amt) internal {
        wrwaRoute.deliverTokens(_b32(who), amt);
        vm.startPrank(who);
        IERC20(address(wrwaRoute)).approve(address(rex), amt);
        rex.requestRedeem(amt);
        vm.stopPrank();
    }

    function _initiate() internal {
        rex.initiateSubEpoch(); // address(this) is keeper
    }
}

contract REXPrimaryNavParamTest is NavParamHarness {
    address bob = makeAddr("bob");

    /// @dev A LOW nav no longer holds a batch back. 12,000 wRWA clears the 10,000 wRWA minimum, and
    /// its USDC value at nav 0.5 (6,000) is irrelevant. This case is the direct inverse of the
    /// audit-H-2 regression it replaces -- under the old value gate the same batch stayed
    /// Accumulating, so a green result here is only reachable once the price leaves the gate.
    function test_gate_bridges_at_low_nav_ignoring_value() public {
        _deployRex(0.5e18);
        _requestRedeem(bob, 12_000e6); // >= MIN_REDEEM in wRWA; only 6,000 USDC of value
        _initiate();
        (uint8 st,,,) = rex.redeemBatch(1);
        assertEq(uint8(st), uint8(BatchStatus.Bridged), "the gate is unpriced: wRWA >= minRedeem bridges");
    }

    /// @dev And a HIGH nav no longer pushes a batch over. 5,000 wRWA is below the 10,000 wRWA
    /// minimum even though it is worth exactly 10,000 USDC at nav 2 -- which is precisely the value
    /// the old gate bridged on.
    function test_gate_accrues_at_high_nav_ignoring_value() public {
        _deployRex(2e18);
        _requestRedeem(bob, 5_000e6); // < MIN_REDEEM in wRWA; worth exactly 10,000 USDC
        _initiate();
        (uint8 st,,,) = rex.redeemBatch(1);
        assertEq(uint8(st), uint8(BatchStatus.Accumulating), "value at nav cannot clear a wRWA minimum");
    }

    // A sub-minimum redeem side accrues into its batch in full: after ADR-024 the whole side IS
    // the residual, and the frozen five-tuple's `matchedOut` reads a permanent 0.
    function test_subminimum_residual_accrues_in_full() public {
        _deployRex(0.5e18);
        _requestRedeem(bob, MIN_REDEEM - 1); // one wRWA unit under the minimum -> accrues
        _initiate();
        (uint8 st,,,) = rex.redeemBatch(1);
        assertEq(uint8(st), uint8(BatchStatus.Accumulating), "sub-minimum, so it stays open");
        (uint256 totalIn, uint256 matchedOut, uint256 netAmount,,) =
            rex.epochSide(rex.currentEpochId() - 1, CLASS_RED_EPOCH);
        assertEq(matchedOut, 0, "matchedOut is a permanent 0 (ADR-024)");
        assertEq(netAmount, totalIn, "the whole redeem side accrues as the residual");
    }
}

/// @notice AT-192 Task 10 -- broader NAV-parametrized coverage (spec §14) beyond the single-nav
/// per-finding regressions above: the four required navs {0.5, 1, 1.5, 3}e18, table-driven. Every
/// other suite in the repo fixes nav at 1e18; this is the audit-named gap. The zone/no-value-creation
/// cases that sat here retired with matching (ADR-024).
contract REXPrimaryNavParamTableTest is NavParamHarness {
    address bob = makeAddr("navBob");

    function _navs() internal pure returns (uint256[4] memory) {
        return [uint256(0.5e18), uint256(1e18), uint256(1.5e18), uint256(3e18)];
    }

    /// @dev The gate's branch point is FIXED in wRWA across every nav (ADR-026 D2). The same two
    /// amounts -- one wRWA unit under the minimum and exactly at it -- must land on the same side of
    /// the branch at 0.5, 1, 1.5 and 3. Under the old value gate three of these four navs would move
    /// the branch point, so this table is what pins the price out of the decision. Both sides are
    /// asserted at each nav, so the case can never collapse onto one branch and pass vacuously.
    function test_gate_branch_point_is_nav_independent() public {
        uint256[4] memory navs = _navs();
        for (uint256 i = 0; i < navs.length; i++) {
            uint256 navE18 = navs[i];

            _deployRex(navE18);
            _requestRedeem(bob, MIN_REDEEM - 1);
            _initiate();
            (uint8 stBelow,,,) = rex.redeemBatch(1);
            assertEq(uint8(stBelow), uint8(BatchStatus.Accumulating), "one wRWA unit under min must accrue");

            _deployRex(navE18);
            _requestRedeem(bob, MIN_REDEEM);
            _initiate();
            (uint8 stAt,,,) = rex.redeemBatch(1);
            assertEq(uint8(stAt), uint8(BatchStatus.Bridged), "exactly at min in wRWA must bridge");
        }
    }
}
