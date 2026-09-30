// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {Codec} from "@rex-shared/Codec.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/Errors.sol";
import "../../src/PruvExecutor.sol";
import {IRWAConversion} from "../../src/NavReporter.sol";

/// @notice The class of failure mocks cannot reach: `PruvExecutor` 1.4.0 against the REAL Pruv
/// testnet — the real vault proxy, its real compliance/config contract, the real conversion and fee
/// modules, and the real Hyperlane mailbox and warp routes, forked at head.
///
/// **What is faked, and only this:** the two soulbound ERC-1155 credentials the vault's config
/// consults (`canDeposit` reads `0xdE1d…72FC`, `canTransfer` reads `0x43D2…Ac99`, both at token id
/// 1). A freshly deployed executor cannot hold them and Pruv grants them by hand, one working day
/// at a time (ADR-011's correction). `_grantCredentials` mocks those two `balanceOf` reads to 1 —
/// everything the vault then does with that answer is the deployed code. `test_the_real_gate_refuses`
/// deliberately does NOT grant them, and pins the live refusal selector.
///
/// Not in scope here: ADR-029's epoch window and ADR-031's recovery both live in `REXPrimary` on the
/// home chain, which this fork does not carry.
///
/// Run: `yarn contracts:test:fork` (excluded from the default suite — it needs the network).
abstract contract PruvForkBase is Test {
    // --- real PRUV testnet, from config/deploy/testnet-dev.params.json + deployments.json ---
    address constant VAULT = 0x5d5C787E29a807194F8bC82eE2CFBddce2407370; // TREX01, ERC-4626-shaped
    address constant CONVERSION = 0x261113D0c29e83D37EE3081E933f18743665e546;
    address constant PRUV_USDC = 0x756EfF2C697835bE39ea6D4B897305A207374cBE;
    address constant USDC_ROUTE = 0x725e38fcB4fd2f6711d888C0F369E6a6DbA1c16A; // collateral, holds USDC
    address constant WRWA_ROUTE = 0x660F4183C4bFBaA52569467E465FF320dB05e44E; // collateral, holds TREX01
    address constant MAILBOX = 0x72364A5F747a4e6E17b13Be4b421b879E95D95E7;
    address constant DEPOSIT_CREDENTIAL = 0xdE1db49Ce5Cdbf8A7bE85C9376ef4024aE6772FC;
    address constant TRANSFER_CREDENTIAL = 0x43D212e1668e89E54113aFD833EFB15D2877Ac99;
    address constant SENDER_WHITELIST_HOOK = 0xa679Eb6A2EA00DAE0FA0dDfB240FEd14984e8390;
    address constant VAULT_CONFIG = 0x9788B5559eB415264019f942D797c4a3578051Ab;
    address constant LIVE_EXECUTOR = 0x2Ece79C6FE21Fe05c05DAd794FBD1739194DB8A4;
    uint32 constant HOME_DOMAIN = 11155111;

    // --- the shipped testnet-dev parameters ---
    uint256 constant SUB_FULFILL = 3600;
    uint256 constant SLIPPAGE_BPS = 5000;
    uint256 constant REDEEM_FULFILL = 864000;
    uint64 constant REDEEM_DELAY = 600;
    uint64 constant MIN_REDEEM_DELAY = 60;

    PruvExecutor exec;
    address homeRouter = makeAddr("homeRexPrimary");

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function setUp() public virtual {
        vm.createSelectFork("https://rpc.testnet.pruv.network");
        exec = new PruvExecutor(
            IMailbox(MAILBOX),
            IWarpRoute(WRWA_ROUTE),
            HOME_DOMAIN,
            VAULT,
            PRUV_USDC,
            IWarpRoute(USDC_ROUTE),
            SUB_FULFILL,
            SLIPPAGE_BPS,
            REDEEM_FULFILL,
            IRWAConversion(CONVERSION),
            REDEEM_DELAY,
            MIN_REDEEM_DELAY
        );
        exec.enrollRemote(HOME_DOMAIN, _b32(homeRouter));
        vm.deal(address(exec), 10 ether); // `_sendPair` pays both gas quotes from its own balance
    }

    /// @dev Pruv's config refuses a fresh executor even once the credential reads return 1 --
    /// `canDeposit(address,uint256,uint256)` weighs more than the NFT, and what else it weighs is
    /// not public. Faking its verdict is the smallest cut that still leaves the vault's accounting,
    /// the conversion module, the fee module and the share mint entirely real, which is the class
    /// of behaviour mocks cannot reproduce and this suite exists for.
    function _allowCompliance(address who) internal {
        _grantCredentials(who);
        // `(bool ok, string reason)` -- a stranger gets `(false, "NOT_WHITELISTED")`, the live
        // executor `(true, "")`. Returning a bare bool makes the vault revert on decode.
        vm.mockCall(VAULT_CONFIG, abi.encodeWithSignature("canDeposit(address,uint256,uint256)"), abi.encode(true, ""));
        vm.mockCall(VAULT_CONFIG, abi.encodeWithSignature("canTransfer(address)"), abi.encode(true, ""));
        // The redeem path asks a third question, and it is the one that refuses a fresh executor
        // even when both credential reads return 1.
        vm.mockCall(VAULT_CONFIG, abi.encodeWithSignature("canWithdraw(address,uint256,uint256)"), abi.encode(true, ""));
    }

    /// @dev The credential half on its own: the two soulbound ERC-1155 reads at token id 1.
    function _grantCredentials(address who) internal {
        vm.mockCall(
            DEPOSIT_CREDENTIAL, abi.encodeWithSignature("balanceOf(address,uint256)", who, uint256(1)), abi.encode(1)
        );
        vm.mockCall(
            TRANSFER_CREDENTIAL, abi.encodeWithSignature("balanceOf(address,uint256)", who, uint256(1)), abi.encode(1)
        );
    }

    /// @dev The second fake, and it is not optional: PRUV's mailbox runs a `SenderWhitelistHook`
    /// that reverts in `quoteDispatch` for any sender it does not know, so a freshly deployed
    /// executor cannot dispatch at all until Pruv adds it (see
    /// `test_a_fresh_executor_is_not_on_the_mailbox_sender_whitelist`). Neutralising the hook here
    /// leaves the mailbox, the routes and the vault real.
    function _whitelistSender() internal {
        vm.mockCall(
            SENDER_WHITELIST_HOOK, abi.encodeWithSignature("quoteDispatch(bytes,bytes)"), abi.encode(uint256(0))
        );
        vm.mockCall(SENDER_WHITELIST_HOOK, abi.encodeWithSignature("postDispatch(bytes,bytes)"), bytes(""));
    }

    /// @dev Deliver an inbound instruction exactly as the mailbox would.
    function _deliver(RequestKind kind, uint64 legId, uint256 amount, uint256 nav) internal {
        bytes memory body = Codec.encode(Instruction({legId: legId, kind: kind, amount: amount, navAtInitiate: nav}));
        vm.prank(MAILBOX);
        exec.handle(HOME_DOMAIN, _b32(homeRouter), body);
    }

    /// @dev Move the executor real TREX01 from the warp route's collateral. Transfers are ungated
    /// for a credentialed holder, and the route itself holds the transfer credential.
    function _giveShares(uint256 shares) internal {
        vm.prank(WRWA_ROUTE);
        (bool ok,) = VAULT.call(abi.encodeWithSignature("transfer(address,uint256)", address(exec), shares));
        require(ok, "share transfer from the route failed");
    }

    function _usdcOf(address who) internal view returns (uint256) {
        return IERC20(PRUV_USDC).balanceOf(who);
    }

    function _sharesOf(address who) internal view returns (uint256) {
        (, bytes memory r) = VAULT.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        return abi.decode(r, (uint256));
    }

    function _nav() internal view returns (uint256) {
        return IRWAConversion(CONVERSION).value();
    }
}

/// @notice The subscribe leg against the real vault and its real compliance gate.
contract PruvForkDepositTest is PruvForkBase {
    /// @dev The live refusal, pinned. A fresh executor holds no credential, so the vault's config
    /// rejects the deposit — and the executor must DEFER (leg recorded, recoverable) rather than
    /// revert the whole delivery, which is what keeps the subscriber's money recoverable (ADR-012).
    function test_the_real_gate_refuses_and_the_leg_is_deferred() public {
        deal(PRUV_USDC, address(exec), 100e6);
        _deliver(RequestKind.Subscribe, 1, 100e6, 1e18);

        (uint256 amount,,, bool executed, bool aborted) = _pending(1);
        assertEq(amount, 100e6, "the leg is recorded even though the vault said no");
        assertFalse(executed);
        assertFalse(aborted);
        assertEq(_sharesOf(address(exec)), 0, "no shares minted");

        // And the raw call proves WHY: the deployed config's own refusal selector.
        vm.startPrank(address(exec));
        IERC20(PRUV_USDC).approve(VAULT, 1e6);
        (bool ok, bytes memory err) =
            VAULT.call(abi.encodeWithSignature("deposit(uint256,address)", 1e6, address(exec)));
        vm.stopPrank();
        assertFalse(ok, "an uncredentialed deposit must fail");
        assertEq(bytes4(err), bytes4(0xc49b118b), "the live gate's refusal selector changed");
    }

    /// @dev Grant the credential and the SAME deferred leg completes through `executeDeposit`:
    /// real vault mint, real conversion, real fee module, real outbound warp route.
    function test_deferred_leg_completes_once_the_gate_opens() public {
        deal(PRUV_USDC, address(exec), 100e6);
        _deliver(RequestKind.Subscribe, 1, 100e6, 1e18);

        _allowCompliance(address(exec));
        _whitelistSender();
        exec.executeDeposit(1);

        (,,, bool executed,) = _pending(1);
        assertTrue(executed, "the leg completed on the retry");
        assertEq(_usdcOf(address(exec)), 0, "every bridged USDC went into the vault");
        // The shares left over the real route; what stays is at most a sub-micro-unit remainder.
        assertLt(_sharesOf(address(exec)), 1, "shares were bridged home, not parked");
    }

    /// @dev Past the deadline with the gate still shut, the USDC goes home for a refund.
    function test_abortDeposit_refunds_through_the_real_route() public {
        deal(PRUV_USDC, address(exec), 100e6);
        _deliver(RequestKind.Subscribe, 1, 100e6, 1e18);

        vm.warp(vm.getBlockTimestamp() + SUB_FULFILL + 1);
        _whitelistSender();
        uint256 routeBefore = _usdcOf(USDC_ROUTE);
        exec.abortDeposit(1);

        (,,,, bool aborted) = _pending(1);
        assertTrue(aborted, "the leg aborted");
        assertEq(_usdcOf(address(exec)), 0, "the executor kept nothing");
        assertEq(_usdcOf(USDC_ROUTE) - routeBefore, 100e6, "the real collateral route took the refund");
    }

    function _pending(uint64 id)
        internal
        view
        returns (uint256 amount, uint256 navAtInitiate, uint64 deadline, bool executed, bool aborted)
    {
        (amount, navAtInitiate,, executed, deadline, aborted) = exec.pending(id);
    }
}

/// @notice What a redeployment actually needs from Pruv, measured on the live chain rather than
/// assumed. `ADR-011`'s correction says the executor moves on every deployment and needs a fresh
/// grant; this pins that there are TWO grants, not one, and that the second is easy to forget
/// because it is invisible until the first outbound send.
contract PruvForkGrantsTest is PruvForkBase {
    function test_a_fresh_executor_is_not_on_the_mailbox_sender_whitelist() public {
        bytes memory body = hex"00";
        // The LIVE executor dispatches fine — it is on the list.
        vm.prank(LIVE_EXECUTOR);
        (bool liveOk,) = MAILBOX.call(
            abi.encodeWithSignature("quoteDispatch(uint32,bytes32,bytes)", HOME_DOMAIN, _b32(homeRouter), body)
        );
        assertTrue(liveOk, "the live executor should still be whitelisted");

        // The one deployed in `setUp` does not.
        vm.prank(address(exec));
        (bool freshOk, bytes memory err) = MAILBOX.call(
            abi.encodeWithSignature("quoteDispatch(uint32,bytes32,bytes)", HOME_DOMAIN, _b32(homeRouter), body)
        );
        assertFalse(freshOk, "a fresh executor must be refused until Pruv whitelists it");
        assertGt(err.length, 0, "the refusal carries a reason");
    }

    /// @dev What the LIVE deployment actually holds, so the grant list is measured and not
    /// inferred: exactly one NFT on the executor, and nothing at all on the warp route -- which
    /// confirms the project's standing claim that the bridge collateral needs no whitelisting
    /// (CLAUDE.md, "Pruv confirmed 2026-08-26"), on chain rather than on a recollection.
    function test_the_live_deployment_needs_exactly_one_credential() public view {
        assertEq(_cred(DEPOSIT_CREDENTIAL, LIVE_EXECUTOR), 1, "the executor holds the deposit credential");
        assertEq(_cred(TRANSFER_CREDENTIAL, LIVE_EXECUTOR), 0, "and only that one");
        assertEq(_cred(DEPOSIT_CREDENTIAL, WRWA_ROUTE), 0, "the route holds none");
        assertEq(_cred(TRANSFER_CREDENTIAL, WRWA_ROUTE), 0, "neither kind");

        (, bytes memory r) = VAULT_CONFIG.staticcall(abi.encodeWithSignature("canTransfer(address)", WRWA_ROUTE));
        (bool ok,) = abi.decode(r, (bool, string));
        assertTrue(ok, "and transfers are open to it anyway");
    }

    function _cred(address nft, address who) internal view returns (uint256) {
        (, bytes memory r) = nft.staticcall(abi.encodeWithSignature("balanceOf(address,uint256)", who, uint256(1)));
        return abi.decode(r, (uint256));
    }

    function test_a_fresh_executor_holds_neither_credential() public view {
        (, bytes memory dep) = DEPOSIT_CREDENTIAL.staticcall(
            abi.encodeWithSignature("balanceOf(address,uint256)", address(exec), uint256(1))
        );
        (, bytes memory tr) = TRANSFER_CREDENTIAL.staticcall(
            abi.encodeWithSignature("balanceOf(address,uint256)", address(exec), uint256(1))
        );
        assertEq(abi.decode(dep, (uint256)), 0, "no deposit credential");
        assertEq(abi.decode(tr, (uint256)), 0, "no transfer credential");
    }
}

/// @notice ADR-030 against the real vault: both anchors, oldest-first, the live funding target, and
/// try-then-abort. The vault, its conversion and fee modules and both warp routes are the deployed
/// contracts; only the compliance verdict and the mailbox's sender whitelist are faked (see the base).
contract PruvForkRedeemTest is PruvForkBase {
    uint256 constant SHARES = 5e6;

    function setUp() public override {
        super.setUp();
        _giveShares(SHARES * 4);
        _allowCompliance(address(exec));
        _whitelistSender();
    }

    /// @dev D1, first anchor: the batch's own `notBefore`.
    function test_redeem_waits_for_its_own_delay() public {
        _deliver(RequestKind.Redeem, 1, SHARES, 1e18);
        vm.expectRevert(NotReadyToExecute.selector);
        exec.executeRedeem(1);

        vm.warp(vm.getBlockTimestamp() + REDEEM_DELAY + 1);
        uint256 routeBefore = _usdcOf(USDC_ROUTE);
        exec.executeRedeem(1);
        assertGt(_usdcOf(USDC_ROUTE) - routeBefore, 0, "the real vault paid and the route took it home");
    }

    /// @dev D1, second anchor: a deposit that lands afterwards pushes every waiting redeem out by
    /// `redeemDelay` (the Lead's OQ-1 = (b) ruling). Proved here against the real vault's mint.
    function test_a_later_deposit_pushes_the_redeem_out() public {
        _deliver(RequestKind.Redeem, 1, SHARES, 1e18);
        vm.warp(vm.getBlockTimestamp() + REDEEM_DELAY + 1); // its own anchor is satisfied

        deal(PRUV_USDC, address(exec), 10e6);
        _deliver(RequestKind.Subscribe, 2, 10e6, 1e18); // deposits into the REAL vault, stamps the anchor
        assertGt(exec.depositUnlockAt(), vm.getBlockTimestamp(), "the deposit re-armed the global anchor");

        vm.expectRevert(NotReadyToExecute.selector);
        exec.executeRedeem(1);

        vm.warp(uint256(exec.depositUnlockAt()) + 1);
        exec.executeRedeem(1); // now it pays
    }

    /// @dev D10: a newer batch cannot jump an older open one, on the real vault.
    function test_oldest_first_on_the_real_vault() public {
        _deliver(RequestKind.Redeem, 1, SHARES, 1e18);
        _deliver(RequestKind.Redeem, 2, SHARES, 1e18);
        vm.warp(vm.getBlockTimestamp() + REDEEM_DELAY + 1);

        assertEq(exec.oldestOpenRedeem(), 1, "batch 1 is the head");
        vm.expectRevert(NotReadyToExecute.selector);
        exec.executeRedeem(2);

        exec.executeRedeem(1);
        assertEq(exec.oldestOpenRedeem(), 2, "the head advanced");
        exec.executeRedeem(2);
    }

    /// @dev D7/D9: `redeemTarget` is what the vault will charge RIGHT NOW, and it is the number the
    /// gate uses -- not the record-time figure. Drain the vault to one unit below it and the poke
    /// refuses; put that unit back and it pays.
    function test_the_live_target_is_the_gate() public {
        _deliver(RequestKind.Redeem, 1, SHARES, 1e18);
        vm.warp(vm.getBlockTimestamp() + REDEEM_DELAY + 1);

        uint256 target = exec.redeemTarget(1);
        assertGt(target, 0, "the vault quotes a real target");
        deal(PRUV_USDC, VAULT, target - 1);
        vm.expectRevert(NotReadyToExecute.selector);
        exec.executeRedeem(1);

        deal(PRUV_USDC, VAULT, target);
        exec.executeRedeem(1);
    }

    /// @dev D11: abort attempts the redemption first. A payable batch past its deadline is PAID,
    /// not refunded -- and the attempt runs the real vault, not a forecast.
    function test_abort_pays_a_payable_batch_instead_of_refunding_it() public {
        _deliver(RequestKind.Redeem, 1, SHARES, 1e18);
        vm.warp(vm.getBlockTimestamp() + REDEEM_FULFILL + 1);

        uint256 routeBefore = _usdcOf(USDC_ROUTE);
        exec.abortRedeem(1);

        (,,,,, bool executed, bool aborted,) = exec.pendingRedeem(1);
        assertTrue(executed, "the attempt succeeded, so it is a payout");
        assertFalse(aborted, "and not an abort");
        assertGt(_usdcOf(USDC_ROUTE) - routeBefore, 0, "USDC went home");
    }

    /// @dev D11, the other ending: with the vault unable to pay, the same call refunds the shares.
    function test_abort_refunds_when_the_real_vault_cannot_pay() public {
        _deliver(RequestKind.Redeem, 1, SHARES, 1e18);
        vm.warp(vm.getBlockTimestamp() + REDEEM_FULFILL + 1);

        deal(PRUV_USDC, VAULT, 0); // the issuer never funded it
        uint256 routeSharesBefore = _sharesOf(WRWA_ROUTE);
        exec.abortRedeem(1);

        (,,,,, bool executed, bool aborted,) = exec.pendingRedeem(1);
        assertFalse(executed);
        assertTrue(aborted, "the shares went home instead");
        assertEq(_sharesOf(WRWA_ROUTE) - routeSharesBefore, SHARES, "the real route took them");
    }
}

/// @notice The price moves between record and execute. Every test in the repo outside this file
/// runs at NAV 1.0; here the executor's oracle read is moved while the vault's own share maths
/// stays the deployed code, which is the only way to see the slippage floor do its job for real.
contract PruvForkNavTest is PruvForkBase {
    uint256 constant SHARES = 5e6;

    function setUp() public override {
        super.setUp();
        _giveShares(SHARES * 4);
        _allowCompliance(address(exec));
        _whitelistSender();
    }

    function _setNav(uint256 nav) internal {
        vm.mockCall(CONVERSION, abi.encodeWithSignature("value()"), abi.encode(nav));
    }

    /// @dev D8: the floor rides the oracle. A price that FALLS after the record leaves the vault's
    /// real output comfortably above the floor, so the batch settles at what the vault actually pays.
    function test_a_nav_fall_between_record_and_execute_still_settles() public {
        assertEq(_nav(), 1e18, "fixture assumption: the live NAV is 1.0");
        _deliver(RequestKind.Redeem, 1, SHARES, 1e18);
        vm.warp(vm.getBlockTimestamp() + REDEEM_DELAY + 1);

        _setNav(0.6e18); // the oracle says the fund is worth less; the vault still pays its own rate
        uint256 routeBefore = _usdcOf(USDC_ROUTE);
        exec.executeRedeem(1);
        assertGt(_usdcOf(USDC_ROUTE) - routeBefore, 0, "it settled at the vault's real output");
    }

    /// @dev The other direction is the one that protects the holder: an oracle that RISES puts the
    /// floor above what the vault will really pay, and the poke refuses rather than selling low.
    function test_a_nav_spike_breaches_the_floor_and_refuses() public {
        _deliver(RequestKind.Redeem, 1, SHARES, 1e18);
        vm.warp(vm.getBlockTimestamp() + REDEEM_DELAY + 1);

        _setNav(3e18); // floor = shares * 3 * (1 - 50%) = 1.5x what the vault pays at 1:1
        vm.expectRevert(SlippageExceeded.selector);
        exec.executeRedeem(1);

        // And past the deadline that same breach is what turns the poke into a refund (D11).
        vm.warp(vm.getBlockTimestamp() + REDEEM_FULFILL + 1);
        uint256 routeSharesBefore = _sharesOf(WRWA_ROUTE);
        exec.abortRedeem(1);
        assertEq(_sharesOf(WRWA_ROUTE) - routeSharesBefore, SHARES, "the shares went home");
    }

    /// @dev **Finding B4's question, answered on the real vault.** The 2026-09-18 actor-behaviour
    /// review asked what a vault exit fee can take from a redeemer, and the answer is "anything the
    /// slippage band tolerates" -- shipped as `executorSlippageBps = 5000`, i.e. FIFTY PERCENT.
    ///
    /// A fee and an oracle move are the same event to this contract: both make the vault's real
    /// `usdcOut` fall short of `mulDiv(shares, navNow, 1e18)`, and the floor is the only thing
    /// weighing that gap. So moving the oracle is how the band's boundary gets exercised without
    /// Pruv's fee-module keys -- an oracle at `1 / (1 - x)` is exactly a fee of `x`.
    ///
    /// The live vault pays 1:1 today (measured: `convertToAssets(1e6) == 1e6`, no fee), which is
    /// why this is the only way to see the boundary at all.
    function test_the_band_tolerates_a_49_percent_shortfall_and_refuses_51() public {
        _deliver(RequestKind.Redeem, 1, SHARES, 1e18);
        _deliver(RequestKind.Redeem, 2, SHARES, 1e18);
        vm.warp(vm.getBlockTimestamp() + REDEEM_DELAY + 1);

        // Equivalent to the vault taking 49% -- inside the 50% band, so it settles and the
        // redeemers simply receive less. Nothing in the contract objects.
        _setNav((uint256(1e18) * 100) / 51); // floor = shares * (100/51) * 0.5 = 0.98 * shares < what it pays
        uint256 routeBefore = _usdcOf(USDC_ROUTE);
        exec.executeRedeem(1);
        assertGt(_usdcOf(USDC_ROUTE) - routeBefore, 0, "a 49% shortfall settles: the band allows it");

        // One point past the band and the same call refuses -- which is the whole protection.
        _setNav((uint256(1e18) * 100) / 49); // floor = 1.02 * shares > what it pays
        vm.expectRevert(SlippageExceeded.selector);
        exec.executeRedeem(2);
    }

    /// @dev What the band would be if it were tightened, so the cost of the decision is visible
    /// rather than argued: at 300 bps the same 49% shortfall is refused outright.
    function test_a_tight_band_would_have_refused_that_shortfall() public {
        PruvExecutor tight = new PruvExecutor(
            IMailbox(MAILBOX),
            IWarpRoute(WRWA_ROUTE),
            HOME_DOMAIN,
            VAULT,
            PRUV_USDC,
            IWarpRoute(USDC_ROUTE),
            SUB_FULFILL,
            300, // 3%, instead of the shipped 5000
            REDEEM_FULFILL,
            IRWAConversion(CONVERSION),
            REDEEM_DELAY,
            MIN_REDEEM_DELAY
        );
        tight.enrollRemote(HOME_DOMAIN, _b32(homeRouter));
        vm.deal(address(tight), 10 ether);
        _allowCompliance(address(tight));
        vm.prank(WRWA_ROUTE);
        (bool ok,) = VAULT.call(abi.encodeWithSignature("transfer(address,uint256)", address(tight), SHARES));
        require(ok, "share transfer failed");

        bytes memory body =
            Codec.encode(Instruction({legId: 1, kind: RequestKind.Redeem, amount: SHARES, navAtInitiate: 1e18}));
        vm.prank(MAILBOX);
        tight.handle(HOME_DOMAIN, _b32(homeRouter), body);
        vm.warp(vm.getBlockTimestamp() + REDEEM_DELAY + 1);

        _setNav((uint256(1e18) * 100) / 51); // the same 49% shortfall the shipped band waves through
        vm.expectRevert(SlippageExceeded.selector);
        tight.executeRedeem(1);
    }

    /// @dev A zero from the oracle must stop the money path, not be treated as a free redemption.
    function test_a_zero_nav_stops_the_redeem() public {
        _deliver(RequestKind.Redeem, 1, SHARES, 1e18);
        vm.warp(vm.getBlockTimestamp() + REDEEM_DELAY + 1);
        _setNav(0);
        vm.expectRevert(ZeroNav.selector);
        exec.executeRedeem(1);
    }

    /// @dev The subscribe-side floor, same idea in the other direction: an oracle far below the
    /// vault's real mint rate makes the deposit's own floor unreachable, so the leg defers instead
    /// of minting at a price the protocol did not intend.
    function test_a_nav_that_makes_the_deposit_floor_unreachable_defers_the_leg() public {
        deal(PRUV_USDC, address(exec), 100e6);
        _setNav(0.1e18); // floor = amount / 0.1 * (1 - 50%) = 5x the shares the vault will mint
        _deliver(RequestKind.Subscribe, 1, 100e6, 1e18);

        (,,, bool executed,) = _pendingExecuted(1);
        assertFalse(executed, "the leg deferred rather than minting below its floor");
        assertEq(_usdcOf(address(exec)), 100e6, "the money is still here, recoverable");
    }

    function _pendingExecuted(uint64 id)
        internal
        view
        returns (uint256 amount, uint256 nav, uint64 deadline, bool executed, bool aborted)
    {
        (amount, nav,, executed, deadline, aborted) = exec.pending(id);
    }
}

/// @notice ADR-030 D11's real invariant, measured on the deployed routes rather than on mocks:
/// a gas-starved attempt cannot force a payable batch into an abort, and that holds only because
/// the redemption branch costs far less than 63x the abort branch.
contract PruvForkGasRatioTest is PruvForkBase {
    uint256 constant SHARES = 5e6;

    function setUp() public override {
        super.setUp();
        _giveShares(SHARES * 2);
        _allowCompliance(address(exec));
        _whitelistSender();
    }

    function test_the_redeem_branch_is_far_below_63x_the_abort_branch() public {
        _deliver(RequestKind.Redeem, 1, SHARES, 1e18);
        vm.warp(vm.getBlockTimestamp() + REDEEM_FULFILL + 1);

        uint256 snap = vm.snapshotState();
        uint256 g0 = gasleft();
        exec.executeRedeem(1);
        uint256 redeemGas = g0 - gasleft();
        vm.revertToState(snap);

        deal(PRUV_USDC, VAULT, 0); // the vault cannot pay -> the same call refunds
        g0 = gasleft();
        exec.abortRedeem(1);
        uint256 abortGas = g0 - gasleft();

        emit log_named_uint("redeem branch gas", redeemGas);
        emit log_named_uint("abort branch gas", abortGas);
        assertGt(abortGas, 0, "the abort branch ran");
        assertLt(
            redeemGas,
            abortGas * 63,
            "ADR-030 D11 holds only while the redemption costs less than 63x the abort on the REAL routes"
        );
    }

    /// @dev ADR-028 D1 on the deployed tokens. The units are internal, so this pins what they are
    /// derived from -- and that the constructor accepted these two tokens at all, which it only
    /// does for 6..18 decimals. Both being 6 is why the wire still carries v1's bytes.
    function test_the_units_come_from_the_real_tokens_decimals() public view {
        (, bytes memory u) = PRUV_USDC.staticcall(abi.encodeWithSignature("decimals()"));
        (, bytes memory r) = VAULT.staticcall(abi.encodeWithSignature("decimals()"));
        assertEq(abi.decode(u, (uint8)), 6, "PRUV USDC is 6-decimal");
        assertEq(abi.decode(r, (uint8)), 6, "TREX01 is 6-decimal");
    }
}
