// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {Codec} from "@rex-shared/Codec.sol";
import "../src/PruvExecutor.sol";
import {IRWAConversion} from "../src/NavReporter.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/Wire.sol";
import "@rex-shared/Errors.sol";
import "./mocks/MockERC20.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockRWAToken.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";
import {MockRWAConversion} from "./mocks/MockRWAConversion.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

/// @dev 6-dec asset, 18-dec shares (assets * 1e12 at nav=1). Models a fund whose share token is
/// NOT 6-dec — the case the fixed-1e18 convention does not handle. Standalone (MockRWAToken's
/// methods are non-virtual); implements only what the executor calls (deposit) + decimals.
contract MockRWAToken18 is ERC20 {
    using SafeERC20 for IERC20;

    address public immutable assetToken;
    bool public immutable halve;

    constructor(address a, bool halve_) ERC20("wRWA18", "wRWA18") {
        assetToken = a;
        halve = halve_;
    }

    function decimals() public pure override returns (uint8) {
        return 18;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        shares = halve ? assets * 1e12 / 2 : assets * 1e12;
        IERC20(assetToken).safeTransferFrom(msg.sender, address(this), assets);
        _mint(receiver, shares);
    }
}

contract PruvExecutorTest is Test {
    event SubDepositDeferred(uint64 legId);
    event SubDepositAborted(uint64 legId);

    MockMailbox mailbox;
    MockSyntheticWarpRoute pusdcRoute; // PRUV-side bridged USDC - the route IS the token
    MockRWAToken vault;
    MockRWAConversion conversion;
    MockCollateralWarpRoute wrwaRoute;
    PruvExecutor exec;

    address home = makeAddr("home");
    uint32 constant PRUV_DOMAIN = 7336;

    uint256 constant SUB_FULFILL_TIMEOUT = 1 hours;
    uint256 constant SLIPPAGE_BPS = 100; // 1% — config-values.md:69 testnet placeholder
    uint256 constant REDEEM_FULFILL_TIMEOUT = 10 days;

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function setUp() public {
        mailbox = new MockMailbox(PRUV_DOMAIN);
        mailbox.setQuoteFee(0);
        pusdcRoute = new MockSyntheticWarpRoute("pUSDC", 6);
        pusdcRoute.setGasQuote(0); // PRUV gas 0; abortDeposit sends over this route
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
            IWarpRoute(address(pusdcRoute)), // usdcRoute: PRUV-side synthetic USDC route (burns)
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

    function _deliverNav(uint64 batchId, uint256 amount, uint256 nav) internal {
        bytes memory body = Codec.encode(
            Instruction({legId: batchId, kind: RequestKind.Subscribe, amount: amount, navAtInitiate: nav})
        );
        vm.prank(address(mailbox));
        exec.handle(PRUV_DOMAIN, _b32(home), body);
    }

    event RedeemRecorded(uint64 legId, uint256 shares, uint256 grossAssets);

    function _deliverRedeemShares(address to, uint256 shares) internal {
        deal(address(vault), address(wrwaRoute), shares); // seed the collateral pool
        wrwaRoute.deliverTokens(_b32(to), shares); // unlock the shares to the recipient
    }

    function _deliverRedeem(uint64 batchId, uint256 shares, uint256 nav) internal {
        bytes memory body =
            Codec.encode(Instruction({legId: batchId, kind: RequestKind.Redeem, amount: shares, navAtInitiate: nav}));
        vm.prank(address(mailbox));
        exec.handle(PRUV_DOMAIN, _b32(home), body);
    }

    /// @dev The common ordering: tokens land first, so the deposit completes inside
    /// the relayer's delivery tx - no keeper poke (ADR-009, preserved by D9).
    function _recordStuck(uint64 batchId, uint256 amount) internal {
        pusdcRoute.deliverTokens(_b32(address(exec)), amount);
        vault.setRejectDeposits(true);
        _deliver(batchId, amount); // records + SubDepositDeferred (gate closed)
    }

    function test_tokens_first_deposits_in_the_same_tx() public {
        pusdcRoute.deliverTokens(_b32(address(exec)), 100e6);
        _deliver(1, 100e6);

        (,,, bool executed,,) = exec.pending(1);
        assertTrue(executed, "deposited on delivery");
        assertEq(vault.balanceOf(address(exec)), 0, "shares were bridged home, not held");
        (, bytes32 instrId,,,) = exec.lastReturnLeg();
        assertTrue(instrId != bytes32(0), "return leg dispatched");
    }

    /// @dev The ordering Hyperlane explicitly does not rule out (spec 3.4). handle MUST revert
    /// and record NOTHING: the revert rolls back Hyperlane's delivery mark, so anyone can simply
    /// re-process the message later, for free (`Mailbox.sol:202/225/241/361`).
    function test_instruction_first_reverts_and_records_nothing() public {
        vm.expectRevert(NotReadyToExecute.selector);
        _deliver(1, 100e6);

        (,, bool exists,,,) = exec.pending(1);
        assertFalse(exists, "nothing recorded - the message stays re-processable instead");
    }

    /// @dev The companion: once the tokens land, the very same delivery succeeds.
    /// This is what "anyone re-processes it" looks like at the handler.
    function test_redelivery_after_the_tokens_land_succeeds() public {
        vm.expectRevert(NotReadyToExecute.selector);
        _deliver(1, 100e6);

        pusdcRoute.deliverTokens(_b32(address(exec)), 100e6);
        _deliver(1, 100e6);

        (,,, bool executed,,) = exec.pending(1);
        assertTrue(executed, "the re-processed delivery completed it");
        assertEq(pusdcRoute.balanceOf(address(vault)), 100e6);
    }

    /// @dev Tokens present but the vault rejects: the leg IS recorded, so it stays pokeable.
    /// This is the only case that needs contract-side state at all.
    function test_failed_deposit_records_the_leg_for_recovery() public {
        pusdcRoute.deliverTokens(_b32(address(exec)), 100e6);
        vault.setRejectDeposits(true);

        vm.expectEmit(true, true, true, true);
        emit SubDepositDeferred(1);
        _deliver(1, 100e6); // must NOT revert - the record is the recovery

        (uint256 amount,, bool exists, bool executed,,) = exec.pending(1);
        assertEq(amount, 100e6);
        assertTrue(exists, "recorded so executeDeposit/abortDeposit can act");
        assertFalse(executed);

        vault.setRejectDeposits(false);
        exec.executeDeposit(1);
        (,,, bool done,,) = exec.pending(1);
        assertTrue(done, "poking works once the cause clears");
    }

    function test_executeDeposit_for_an_unrecorded_leg_reverts() public {
        vm.expectRevert(InvalidState.selector);
        exec.executeDeposit(1); // nothing was ever recorded - the message is what gets retried
    }

    function test_executeDeposit_twice_reverts() public {
        pusdcRoute.deliverTokens(_b32(address(exec)), 100e6);
        _deliver(1, 100e6);
        vm.expectRevert(InvalidState.selector);
        exec.executeDeposit(1);
    }

    function test_executeDeposit_for_an_unknown_batch_reverts() public {
        vm.expectRevert(InvalidState.selector);
        exec.executeDeposit(99);
    }

    /// @dev Idempotency at the handler (constitution Art 4.1), independent of the mailbox's
    /// own replay guard: a second delivery of the same batch must not deposit twice.
    function test_redelivery_is_a_no_op() public {
        pusdcRoute.deliverTokens(_b32(address(exec)), 200e6); // enough for two, to prove it does not
        _deliver(1, 100e6);
        uint256 depositedOnce = pusdcRoute.balanceOf(address(vault));

        _deliver(1, 100e6); // same batch again
        assertEq(pusdcRoute.balanceOf(address(vault)), depositedOnce, "no second deposit");
    }

    function test_redeem_records_when_shares_present() public {
        _deliverRedeemShares(address(exec), 100e6);
        vm.expectEmit(true, true, true, true);
        emit RedeemRecorded(1, 100e6, 100e6); // grossAssets = mulDiv(100e6, 1e18, 1e18)
        _deliverRedeem(1, 100e6, 1e18);

        (uint256 shares, uint256 nav, uint256 gross, uint64 deadline, bool exists,,,) = exec.pendingRedeem(1);
        assertEq(shares, 100e6);
        assertEq(nav, 1e18);
        assertEq(gross, 100e6);
        assertEq(deadline, uint64(block.timestamp + REDEEM_FULFILL_TIMEOUT), "authoritative PRUV deadline");
        assertTrue(exists);
        assertEq(exec.pendingRedeemShares(), 100e6, "shares reserved");
    }

    function test_redeem_instruction_before_shares_reverts_and_records_nothing() public {
        vm.expectRevert(NotReadyToExecute.selector);
        _deliverRedeem(1, 100e6, 1e18);
        (,,,, bool exists,,,) = exec.pendingRedeem(1);
        assertFalse(exists, "message stays re-processable, nothing recorded");
    }

    /// @dev ADR-026: an uninitialised or mis-pointed NAV source must never let a leg record with a
    /// zero funding target -- that would make executeRedeem's rendezvous gate pass trivially
    /// (`balanceOf >= 0`). Records nothing, same as any other revert here (re-processable).
    function test_redeem_recordReverts_onZeroLocalNav() public {
        conversion.setValue(0);
        _deliverRedeemShares(address(exec), 100e6);
        vm.expectRevert(ZeroNav.selector);
        _deliverRedeem(1, 100e6, 1e18);
        (,,,, bool exists,,,) = exec.pendingRedeem(1);
        assertFalse(exists, "message stays re-processable, nothing recorded");
    }

    function test_redeem_grossAssets_scales_with_nav() public {
        _deliverRedeemShares(address(exec), 100e6);
        conversion.setValue(1.2e18); // record-time local read (ADR-026), not the wire navAtInitiate
        _deliverRedeem(1, 100e6, 1e18); // gross = mulDiv(100e6, 1.2e18, 1e18) = 120e6
        (,, uint256 gross,,,,,) = exec.pendingRedeem(1);
        assertEq(gross, 120e6);
    }

    function test_redeem_redelivery_is_a_no_op() public {
        _deliverRedeemShares(address(exec), 200e6); // enough for two — prove it does not double-count
        _deliverRedeem(1, 100e6, 1e18);
        _deliverRedeem(1, 100e6, 1e18); // same batch again
        assertEq(exec.pendingRedeemShares(), 100e6, "idempotent: reserved once");
    }

    function test_redeem_parallel_batch_no_false_rendezvous() public {
        // Batch A's 100e6 shares land and record; they are reserved.
        _deliverRedeemShares(address(exec), 100e6);
        _deliverRedeem(1, 100e6, 1e18);
        assertEq(exec.pendingRedeemShares(), 100e6);

        // Batch B's instruction arrives before B's shares. The executor still HOLDS A's 100e6, but
        // they are reserved — B must NOT rendezvous on them (that would later burn A's shares).
        vm.expectRevert(NotReadyToExecute.selector);
        _deliverRedeem(2, 80e6, 1e18);
        (,,,, bool bExists,,,) = exec.pendingRedeem(2);
        assertFalse(bExists, "B did not false-rendezvous on A's reserved shares");
    }

    event RedeemBatchFulfilled(uint64 legId, uint256 usdcOut);

    function _fundVault(uint256 amt) internal {
        pusdcRoute.deliverTokens(_b32(address(vault)), amt); // issuer sold off-chain, funded the vault
    }

    function _recordRedeem1(uint256 shares) internal {
        _deliverRedeemShares(address(exec), shares);
        _deliverRedeem(1, shares, 1e18);
    }

    function test_executeRedeem_reverts_until_vault_funded() public {
        _recordRedeem1(100e6);
        vm.expectRevert(NotReadyToExecute.selector);
        exec.executeRedeem(1); // vault holds 0 USDC

        _fundVault(100e6);
        vm.expectEmit(true, true, true, true);
        emit RedeemBatchFulfilled(1, 100e6);
        exec.executeRedeem(1);

        (,,,,, bool executed,,) = exec.pendingRedeem(1);
        assertTrue(executed, "latched");
        assertEq(exec.pendingRedeemShares(), 0, "reserve released");
        assertEq(pusdcRoute.balanceOf(address(exec)), 0, "net USDC burned to bridge home");
        (, bytes32 instrId,,,) = exec.lastReturnLeg();
        assertTrue(instrId != bytes32(0), "Redeem return dispatched");
    }

    function test_executeRedeem_slippage_breach_reverts_and_rolls_back() public {
        _recordRedeem1(100e6);
        _fundVault(100e6);
        vault.setRedeemRateBps(9800); // 98% < floor 99% (slippage 100bps) -> breach

        vm.expectRevert(SlippageExceeded.selector);
        exec.executeRedeem(1);

        (,,,,, bool executed,,) = exec.pendingRedeem(1);
        assertFalse(executed, "rolled back atomically");
        assertEq(exec.pendingRedeemShares(), 100e6, "reserve intact");
        assertEq(IERC20(address(vault)).balanceOf(address(exec)), 100e6, "shares restored by rollback");
    }

    function test_executeRedeem_within_tolerance_executes() public {
        _recordRedeem1(100e6);
        _fundVault(100e6);
        vault.setRedeemRateBps(9950); // 99.5% >= floor 99%
        exec.executeRedeem(1);
        (,,,,, bool executed,,) = exec.pendingRedeem(1);
        assertTrue(executed, "just clears the floor");
    }

    /// @dev ADR-026: the execute-time floor read is guarded against 0 too, and guarded BEFORE the
    /// burn -- unlike the deposit path (which fails safe on a mulDiv-by-zero panic), a redeem is
    /// atomic and irreversible once shares are burned, so a 0 price must never be allowed to make
    /// usdcOut=0 clear a 0 floor and latch. The source read 1e18 at record time (nonzero, so the
    /// leg records fine); it is moved to 0 only afterward, before executing.
    function test_executeRedeem_revertsOnZeroLocalNav() public {
        _recordRedeem1(100e6);
        _fundVault(100e6);
        conversion.setValue(0);
        vm.expectRevert(ZeroNav.selector);
        exec.executeRedeem(1);

        (,,,,, bool executed,,) = exec.pendingRedeem(1);
        assertFalse(executed, "not latched -- shares must not have been burned");
        assertEq(exec.pendingRedeemShares(), 100e6, "reserve intact");
    }

    /// @dev ADR-026: the floor at execute time must come from a LOCAL read taken THEN, not from
    /// the record-time price -- and not from the wire either. Record while the source reads
    /// A=2e18 (gross = mulDiv(100e6, 2e18, 1e18) = 200e6, funded below), with the WIRE nav set to
    /// a third, distinct value (7e18) so a hypothetical wire-derived floor cannot coincidentally
    /// agree with either A or B and pass by accident. Then move the source to B=1e18 before
    /// executing: floor(A) = mulDiv(mulDiv(100e6, 2e18, 1e18), 9900, 1e4) = 198e6, floor(B) =
    /// mulDiv(mulDiv(100e6, 1e18, 1e18), 9900, 1e4) = 99e6. A fill of 150e6 clears floor(B) but
    /// sits below floor(A) -- it would have reverted under the old record-time behaviour, so this
    /// genuinely distinguishes the two prices.
    function test_redeemFloorUsesTheLocalSourceAtExecuteTime() public {
        conversion.setValue(2e18); // A, at record time
        _deliverRedeemShares(address(exec), 100e6);
        _deliverRedeem(1, 100e6, 7e18); // wire nav: a THIRD price, distinct from A and B
        _fundVault(200e6); // grossAssets, fixed at A

        conversion.setValue(1e18); // B, moved before execute
        vault.setRedeemRateBps(15000); // usdcOut = 150e6: >= floor(B)=99e6, < floor(A)=198e6
        exec.executeRedeem(1);

        (,,,,, bool executed,,) = exec.pendingRedeem(1);
        assertTrue(executed, "cleared the execute-time floor derived from B, not the stale A or the wire");
    }

    /// @dev Same record/move setup as above (including the distinct wire nav); the fill now sits
    /// below floor(B) = 99e6 too.
    function test_redeemFloorRevertsWhenTheLocalPriceIsNotMet() public {
        conversion.setValue(2e18); // A, at record time
        _deliverRedeemShares(address(exec), 100e6);
        _deliverRedeem(1, 100e6, 7e18); // wire nav: a THIRD price, distinct from A and B
        _fundVault(200e6);

        conversion.setValue(1e18); // B, moved before execute -- floor(B) = 99e6
        vault.setRedeemRateBps(5000); // usdcOut = 50e6 < floor(B)
        vm.expectRevert(SlippageExceeded.selector);
        exec.executeRedeem(1);
    }

    /// @dev The tautological half: `grossAssets` re-read from the same storage slot after moving
    /// the price. No refactor of `_recordRedeem`/`executeRedeem` could make this fail -- Solidity
    /// storage does not spontaneously change -- so it proves only that the write happened, not
    /// WHEN the value was computed. Kept for the storage-stability sanity check; since ADR-030 D7
    /// the gate no longer reads it at all -- `test_executeGateReadsTheLiveVaultTarget` below is
    /// what guards the execute-time funding target now.
    function test_grossAssetsUsesTheRecordTimePrice() public {
        conversion.setValue(1e18);
        _recordRedeem1(100e6);
        (,, uint256 recorded,,,,,) = exec.pendingRedeem(1);
        assertEq(recorded, 100e6);

        conversion.setValue(3e18);
        (,, uint256 stillRecorded,,,,,) = exec.pendingRedeem(1);
        assertEq(stillRecorded, recorded, "grossAssets moved after recording");
    }

    /// @dev ADR-030 D7: the execute gate asks the VAULT what it will charge right now
    /// (`convertToAssets(shares)`), not the record-time `grossAssets`. Record at A = 1e18 (gross =
    /// 100e6), then point the vault at the same source and move it to B = 3e18, so the live target
    /// is 300e6 while the stored `grossAssets` stays 100e6. Funding 299e6 clears the OLD gate
    /// comfortably and must still be refused; the last 1e6 is what makes the batch payable. The
    /// floor cannot mask either half: floor(B) = mulDiv(300e6, 9900, 1e4) = 297e6, below both
    /// funding levels, so the refusal can only come from the gate.
    function test_executeGateReadsTheLiveVaultTarget() public {
        conversion.setValue(1e18); // A, at record time -> grossAssets = 100e6
        _recordRedeem1(100e6);

        vault.setConversion(address(conversion)); // the vault now prices off the same source
        conversion.setValue(3e18); // B -> convertToAssets(100e6) = 300e6
        assertEq(exec.redeemTarget(1), 300e6, "the live target moved with the vault");

        _fundVault(299e6); // above the record-time 100e6, one micro-unit short of the live target
        vm.expectRevert(NotReadyToExecute.selector);
        exec.executeRedeem(1);

        _fundVault(1e6); // now the vault can actually pay what it will charge
        exec.executeRedeem(1);

        (,,,,, bool executed,,) = exec.pendingRedeem(1);
        assertTrue(executed, "gate cleared only once the vault held its own live price");
    }

    function test_executeRedeem_unrecorded_reverts() public {
        vm.expectRevert(InvalidState.selector);
        exec.executeRedeem(1);
    }

    function test_executeRedeem_twice_reverts() public {
        _recordRedeem1(100e6);
        _fundVault(100e6);
        exec.executeRedeem(1);
        vm.expectRevert(InvalidState.selector);
        exec.executeRedeem(1);
    }

    event RedeemBatchAborted(uint64 legId);

    function test_abortRedeem_before_deadline_reverts() public {
        _recordRedeem1(100e6);
        vm.expectRevert(AbortBeforeDeadline.selector);
        exec.abortRedeem(1);
    }

    /// @dev ADR-030 D11: a payable batch past its deadline is not refused, it is PAID -- the abort
    /// call tries the redemption first and only sends the shares home if that attempt fails.
    function test_abortRedeem_while_payable_executes_instead() public {
        _recordRedeem1(100e6);
        _fundVault(100e6); // vault can pay
        vm.warp(block.timestamp + REDEEM_FULFILL_TIMEOUT + 1);
        exec.abortRedeem(1);

        (,,,,, bool executed, bool aborted,) = exec.pendingRedeem(1);
        assertTrue(executed, "the abort call executed the batch");
        assertFalse(aborted, "a payable redeem is never cancelled");
        assertEq(exec.pendingRedeemShares(), 0, "reserve released");
    }

    function test_abortRedeem_unfunded_after_deadline_bridges_wrwa_home() public {
        _recordRedeem1(100e6);
        vm.warp(block.timestamp + REDEEM_FULFILL_TIMEOUT + 1);

        vm.expectEmit(true, true, true, true);
        emit RedeemBatchAborted(1);
        exec.abortRedeem(1);

        (,,,,,, bool aborted,) = exec.pendingRedeem(1);
        assertTrue(aborted, "latched");
        assertEq(exec.pendingRedeemShares(), 0, "reserve released");
        assertEq(IERC20(address(vault)).balanceOf(address(exec)), 0, "shares bridged home, not held");
        (, bytes32 instrId,,,) = exec.lastReturnLeg();
        assertTrue(instrId != bytes32(0), "RedeemAborted return dispatched");
    }

    function test_abortRedeem_unrecorded_reverts() public {
        vm.expectRevert(BatchAlreadyResolved.selector);
        exec.abortRedeem(1);
    }

    function test_abortRedeem_twice_reverts() public {
        _recordRedeem1(100e6);
        vm.warp(block.timestamp + REDEEM_FULFILL_TIMEOUT + 1);
        exec.abortRedeem(1);
        vm.expectRevert(BatchAlreadyResolved.selector);
        exec.abortRedeem(1);
    }

    function test_aborted_redeem_inert_to_executeRedeem() public {
        _recordRedeem1(100e6);
        vm.warp(block.timestamp + REDEEM_FULFILL_TIMEOUT + 1);
        exec.abortRedeem(1);
        _fundVault(100e6); // even funded now, the aborted leg must not execute
        vm.expectRevert(InvalidState.selector);
        exec.executeRedeem(1);
    }

    function test_wrong_kind_reverts() public {
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.RedeemAborted, amount: 1e6, navAtInitiate: 1e18}));
        vm.prank(address(mailbox));
        vm.expectRevert(InvalidState.selector);
        exec.handle(PRUV_DOMAIN, _b32(home), body);
    }

    function test_recorded_leg_stamps_a_future_deadline() public {
        pusdcRoute.deliverTokens(_b32(address(exec)), 100e6);
        vault.setRejectDeposits(true); // record without executing, so the leg persists
        _deliver(1, 100e6);
        (,,,, uint64 deadline,) = exec.pending(1);
        assertEq(deadline, uint64(block.timestamp + SUB_FULFILL_TIMEOUT), "deadline stamped at record");
    }

    function test_constructor_rejects_slippage_over_100pct() public {
        vm.expectRevert(InvalidState.selector);
        _deployExecutorWithSlippage(10001); // > 1e4 → the floor math (1e4 - bps) would underflow
    }

    /// @dev Mirrors `setUp`'s deployment, varying only `executorSlippageBps` — for the constructor
    /// boundary tests below (ADR-026 D5).
    function _deployExecutorWithSlippage(uint256 bps) internal returns (PruvExecutor) {
        return new PruvExecutor(
            IMailbox(address(mailbox)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            address(vault),
            address(pusdcRoute),
            IWarpRoute(address(pusdcRoute)),
            SUB_FULFILL_TIMEOUT,
            bps,
            REDEEM_FULFILL_TIMEOUT,
            conversion,
            0,
            0
        );
    }

    function test_constructorRejectsFullSlippage() public {
        // ADR-026 D5: at 1e4 the floor computes to 0, and the floor is the ONLY guard on vault
        // output in either path -- a 0-share deposit would be accepted and latched.
        vm.expectRevert(InvalidState.selector);
        _deployExecutorWithSlippage(1e4);
    }

    function test_constructorAcceptsFiftyPercent() public {
        PruvExecutor e = _deployExecutorWithSlippage(5000);
        assertEq(e.executorSlippageBps(), 5000);
    }

    function test_constructorRejectsZeroRwaConversion() public {
        vm.expectRevert(InvalidState.selector);
        new PruvExecutor(
            IMailbox(address(mailbox)),
            IWarpRoute(address(wrwaRoute)),
            PRUV_DOMAIN,
            address(vault),
            address(pusdcRoute),
            IWarpRoute(address(pusdcRoute)),
            SUB_FULFILL_TIMEOUT,
            SLIPPAGE_BPS,
            REDEEM_FULFILL_TIMEOUT,
            IRWAConversion(address(0)),
            0,
            0
        );
    }

    function test_slippage_adverse_fill_defers_and_leaves_usdc_here() public {
        pusdcRoute.deliverTokens(_b32(address(exec)), 100e6);
        conversion.setValue(0.9e18); // floor ≈ 110e6 > 100e6 fill → deferred, NOT reverted (execute-time local read)

        vm.expectEmit(true, true, true, true);
        emit SubDepositDeferred(1);
        _deliver(1, 100e6);

        (,,, bool executed,,) = exec.pending(1);
        assertFalse(executed, "did not latch");
        assertEq(pusdcRoute.balanceOf(address(exec)), 100e6, "USDC rolled back, still here - leg recoverable");
        assertEq(pusdcRoute.balanceOf(address(vault)), 0, "no shares minted");

        vm.expectRevert(NotReadyToExecute.selector);
        exec.executeDeposit(1); // still below floor — keeper poke reverts loudly
    }

    function test_slippage_within_tolerance_executes() public {
        pusdcRoute.deliverTokens(_b32(address(exec)), 100e6);
        // Wire nav = 0 on purpose (a later task changes the home chain to send exactly this):
        // the floor is driven by `conversion` (default 1e18), not this field. If a bug read the
        // wire value instead, mulDiv(amount, 1e18, 0) would panic and the deposit would defer
        // instead of executing.
        _deliverNav(1, 100e6, 0); // floor = 99e6 ≤ 100e6 fill → executes
        (,,, bool executed,,) = exec.pending(1);
        assertTrue(executed, "1:1 fill clears the 1% floor, independent of the wire nav");
    }

    function test_depositChecked_is_self_only() public {
        pusdcRoute.deliverTokens(_b32(address(exec)), 100e6);
        vault.setRejectDeposits(true);
        _deliver(1, 100e6); // record the leg
        vm.expectRevert(UnauthorizedSender.selector);
        exec._depositChecked(1); // external caller must not drive the raw deposit
    }

    function test_abortDeposit_before_deadline_reverts() public {
        _recordStuck(1, 100e6);
        vm.expectRevert(AbortBeforeDeadline.selector);
        exec.abortDeposit(1);
    }

    function test_abortDeposit_on_unrecorded_reverts() public {
        vm.expectRevert(BatchAlreadyResolved.selector);
        exec.abortDeposit(1); // nothing recorded — not in an abortable state
    }

    function test_abortDeposit_gate_closed_bridges_usdc_home() public {
        _recordStuck(1, 100e6);
        vm.warp(block.timestamp + SUB_FULFILL_TIMEOUT + 1);

        vm.expectEmit(true, true, true, true);
        emit SubDepositAborted(1);
        exec.abortDeposit(1);

        (,,, bool executed,, bool aborted) = exec.pending(1);
        assertTrue(aborted, "aborted latched");
        assertFalse(executed);
        assertEq(pusdcRoute.balanceOf(address(exec)), 0, "synthetic USDC burned to bridge home");
        (, bytes32 instrId,,,) = exec.lastReturnLeg();
        assertTrue(instrId != bytes32(0), "SubAborted instruction dispatched");
    }

    function test_abortDeposit_gate_reopened_executes_not_aborts() public {
        _recordStuck(1, 100e6);
        vm.warp(block.timestamp + SUB_FULFILL_TIMEOUT + 1);
        vault.setRejectDeposits(false); // gate reopened before the keeper pokes

        exec.abortDeposit(1);

        (,,, bool executed,, bool aborted) = exec.pending(1);
        assertTrue(executed, "try-then-abort: deposit completed instead of aborting");
        assertFalse(aborted, "no abort - subscriber gets wRWA");
        assertEq(pusdcRoute.balanceOf(address(vault)), 100e6, "USDC deposited, not bridged home");
    }

    function test_abortDeposit_twice_reverts() public {
        _recordStuck(1, 100e6);
        vm.warp(block.timestamp + SUB_FULFILL_TIMEOUT + 1);
        exec.abortDeposit(1);
        vm.expectRevert(BatchAlreadyResolved.selector);
        exec.abortDeposit(1);
    }

    function test_aborted_leg_is_inert_to_executeDeposit() public {
        _recordStuck(1, 100e6);
        vm.warp(block.timestamp + SUB_FULFILL_TIMEOUT + 1);
        exec.abortDeposit(1); // batch 1 aborted; its 100e6 burned

        // a LATER batch's fungible USDC lands on the executor
        pusdcRoute.deliverTokens(_b32(address(exec)), 300e6);
        vm.expectRevert(InvalidState.selector);
        exec.executeDeposit(1); // aborted leg must not consume batch 2's USDC
        assertEq(pusdcRoute.balanceOf(address(exec)), 300e6, "later batch's funds untouched");
    }

    /// @dev AT-190 — the wRWA return route (subscribe leg) charges a cross-token fee in USDC.
    /// The executor must approve/pay it out of its own USDC float so the return leg completes.
    function test_approveForRoute_crossTokenFee_subReturnCompletes() public {
        wrwaRoute.setFee(IERC20(address(pusdcRoute)), 750000, address(0xFEE));
        pusdcRoute.deliverTokens(_b32(address(exec)), 750000); // fund the executor's USDC float
        pusdcRoute.deliverTokens(_b32(address(exec)), 100e6); // subscribe funds
        _deliver(1, 100e6); // must NOT revert; the fee must be pulled

        assertEq(pusdcRoute.balanceOf(address(0xFEE)), 750000);
    }

    /// @dev AT-190 — the usdc return route (redeem leg) charges a same-token fee (the fee token
    /// IS the routed token). The float must cover the fee on top of the redeemed amount.
    function test_approveForRoute_sameTokenFee_redeemReturnCompletes() public {
        pusdcRoute.setFee(IERC20(address(pusdcRoute)), 750000, address(0xFEE));
        pusdcRoute.deliverTokens(_b32(address(exec)), 750000); // float on top of the redeemed USDC
        _recordRedeem1(100e6);
        _fundVault(100e6);
        exec.executeRedeem(1);

        assertEq(pusdcRoute.balanceOf(address(0xFEE)), 750000);
    }

    /// @dev AT-190 — the load-bearing collapse branch: a COLLATERAL route whose fee token is the
    /// SAME as its locked token produces quotes `[gas, T=amount, T=fee]` (exactly what the live
    /// PRUV usdc route emits: `[native, USDC=amount, USDC=750000]`). The override must fold both
    /// T entries into ONE summed `forceApprove(T, route, amount+fee)` — a buggy version that
    /// issued two separate forceApprove calls would have the second (fee-only) call OVERWRITE
    /// the first (amount) allowance via `forceApprove`'s set-not-add semantics, so the route's
    /// first pull (of `amount`) would revert on insufficient allowance. Assert both effects of a
    /// correct single summed approval: the leg completes AND the route actually pulled
    /// `amount + fee` total (locked `amount` + collected `fee`), not just `fee`.
    function test_approveForRoute_sameTokenCollapse_collateralRoute_singleApproval() public {
        wrwaRoute.setFee(IERC20(address(vault)), 750000, address(0xFEE));

        // Fund the executor's vault-share float BEFORE the deposit mints the subscribed shares,
        // so held(vault) at approval time = float + freshly minted shares = amount + fee exactly.
        deal(address(vault), address(exec), 750000);
        pusdcRoute.deliverTokens(_b32(address(exec)), 100e6); // subscribe funds
        _deliver(1, 100e6); // must NOT revert — a broken two-approve split would revert here

        assertEq(vault.balanceOf(address(0xFEE)), 750000, "fee collected");
        assertEq(vault.balanceOf(address(wrwaRoute)), 100e6, "shares locked by the route");
    }

    /// @dev AT-190 — no USDC float minted: the executor's own committed-balance check refuses the
    /// return leg before the route's transferFrom can. Since ADR-030 D11 that refusal happens
    /// inside `_depositChecked`, so it rolls the deposit back and the leg DEFERS (spec §3.4)
    /// rather than reverting the delivery. The recoverable ending is the point: nothing latched,
    /// no fee drawn, and the leg completes as soon as ops funds the float.
    function test_approveForRoute_insufficientFloat_defers_until_the_float_is_funded() public {
        wrwaRoute.setFee(IERC20(address(pusdcRoute)), 750000, address(0xFEE));
        pusdcRoute.deliverTokens(_b32(address(exec)), 100e6); // subscribe funds only, no fee float

        vm.expectEmit(true, true, true, true);
        emit SubDepositDeferred(1);
        _deliver(1, 100e6);

        (,, bool exists, bool executed,,) = exec.pending(1);
        assertTrue(exists, "recorded, so the leg stays pokeable");
        assertFalse(executed, "the deposit rolled back with the unfundable fee");
        assertEq(pusdcRoute.balanceOf(address(exec)), 100e6, "no USDC left the executor");
        assertEq(pusdcRoute.balanceOf(address(0xFEE)), 0, "no fee drawn from the subscriber's own escrow");

        pusdcRoute.deliverTokens(_b32(address(exec)), 750000); // ops funds the float
        exec.executeDeposit(1);
        (,,, bool done,,) = exec.pending(1);
        assertTrue(done, "the same leg completes once the fee is payable");
        assertEq(pusdcRoute.balanceOf(address(0xFEE)), 750000);
    }

    event Swept(address indexed token, address indexed to, uint256 amount);

    function test_sweep_rwaToken_reverts() public {
        _recordRedeem1(100e6); // pendingRedeemShares = 100e6
        _deliverRedeemShares(address(exec), 5e6); // extra free shares (mis-sent)

        // rwaToken is no longer rescuable at all: the executor has no on-chain signal for an
        // incoming-but-unrecorded redeem return, so even the "free above pendingRedeemShares"
        // slice can't be safely bounded (cf. Aave AToken UNDERLYING_CANNOT_BE_RESCUED).
        vm.expectRevert(InvalidState.selector);
        exec.sweep(address(vault), makeAddr("treasury"), 5e6);

        assertEq(vault.balanceOf(address(exec)), 105e6, "no shares moved");
        assertEq(exec.pendingRedeemShares(), 100e6, "reserved shares untouched");
    }

    /// @dev M-6 (AT-192 Task 3): `usdc` is no longer write-only -- free float (nothing recorded
    /// against it) is fully sweepable. The committed-floor case lives in
    /// `PruvExecutor.float.t.sol`'s `test_M6_sweep_recovers_free_float_but_not_committed`.
    function test_sweep_usdc_sweeps_free_float() public {
        pusdcRoute.deliverTokens(_b32(address(exec)), 10e6);
        exec.sweep(address(pusdcRoute), makeAddr("treasury"), 10e6);
        assertEq(pusdcRoute.balanceOf(makeAddr("treasury")), 10e6);
    }

    function test_sweep_stray_token_full_balance() public {
        MockERC20 stray = new MockERC20("STRAY", 18);
        stray.mint(address(exec), 5e18);

        exec.sweep(address(stray), makeAddr("treasury"), 5e18);
        assertEq(stray.balanceOf(makeAddr("treasury")), 5e18);
        assertEq(stray.balanceOf(address(exec)), 0);
    }

    function test_sweep_non_owner_reverts() public {
        MockERC20 stray = new MockERC20("STRAY", 18);
        stray.mint(address(exec), 1e18);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(); // OwnableUnauthorizedAccount
        exec.sweep(address(stray), makeAddr("treasury"), 1e18);
    }

    /// @dev T2 access-matrix parity (BridgeAdapter, ADR-011): renounce is disabled on the
    /// executor too -- a renounce would permanently brick every onlyOwner recovery power here
    /// (sweep, enrollRemote) with no path back.
    function test_renounceOwnership_reverts() public {
        vm.expectRevert(RenounceDisabled.selector);
        exec.renounceOwnership();
    }

    function test_sweep_non_owner_reverts_specific_selector() public {
        address stranger = makeAddr("stranger");
        MockERC20 stray = new MockERC20("STRAY", 18);
        stray.mint(address(exec), 1e18);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        exec.sweep(address(stray), makeAddr("treasury"), 1e18);
    }

    function test_enrollRemote_non_owner_reverts() public {
        address stranger = makeAddr("stranger");
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        exec.enrollRemote(PRUV_DOMAIN, _b32(stranger));
    }

    function test_FF2_18dec_shares_diverge_from_fixed_1e18_convention() public {
        MockRWAToken18 vault18 = new MockRWAToken18(address(pusdcRoute), false);
        // A dedicated collateral route, NOT the shared `wrwaRoute` — that one's `lockedToken`
        // is immutably wired to the 6-dec `vault` from setUp() and cannot carry vault18's shares.
        MockCollateralWarpRoute wrwaRoute18 = new MockCollateralWarpRoute(IERC20(address(vault18)));
        wrwaRoute18.setGasQuote(0);
        PruvExecutor exec18 = new PruvExecutor(
            IMailbox(address(mailbox)),
            IWarpRoute(address(wrwaRoute18)),
            PRUV_DOMAIN,
            address(vault18),
            address(pusdcRoute),
            IWarpRoute(address(pusdcRoute)),
            SUB_FULFILL_TIMEOUT,
            SLIPPAGE_BPS,
            REDEEM_FULFILL_TIMEOUT,
            conversion,
            0,
            0
        );
        exec18.enrollRemote(PRUV_DOMAIN, _b32(home));

        pusdcRoute.deliverTokens(_b32(address(exec18)), 100e6);
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 100e6, navAtInitiate: 0}));
        vm.prank(address(mailbox));
        exec18.handle(PRUV_DOMAIN, _b32(home), body);

        // ADR-028: the floor is decimal-aware (expects 100e18 shares) and the return instruction carries
        // micro-units, so 100e18 shares leave as amount 100e6.
        (,,, bool executed,,) = exec18.pending(1);
        assertTrue(executed, "an 18-decimal fill at par clears the decimal-aware floor");
        (, bytes32 instrMsgId,,, RequestKind kind) = exec18.lastReturnLeg();
        assertEq(uint8(kind), uint8(RequestKind.Subscribe));
        // The token leg moves local units (100e18 shares); the paired instruction leg moves
        // micro-units (100e6) — this is the property the whole task adds, and it is only visible
        // by decoding the dispatched instruction, not by reading `lastReturnLeg` alone
        // (`returnedAmount` is always 0 at send time — it is filled in on the RETURN delivery).
        (,,, bytes memory retBody,,) = mailbox.messageOf(instrMsgId);
        Instruction memory retInstr = Codec.decode(retBody);
        assertEq(uint8(retInstr.kind), uint8(RequestKind.Subscribe));
        assertEq(retInstr.amount, 100e6, "wire instruction carries micro-units, not local 18-dec shares");
        assertEq(IERC20(address(vault18)).balanceOf(address(wrwaRoute18)), 100e18, "all shares sent");
    }

    function test_FF2_18dec_half_fill_caught_by_decimal_aware_floor() public {
        MockRWAToken18 vault18 = new MockRWAToken18(address(pusdcRoute), true);
        MockCollateralWarpRoute wrwaRoute18 = new MockCollateralWarpRoute(IERC20(address(vault18)));
        wrwaRoute18.setGasQuote(0);
        PruvExecutor exec18 = new PruvExecutor(
            IMailbox(address(mailbox)),
            IWarpRoute(address(wrwaRoute18)),
            PRUV_DOMAIN,
            address(vault18),
            address(pusdcRoute),
            IWarpRoute(address(pusdcRoute)),
            SUB_FULFILL_TIMEOUT,
            SLIPPAGE_BPS,
            REDEEM_FULFILL_TIMEOUT,
            conversion,
            0,
            0
        );
        exec18.enrollRemote(PRUV_DOMAIN, _b32(home));

        pusdcRoute.deliverTokens(_b32(address(exec18)), 100e6);
        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 100e6, navAtInitiate: 0}));
        vm.expectEmit(false, false, false, true);
        emit SubDepositDeferred(1);
        vm.prank(address(mailbox));
        exec18.handle(PRUV_DOMAIN, _b32(home), body);

        // ADR-028: a half-size fill (50e18 shares against a ~99e18 decimal-aware floor) is deferred —
        // the decimal-blind floor (≈99e6) could not have caught this.
        (,,, bool executed,,) = exec18.pending(1);
        assertFalse(executed, "a half-size 18-decimal fill is deferred by the decimal-aware floor");
    }
}
