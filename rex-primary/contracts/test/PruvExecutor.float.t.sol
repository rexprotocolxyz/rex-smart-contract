// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {Codec} from "@rex-shared/Codec.sol";
import "../src/PruvExecutor.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/Wire.sol";
import "@rex-shared/Errors.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockRWAToken.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import {MockRWAConversion} from "./mocks/MockRWAConversion.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @notice AT-192 Task 3 (H-1/M-2/M-6): the executor's own USDC/wRWA balance can transiently hold
/// MORE than one batch's committed collateral at once (parallel recorded-not-resolved legs), so a
/// raw `balanceOf` rendezvous or fee-float check can false-positive against another batch's escrow
/// instead of the free float. `pendingDepositAssets` is the USDC twin of `pendingRedeemShares`
/// (mirrors `_recordRedeem`'s own committed-balance discipline) -- these tests reproduce the PoCs
/// from the audit (PoC C: fee drawn from a neighbouring batch's escrow: PoC D: false rendezvous)
/// and the M-6 sweep-recoverability fix, using the exact mock topology from `PruvExecutor.t.sol`.
contract PruvExecutorFloatTest is Test {
    event SubDepositDeferred(uint64 legId);

    MockMailbox mailbox;
    MockSyntheticWarpRoute pusdcRoute; // PRUV-side bridged USDC - the route IS the token
    MockRWAToken vault;
    MockRWAConversion conversion;
    MockCollateralWarpRoute wrwaRoute;
    PruvExecutor exec;

    address home = makeAddr("home");
    address feeCollector = makeAddr("feeCollector");
    address treasury = makeAddr("treasury");
    uint32 constant PRUV_DOMAIN = 7336;

    uint256 constant SUB_FULFILL_TIMEOUT = 1 hours;
    uint256 constant SLIPPAGE_BPS = 100;
    uint256 constant REDEEM_FULFILL_TIMEOUT = 10 days;

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function setUp() public {
        mailbox = new MockMailbox(PRUV_DOMAIN);
        mailbox.setQuoteFee(0);
        pusdcRoute = new MockSyntheticWarpRoute("pUSDC", 6);
        pusdcRoute.setGasQuote(0);
        vault = new MockRWAToken(address(pusdcRoute));
        conversion = new MockRWAConversion(1e18);
        wrwaRoute = new MockCollateralWarpRoute(IERC20(address(vault)));
        wrwaRoute.setGasQuote(0);
        exec = new PruvExecutor(
            IMailbox(address(mailbox)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            address(vault),
            address(pusdcRoute),
            IWarpRoute(address(pusdcRoute)),
            SUB_FULFILL_TIMEOUT,
            SLIPPAGE_BPS,
            REDEEM_FULFILL_TIMEOUT,
            conversion,
            0,
            0
        );
        exec.enrollRemote(PRUV_DOMAIN, _b32(home));
    }

    function _deliver(uint64 batchId, uint256 amount) internal {
        bytes memory body = Codec.encode(
            Instruction({legId: batchId, kind: RequestKind.Subscribe, amount: amount, navAtInitiate: 1e18})
        );
        vm.prank(address(mailbox));
        exec.handle(PRUV_DOMAIN, _b32(home), body);
    }

    /// @dev Records a deposit leg without executing it: tokens land, the vault gate is shut, so the
    /// leg is recorded + deferred and its USDC stays committed (mirrors `PruvExecutor.t.sol`'s
    /// `_recordStuck`).
    function _recordDeferred(uint64 batchId, uint256 amount) internal {
        pusdcRoute.deliverTokens(_b32(address(exec)), amount);
        vault.setRejectDeposits(true);
        _deliver(batchId, amount);
    }

    // ---------------------------------------------------------------------
    // M-2: false rendezvous on the subscribe path
    // ---------------------------------------------------------------------

    /// @dev PoC D. Batch A's USDC lands and records (gate shut -> deferred, still held). Batch B's
    /// instruction then arrives with NO B tokens delivered. A raw `balanceOf` rendezvous would let
    /// B record against A's still-held money (false rendezvous); the committed-balance check must
    /// instead revert `NotReadyToExecute`, exactly like `_recordRedeem`'s own guard.
    function test_M2_no_false_rendezvous_on_deposit_leg() public {
        _recordDeferred(1, 1_000e6); // A records, gate shut -> deferred, still holds 1,000e6
        assertEq(exec.pendingDepositAssets(), 1_000e6, "A's USDC committed");

        vm.expectRevert(NotReadyToExecute.selector);
        _deliver(2, 1_000e6); // no B tokens delivered: balanceOf(1000e6) < pendingDepositAssets(1000e6)+1000e6

        (,, bool bExists,,,) = exec.pending(2);
        assertFalse(bExists, "B did not false-rendezvous on A's committed money");
        assertEq(pusdcRoute.balanceOf(address(exec)), 1_000e6, "A's escrow untouched");
    }

    // ---------------------------------------------------------------------
    // H-1: bridge fee paid from the free float, never from a neighbouring batch's escrow
    // ---------------------------------------------------------------------

    /// @dev PoC C. Batch B records and defers (gate shut) -- its 50e6 stays committed. The gate
    /// then reopens and batch A's own 100e6 lands and deposits successfully, consuming A's own
    /// principal into the vault. The wRWA return route charges a WithFee fee IN USDC with no
    /// separate float funded: the only USDC left on the executor at that point is B's committed
    /// 50e6. A raw `balanceOf` fee check would silently approve+pull the 750000 fee out of B's
    /// escrow (PoC C); the committed-balance check must instead refuse with `have == 0`, rolling
    /// A's whole attempt back so it is not stranded half-executed and B's escrow is provably
    /// untouched. Since ADR-030 D11 the send home sits inside `_depositChecked`, so that refusal
    /// is caught by `_tryDeposit` and A simply DEFERS (spec §3.4) instead of reverting the
    /// delivery -- the money-safety conclusion is identical, and A stays pokeable.
    function test_H1_withfee_fee_not_drawn_from_neighbouring_batch_escrow() public {
        _recordDeferred(2, 50e6); // B records, gate shut -> deferred, committed
        assertEq(exec.pendingDepositAssets(), 50e6);

        vault.setRejectDeposits(false); // gate reopens for A
        wrwaRoute.setFee(IERC20(address(pusdcRoute)), 750_000, feeCollector); // cross-token fee, no float funded

        pusdcRoute.deliverTokens(_b32(address(exec)), 100e6); // A's own funds only
        vm.expectEmit(true, true, true, true);
        emit SubDepositDeferred(1);
        _deliver(1, 100e6);

        // Atomic rollback: A never latched, and B's committed escrow is untouched.
        (,,, bool aExecuted,,) = exec.pending(1);
        assertFalse(aExecuted, "A's deposit rolled back with the fee refusal");
        (uint256 bAmount,,, bool bExecuted,, bool bAborted) = exec.pending(2);
        assertEq(bAmount, 50e6, "B's escrow still its own");
        assertFalse(bExecuted || bAborted, "B untouched by A's attempt");
        // A now defers rather than reverting the delivery, so its own 100e6 joins B's 50e6 as
        // committed -- the point is that NONE of B's 50e6 went to the fee.
        assertEq(exec.pendingDepositAssets(), 150e6, "B's 50e6 intact, A's 100e6 committed alongside it");
        assertEq(pusdcRoute.balanceOf(address(exec)), 150e6, "no USDC left the executor");
        assertEq(pusdcRoute.balanceOf(feeCollector), 0, "fee collector got nothing -- no silent draw");
    }

    // ---------------------------------------------------------------------
    // M-6: sweep recovers the free float but never the committed escrow
    // ---------------------------------------------------------------------

    /// @dev Fund a true float on top of one recorded-deferred leg's committed escrow. `sweep`
    /// must be able to withdraw the float, but reverts `InvalidState` if asked for more than
    /// `balanceOf - pendingDepositAssets`.
    function test_M6_sweep_recovers_free_float_but_not_committed() public {
        _recordDeferred(1, 300e6); // committed
        pusdcRoute.deliverTokens(_b32(address(exec)), 500e6); // true float on top

        assertEq(pusdcRoute.balanceOf(address(exec)), 800e6);
        assertEq(exec.pendingDepositAssets(), 300e6);

        vm.expectRevert(InvalidState.selector);
        exec.sweep(address(pusdcRoute), treasury, 500e6 + 1); // over the free float -> reverts

        exec.sweep(address(pusdcRoute), treasury, 500e6); // exactly the free float -> succeeds
        assertEq(pusdcRoute.balanceOf(treasury), 500e6);
        assertEq(pusdcRoute.balanceOf(address(exec)), 300e6, "committed escrow left untouched");

        vm.expectRevert(InvalidState.selector);
        exec.sweep(address(pusdcRoute), treasury, 1); // float now fully drained -> any more reverts
    }

    function test_sweep_rwaToken_still_fully_excluded() public {
        deal(address(vault), address(exec), 5e6); // stray/free shares
        vm.expectRevert(InvalidState.selector);
        exec.sweep(address(vault), treasury, 5e6);
    }
}
