// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import "../../src/REXPrimary.sol";
import "../../src/PruvExecutor.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/Errors.sol";
import "@rex-shared/Receipt.sol";
import "../mocks/MockERC20.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockRWAToken.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import {MockRWAConversion} from "../mocks/MockRWAConversion.sol";
import "@rex-shared-mocks/MockNavOracle.sol";
import "@rex-shared/INavOracle.sol";
import {perSecondSchedule} from "../helpers/TestSchedule.sol";

/// @notice SC4b RS8' end-to-end: a subscribe leg that never executes (the KYC/canDeposit gate
/// stays shut) is recovered by abortDeposit -> the USDC comes home by UNLOCKING the original
/// Sepolia collateral (not minted) -> the batch settles Aborted, and subscribers claim their
/// own USDC back pro-rata. Proves conservation + no stranded funds.
contract SubscribeAbortRoundTripTest is Test {
    MockMailbox mailbox;
    MockERC20 usdc;
    MockCollateralWarpRoute usdcRoute; // home USDC collateral (Sepolia locks/unlocks)
    MockSyntheticWarpRoute pusdcRoute; // PRUV USDC synthetic (executor holds/burns)
    MockRWAToken vault;
    MockRWAConversion conversion;
    MockCollateralWarpRoute pruvWrwaRoute;
    MockSyntheticWarpRoute homeWrwaRoute;
    MockNavOracle navOracle;
    REXPrimary rex;
    PruvExecutor exec;

    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
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
        pusdcRoute = new MockSyntheticWarpRoute("pUSDC", 6);
        pusdcRoute.setGasQuote(0); // PRUV gas 0 — abortDeposit sends over this route

        vault = new MockRWAToken(address(pusdcRoute));
        conversion = new MockRWAConversion(1e18);
        pruvWrwaRoute = new MockCollateralWarpRoute(IERC20(address(vault)));
        pruvWrwaRoute.setGasQuote(0);
        homeWrwaRoute = new MockSyntheticWarpRoute("wRWA", 6);
        homeWrwaRoute.setGasQuote(0);

        navOracle = new MockNavOracle(1e18);
        rex = new REXPrimary(
            usdc,
            IMailbox(address(mailbox)),
            IWarpRoute(address(usdcRoute)),
            IWarpRoute(address(homeWrwaRoute)),
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
        exec = new PruvExecutor(
            IMailbox(address(mailbox)),
            IWarpRoute(address(pruvWrwaRoute)),
            PRUV_DOMAIN,
            address(vault),
            address(pusdcRoute),
            IWarpRoute(address(pusdcRoute)),
            1 hours,
            100,
            10 days,
            conversion,
            0,
            0
        );
        rex.enrollRemote(PRUV_DOMAIN, _b32(address(exec)));
        exec.enrollRemote(PRUV_DOMAIN, _b32(address(rex)));
        vm.warp(rex.launchpadStart() + rex.launchpadPeriod());
        rex.closeLaunchpad();
    }

    function _subscribe(address who, uint256 amount) internal {
        usdc.mint(who, amount);
        vm.startPrank(who);
        usdc.approve(address(rex), amount);
        rex.requestDeposit(amount);
        vm.stopPrank();
    }

    function test_abort_round_trip_refunds_pro_rata_and_reopens_cadence() public {
        _subscribe(alice, 100e6);
        _subscribe(bob, 300e6);

        rex.initiateSubEpoch(); // locks 400e6 into usdcRoute; batch 1 Bridged
        (, bytes32 outInstr,,) = rex.batchLeg(1, false);

        pusdcRoute.deliverTokens(_b32(address(exec)), 400e6);
        vault.setRejectDeposits(true); // the gate that never opens
        mailbox.process(outInstr); // handle(Subscribe): records + SubDepositDeferred (gate shut)

        vm.warp(block.timestamp + 1 hours + 1);
        exec.abortDeposit(1); // gate still shut → burns 400e6 pUSDC, sends Instruction{SubAborted}
        (, bytes32 abortInstr,,,) = exec.lastReturnLeg();

        usdcRoute.deliverTokens(_b32(address(rex)), 400e6); // UNLOCK the original Sepolia USDC home
        mailbox.process(abortInstr); // handle(SubAborted): batch Aborted, heldEscrowUSDC += 400e6

        (uint8 status,,) = rex.subBatch(1);
        assertEq(status, uint8(BatchStatus.Aborted), "batch 1 aborted");

        vm.prank(alice);
        rex.claim(ID1, 100e6);
        vm.prank(bob);
        rex.claim(ID1, 300e6);

        assertEq(usdc.balanceOf(alice), 100e6, "alice refunded her own escrow");
        assertEq(usdc.balanceOf(bob), 300e6, "bob refunded pro-rata");
        assertEq(usdc.balanceOf(address(rex)), 0, "no USDC stranded");
        assertEq(rex.heldEscrowUSDC(), 0, "reserve fully drained");

        // currentEpochId already advanced to 2 on the first initiateSubEpoch call (unconditional
        // in REXPrimary.sol), so epoch 2 needs its own subscriber or this call hits the unrelated
        // NothingToSettle gate instead of proving what this test is actually about: ADR-018 retired
        // single-in-flight, so a fresh epoch initiates freely regardless of batch 1's outcome.
        _subscribe(alice, 1e6);
        rex.initiateSubEpoch(); // proves the cadence is unblocked (no revert)
    }
}
