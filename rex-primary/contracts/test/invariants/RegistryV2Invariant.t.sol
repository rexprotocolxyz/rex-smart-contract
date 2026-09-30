// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {REXRegistryV2} from "../../src/REXRegistryV2.sol";
import {IREXRegistryV2} from "@rex-shared/IREXRegistryV2.sol";
import {MockREXPrimaryEmptiness} from "../mocks/MockREXPrimaryEmptiness.sol";

/// @notice Drives REXRegistryV2 through random register/unregister/setStatus/setIssuer sequences
/// from a fixed pool of REXPrimary stand-ins, some of which are never empty.
contract RegistryV2Handler is Test {
    REXRegistryV2 public registry;
    MockREXPrimaryEmptiness[] public pool;
    uint256 public mutations;

    /// @dev Every address a `register` call put into the directory while its mock read non-empty,
    /// deduplicated. This is the independent record `invariant_a_non_empty_fund_is_never_unregistered`
    /// checks against -- built from what the mock actually reported at register time, not from the
    /// pool's construction order, so it survives someone later changing how the pool is built.
    address[] internal _everNonEmpty;
    mapping(address => bool) internal _seenNonEmpty;

    constructor(REXRegistryV2 registry_) {
        registry = registry_;
        for (uint256 i = 0; i < 8; ++i) {
            MockREXPrimaryEmptiness m = new MockREXPrimaryEmptiness(address(0x0FF0), 7336);
            m.setRemoteRouter(7336, bytes32(uint256(uint160(address(0xE7EC)))));
            // Half the pool is permanently non-empty, so unregister is genuinely refused sometimes.
            if (i % 2 == 0) m.makeEmpty();
            else m.setHeldEscrowUSDC(1);
            pool.push(m);
        }
    }

    function _pick(uint256 seed) internal view returns (MockREXPrimaryEmptiness) {
        return pool[seed % pool.length];
    }

    /// @dev Mirrors REXRegistryV2._isEmpty exactly, reading the mock's own getters rather than
    /// assuming which pool slots are empty.
    function _isEmpty(MockREXPrimaryEmptiness m) internal view returns (bool) {
        return m.state() == 4 && m.heldEscrowUSDC() == 0 && m.settledRedeemUSDC() == 0 && m.liveRedeemEscrow() == 0
            && m.settledUnclaimed() == 0 && m.outstandingSubBatches() == 0 && m.outstandingRedeemBatches() == 0;
    }

    function _recordIfNonEmpty(MockREXPrimaryEmptiness m) internal {
        if (_isEmpty(m)) return;
        address a = address(m);
        if (_seenNonEmpty[a]) return;
        _seenNonEmpty[a] = true;
        _everNonEmpty.push(a);
    }

    function register(uint256 seed, address rwaToken) external {
        if (rwaToken == address(0)) rwaToken = address(0xA11CE);
        MockREXPrimaryEmptiness m = _pick(seed);
        try registry.register(address(m), rwaToken, address(0x1554E4)) {
            ++mutations;
            _recordIfNonEmpty(m);
        } catch {}
    }

    function unregister(uint256 seed) external {
        try registry.unregister(address(_pick(seed))) {
            ++mutations;
        } catch {}
    }

    function setStatus(uint256 seed, uint8 status) external {
        uint8 s = uint8(bound(status, 1, 3));
        try registry.setStatus(address(_pick(seed)), IREXRegistryV2.FundStatus(s)) {
            ++mutations;
        } catch {}
    }

    function setIssuer(uint256 seed, address issuer) external {
        if (issuer == address(0)) issuer = address(0x1554E4);
        try registry.setIssuer(address(_pick(seed)), issuer) {
            ++mutations;
        } catch {}
    }

    function poolLength() external view returns (uint256) {
        return pool.length;
    }

    /// @notice Every address ever registered while its mock read non-empty, deduplicated.
    function everRegisteredNonEmpty() external view returns (address[] memory) {
        return _everNonEmpty;
    }
}

contract RegistryV2InvariantTest is Test {
    REXRegistryV2 internal registry;
    RegistryV2Handler internal handler;

    function setUp() public {
        registry = new REXRegistryV2();
        handler = new RegistryV2Handler(registry);
        registry.transferOwnership(address(handler));
        vm.prank(address(handler));
        registry.acceptOwnership();

        bytes4[] memory selectors = new bytes4[](4);
        selectors[0] = RegistryV2Handler.register.selector;
        selectors[1] = RegistryV2Handler.unregister.selector;
        selectors[2] = RegistryV2Handler.setStatus.selector;
        selectors[3] = RegistryV2Handler.setIssuer.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
        targetContract(address(handler));
    }

    /// Every listed row resolves to itself, and `fundCount` agrees with `allFunds`.
    function invariant_index_and_array_agree() public view {
        IREXRegistryV2.Fund[] memory all = registry.allFunds();
        assertEq(all.length, registry.fundCount());
        for (uint256 i = 0; i < all.length; ++i) {
            assertEq(registry.fund(all[i].rexPrimary).rexPrimary, all[i].rexPrimary);
            assertEq(registry.fundAt(i).rexPrimary, all[i].rexPrimary);
            assertTrue(all[i].status != IREXRegistryV2.FundStatus.None);
        }
    }

    /// No address appears twice.
    function invariant_no_duplicate_rows() public view {
        IREXRegistryV2.Fund[] memory all = registry.allFunds();
        for (uint256 i = 0; i < all.length; ++i) {
            for (uint256 j = i + 1; j < all.length; ++j) {
                assertTrue(all[i].rexPrimary != all[j].rexPrimary);
            }
        }
    }

    /// `revision` counts mutations exactly -- a poller that gates on it can never miss one.
    function invariant_revision_equals_mutation_count() public view {
        assertEq(registry.revision(), handler.mutations());
    }

    /// A non-empty fund is never unregistered: every address the handler ever registered while its
    /// mock read non-empty (per an independent record built from the mock's own getters, not from
    /// pool construction order) must still be listed. This is the sole coverage of the emptiness
    /// predicate that guards `unregister` -- the property has to be checked against fund addresses
    /// that were ACTUALLY registered non-empty, not merely bounded by pool size, or it proves
    /// nothing.
    function invariant_a_non_empty_fund_is_never_unregistered() public view {
        address[] memory addrs = handler.everRegisteredNonEmpty();
        for (uint256 i = 0; i < addrs.length; ++i) {
            assertTrue(
                registry.statusOf(addrs[i]) != IREXRegistryV2.FundStatus.None,
                "non-empty fund vanished from the directory"
            );
        }
    }
}
