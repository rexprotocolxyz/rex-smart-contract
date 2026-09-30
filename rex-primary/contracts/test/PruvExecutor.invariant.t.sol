// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "./helpers/World.sol";

/// @notice Stateful invariants on the executor's redeem surface across the SC13 matrix: the executor
/// holds every share it owes, a batch resolves at most once, and the head is always the oldest open.
/// @dev `World.setUp` is reachable through both bases of each concrete suite (this one and the
/// `Config` mixin), so solc demands the resolution be spelled out there: each suite restates the
/// override and delegates to this base, whose `super.setUp()` then runs World's.
abstract contract PruvExecutorInvariantBase is World {
    PruvExecutorRedeemHandler internal handler;

    function setUp() public virtual override {
        super.setUp();
        handler = new PruvExecutorRedeemHandler(exec, mailbox, pusdcRoute, vault, pruvWrwaRoute, address(rex));
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = handler.deliverAndRecord.selector;
        selectors[1] = handler.fundVaultAndExecute.selector;
        selectors[2] = handler.warpAndAbort.selector;
        targetContract(address(handler));
        targetSelector(StdInvariant.FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    function invariant_executorShareSolvency() public view {
        assertGe(vault.balanceOf(address(exec)), exec.pendingRedeemShares());
    }

    function invariant_resolvedAtMostOnce() public view {
        uint256 n = handler.recordedCount();
        for (uint256 i = 0; i < n; i++) {
            (,,,,, bool executed, bool aborted,) = exec.pendingRedeem(handler.recordedIds(i));
            assertFalse(executed && aborted);
        }
    }

    function invariant_headIsOldestOpen() public view {
        uint64 head = exec.oldestOpenRedeem();
        uint256 n = handler.recordedCount();
        for (uint256 i = 0; i < n; i++) {
            uint64 id = handler.recordedIds(i);
            (,,,,, bool executed, bool aborted,) = exec.pendingRedeem(id);
            if (!executed && !aborted) {
                assertEq(head, id, "head is the first open batch in record order");
                return;
            }
        }
        assertEq(head, 0);
    }
}

contract PruvExecutorInvariantTest is DefaultConfig, PruvExecutorInvariantBase {
    function setUp() public override(World, PruvExecutorInvariantBase) {
        PruvExecutorInvariantBase.setUp();
    }
}

contract PruvExecutorInvariantNavDriftTest is NavDriftConfig, PruvExecutorInvariantBase {
    function setUp() public override(World, PruvExecutorInvariantBase) {
        PruvExecutorInvariantBase.setUp();
    }
}

contract PruvExecutorInvariantPercentFeeTest is PercentFeeConfig, PruvExecutorInvariantBase {
    function setUp() public override(World, PruvExecutorInvariantBase) {
        PruvExecutorInvariantBase.setUp();
    }
}

contract PruvExecutorInvariantFixedFeeTest is FixedFeeConfig, PruvExecutorInvariantBase {
    function setUp() public override(World, PruvExecutorInvariantBase) {
        PruvExecutorInvariantBase.setUp();
    }
}

contract PruvExecutorRedeemHandler is Test {
    uint32 constant PRUV_DOMAIN = 7336;
    uint256 constant MIN_SHARES = 10e6; // above 2F for FixedFee (F = 1e6)
    uint256 constant MAX_SHARES = 1e12;

    PruvExecutor public exec;
    MockMailbox public mailbox;
    MockSyntheticWarpRoute public pusdcRoute;
    MockRWAToken public vault;
    MockCollateralWarpRoute public wrwaRoute;
    address public home;
    uint64 public nextBatchId = 1;
    uint64[] public recordedIds;

    constructor(
        PruvExecutor exec_,
        MockMailbox mailbox_,
        MockSyntheticWarpRoute pusdcRoute_,
        MockRWAToken vault_,
        MockCollateralWarpRoute wrwaRoute_,
        address home_
    ) {
        exec = exec_;
        mailbox = mailbox_;
        pusdcRoute = pusdcRoute_;
        vault = vault_;
        wrwaRoute = wrwaRoute_;
        home = home_;
    }

    function recordedCount() external view returns (uint256) {
        return recordedIds.length;
    }

    function _b32(address a) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(a)));
    }

    function deliverAndRecord(uint256 sharesSeed) external {
        uint256 shares = bound(sharesSeed, MIN_SHARES, MAX_SHARES);
        uint64 batchId = nextBatchId++;
        deal(address(vault), address(wrwaRoute), vault.balanceOf(address(wrwaRoute)) + shares);
        wrwaRoute.deliverTokens(_b32(address(exec)), shares);
        bytes memory body =
            Codec.encode(Instruction({legId: batchId, kind: RequestKind.Redeem, amount: shares, navAtInitiate: 0}));
        vm.prank(address(mailbox));
        exec.handle(PRUV_DOMAIN, _b32(home), body);
        recordedIds.push(batchId);
    }

    /// @dev Only the head may execute (ADR-030 D10): fund exactly its live target, then execute it.
    function fundVaultAndExecute() external {
        uint64 head = exec.oldestOpenRedeem();
        if (head == 0) return;
        uint256 target = exec.redeemTarget(head);
        uint256 held = pusdcRoute.balanceOf(address(vault));
        if (held < target) pusdcRoute.deliverTokens(_b32(address(vault)), target - held);
        exec.executeRedeem(head);
    }

    /// @dev After the deadline any open batch resolves: executed if payable and at the head, else aborted.
    function warpAndAbort(uint256 idSeed) external {
        uint256 n = recordedIds.length;
        if (n == 0) return;
        uint64 id = recordedIds[idSeed % n];
        (,,, uint64 deadline, bool exists, bool executed, bool aborted,) = exec.pendingRedeem(id);
        if (!exists || executed || aborted) return;
        if (block.timestamp < deadline) vm.warp(deadline);
        exec.abortRedeem(id);
    }
}
