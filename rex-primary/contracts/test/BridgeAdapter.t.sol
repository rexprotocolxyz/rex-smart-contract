// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {Codec} from "@rex-shared/Codec.sol";
import "../src/BridgeAdapter.sol";
import "@rex-shared/IHyperlane.sol";
import "@rex-shared/Wire.sol";
import "@rex-shared/Errors.sol";
import "../src/libraries/State.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "./mocks/MockERC20.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@rex-shared-mocks/MockSyntheticWarpRoute.sol";

/// @dev Concrete stand-in exposing the last decoded Instruction so the test
/// can assert on _onInstruction's inputs without a real settlement side effect.
contract TestBridgeAdapter is BridgeAdapter {
    uint32 public lastOrigin;
    Instruction public lastInstruction;

    constructor(IMailbox _mailbox) BridgeAdapter(_mailbox) {}

    function _onInstruction(uint32 origin, Instruction memory instr) internal override {
        lastOrigin = origin;
        lastInstruction = instr;
    }

    /// @dev Test-only passthrough so the send path can be exercised directly;
    /// never add this to production BridgeAdapter.
    function sendPair(uint32 dst, IWarpRoute route, IERC20 approveToken, uint256 amount, Instruction memory instr)
        external
        payable
        returns (Leg memory)
    {
        return _sendPair(dst, route, approveToken, amount, instr);
    }

    receive() external payable {}
}

contract BridgeAdapterTest is Test {
    MockMailbox mailbox;
    TestBridgeAdapter adapter;

    uint32 constant REMOTE_DOMAIN = 7336;
    bytes32 enrolledRouter = bytes32(uint256(uint160(address(0xBEEF))));

    function setUp() public {
        mailbox = new MockMailbox(1);
        adapter = new TestBridgeAdapter(IMailbox(address(mailbox)));
    }

    function test_handle_fromUnenrolledSender_reverts() public {
        Instruction memory instr =
            Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 100e6, navAtInitiate: 1e18});

        vm.prank(address(mailbox));
        vm.expectRevert(UnauthorizedSender.selector);
        adapter.handle(REMOTE_DOMAIN, enrolledRouter, Codec.encode(instr));
    }

    function test_handle_fromEnrolledSender_decodesAndDispatches() public {
        adapter.enrollRemote(REMOTE_DOMAIN, enrolledRouter);

        Instruction memory instr =
            Instruction({legId: 42, kind: RequestKind.Redeem, amount: 250e6, navAtInitiate: 1.05e18});

        vm.prank(address(mailbox));
        adapter.handle(REMOTE_DOMAIN, enrolledRouter, Codec.encode(instr));

        assertEq(adapter.lastOrigin(), REMOTE_DOMAIN);
        (uint64 legId, RequestKind kind, uint256 amount, uint256 nav) = adapter.lastInstruction();
        assertEq(legId, 42);
        assertEq(uint8(kind), uint8(RequestKind.Redeem));
        assertEq(amount, 250e6);
        assertEq(nav, 1.05e18);
    }

    /// @dev I-2 — the real Mailbox calls `handle{value: msg.value}(...)`
    /// (`Mailbox.sol:241`); `handle` must be payable or a valued delivery reverts.
    function test_handle_deliveredWithValue_succeeds() public {
        adapter.enrollRemote(REMOTE_DOMAIN, enrolledRouter);
        Instruction memory instr =
            Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 100e6, navAtInitiate: 1e18});

        vm.deal(address(mailbox), 1);
        vm.prank(address(mailbox));
        adapter.handle{value: 1}(REMOTE_DOMAIN, enrolledRouter, Codec.encode(instr));

        assertEq(adapter.lastOrigin(), REMOTE_DOMAIN);
    }

    function test_handle_notMailbox_reverts() public {
        adapter.enrollRemote(REMOTE_DOMAIN, enrolledRouter);
        Instruction memory instr =
            Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 100e6, navAtInitiate: 1e18});

        vm.expectRevert(UnauthorizedSender.selector);
        adapter.handle(REMOTE_DOMAIN, enrolledRouter, Codec.encode(instr));
    }

    function test_sendPair_toUnenrolledDst_reverts() public {
        MockERC20 local = new MockERC20("local", 6);
        MockCollateralWarpRoute route = new MockCollateralWarpRoute(local);
        local.mint(address(adapter), 100e6);

        Instruction memory instr =
            Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 100e6, navAtInitiate: 1e18});

        vm.expectRevert(UnenrolledRemote.selector);
        adapter.sendPair(REMOTE_DOMAIN, IWarpRoute(address(route)), IERC20(address(local)), 100e6, instr);
    }

    /// @dev C1 — the adapter must QUOTE both legs and attach the quoted native gas.
    /// Against a route/mailbox that honestly charges (the mock default, mirroring the
    /// real fork), a funded send must SUCCEED.
    /// Reference: `hyperlane-bridge.md` §"Send a token + paired instruction" steps 1,3,4.
    function test_sendPair_quotes_and_pays_interchain_gas() public {
        adapter.enrollRemote(REMOTE_DOMAIN, enrolledRouter);

        MockERC20 local = new MockERC20("local", 6);
        MockCollateralWarpRoute route = new MockCollateralWarpRoute(local);
        local.mint(address(adapter), 100e6);

        assertGt(route.gasQuote(), 0, "route must require a non-zero fee by default, like the real fork");
        assertGt(mailbox.quoteFee(), 0, "mailbox must require a non-zero fee by default");

        Instruction memory instr =
            Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 100e6, navAtInitiate: 1e18});

        uint256 fees = route.gasQuote() + mailbox.quoteFee();
        vm.deal(address(this), fees);
        payable(address(adapter)).transfer(fees); // fund the adapter's gas

        Leg memory leg =
            adapter.sendPair(REMOTE_DOMAIN, IWarpRoute(address(route)), IERC20(address(local)), 100e6, instr);
        assertTrue(leg.tokenMsgId != bytes32(0), "token leg dispatched");
        assertTrue(leg.instrMsgId != bytes32(0), "instruction leg dispatched");
    }

    /// @dev The adapter must fail loudly when it cannot cover the quoted gas,
    /// rather than reverting deep inside the route.
    function test_sendPair_unfunded_reverts_InsufficientGasPayment() public {
        adapter.enrollRemote(REMOTE_DOMAIN, enrolledRouter);

        MockERC20 local = new MockERC20("local", 6);
        MockCollateralWarpRoute route = new MockCollateralWarpRoute(local);
        local.mint(address(adapter), 100e6);

        Instruction memory instr =
            Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 100e6, navAtInitiate: 1e18});

        vm.expectRevert(InsufficientGasPayment.selector);
        adapter.sendPair(REMOTE_DOMAIN, IWarpRoute(address(route)), IERC20(address(local)), 100e6, instr);
    }

    /// @dev AT-190 (base behaviour) — the base `_approveForRoute` hook still approves
    /// exactly `amount` for a fee-free collateral route: the route locks `amount`
    /// and the adapter's allowance to it is consumed to 0.
    function test_base_approvesCollateralExactly() public {
        adapter.enrollRemote(REMOTE_DOMAIN, enrolledRouter);

        MockERC20 local = new MockERC20("local", 6);
        MockCollateralWarpRoute route = new MockCollateralWarpRoute(local);
        local.mint(address(adapter), 100e6);

        Instruction memory instr =
            Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 100e6, navAtInitiate: 1e18});

        uint256 fees = route.gasQuote() + mailbox.quoteFee();
        vm.deal(address(this), fees);
        payable(address(adapter)).transfer(fees);

        adapter.sendPair(REMOTE_DOMAIN, IWarpRoute(address(route)), IERC20(address(local)), 100e6, instr);

        assertEq(local.balanceOf(address(route)), 100e6, "route locked amount");
        assertEq(local.allowance(address(adapter), address(route)), 0, "allowance consumed to 0");
    }

    /// @dev AT-190 (base behaviour) — a synthetic route (`approveToken == address(0)`)
    /// needs no approval at all; the base hook must no-op and the burn-based transfer
    /// still succeeds.
    function test_base_syntheticRoute_needsNoApproval() public {
        adapter.enrollRemote(REMOTE_DOMAIN, enrolledRouter);

        MockSyntheticWarpRoute route = new MockSyntheticWarpRoute("pUSDC", 6);
        route.deliverTokens(bytes32(uint256(uint160(address(adapter)))), 100e6);

        Instruction memory instr =
            Instruction({legId: 1, kind: RequestKind.Subscribe, amount: 100e6, navAtInitiate: 1e18});

        uint256 fees = route.gasQuote() + mailbox.quoteFee();
        vm.deal(address(this), fees);
        payable(address(adapter)).transfer(fees);

        Leg memory leg = adapter.sendPair(REMOTE_DOMAIN, IWarpRoute(address(route)), IERC20(address(0)), 100e6, instr);
        assertTrue(leg.tokenMsgId != bytes32(0), "token leg dispatched without approval");
    }

    /// @dev AT-190 — the live PRUV wRWA route charges a real cross-token fee
    /// (0.75 USDC) that `transferRemote` actually PULLS, distinct from the
    /// quote-only `tokenCharge`/`externalCharge` knobs above. Reproduces the
    /// missing-approval revert and confirms the fee lands with the collector.
    function test_MockCollateralRoute_pullsCrossTokenFee_revertsWithoutApproval() public {
        MockERC20 usdc = new MockERC20("USDC", 6);
        MockERC20 rwa = new MockERC20("wRWA", 6);
        MockCollateralWarpRoute route = new MockCollateralWarpRoute(IERC20(address(rwa)));
        address feeCollector = address(0xFEE);
        route.setFee(IERC20(address(usdc)), 750000, feeCollector);

        rwa.mint(address(this), 100e6);
        rwa.approve(address(route), 100e6);
        route.setGasQuote(0);
        // No USDC approval for the fee -> transferRemote must revert.
        vm.expectRevert();
        route.transferRemote{value: 0}(11155111, bytes32(uint256(uint160(address(this)))), 100e6);

        // With USDC + balance, it succeeds and pulls the fee.
        usdc.mint(address(this), 750000);
        usdc.approve(address(route), 750000);
        route.transferRemote{value: 0}(11155111, bytes32(uint256(uint160(address(this)))), 100e6);
        assertEq(usdc.balanceOf(feeCollector), 750000);
    }
}
