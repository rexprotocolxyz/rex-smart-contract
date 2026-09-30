// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {REXRegistry} from "../src/REXRegistry.sol";
import {
    IREXRegistry,
    FundAlreadyRegistered,
    FundNotRegistered,
    NotAContract,
    IndexOutOfBounds,
    InvalidStatus,
    NotInChain
} from "@rex-shared/IREXRegistry.sol";
import {InvalidState, UnenrolledRemote, RenounceDisabled} from "@rex-shared/Errors.sol";
import {MockREXPrimaryInfo} from "./mocks/MockREXPrimaryInfo.sol";

contract REXRegistryTest is Test {
    uint32 constant PRUV_DOMAIN = 7336;

    REXRegistry internal registry;
    address internal owner = address(this);
    address internal stranger = address(0xBEEF);
    address internal rwaToken = address(0xA11CE);
    address internal issuer = address(0x1554E4);
    address internal executor = address(0xE7EC);
    address internal wrwaRoute = address(0x0FF0);
    address internal navOracle = address(0x0FACE);

    MockREXPrimaryInfo internal primary;

    function setUp() public {
        registry = new REXRegistry();
        primary = new MockREXPrimaryInfo(wrwaRoute, PRUV_DOMAIN, navOracle, "1.0.1");
        primary.setRemoteRouter(PRUV_DOMAIN, bytes32(uint256(uint160(executor))));
    }

    function _key(address token) internal pure returns (bytes32) {
        return bytes32(uint256(uint160(token)));
    }

    function test_register_storesKeyIssuerAndActiveStatus() public {
        registry.register(address(primary), rwaToken, issuer);

        (bytes32 key, address gotIssuer, IREXRegistry.FundStatus status) = registry.fund(address(primary));
        assertEq(key, _key(rwaToken));
        assertEq(gotIssuer, issuer);
        assertEq(uint256(status), uint256(IREXRegistry.FundStatus.Active));
        assertTrue(registry.isRegistered(address(primary)));
    }

    function test_register_emitsFundRegistered() public {
        vm.expectEmit(true, true, false, false, address(registry));
        emit IREXRegistry.FundRegistered(_key(rwaToken), address(primary));
        registry.register(address(primary), rwaToken, issuer);
    }

    function test_register_revertsForNonOwner() public {
        vm.prank(stranger);
        vm.expectRevert();
        registry.register(address(primary), rwaToken, issuer);
    }

    function test_register_revertsOnZeroRexPrimary() public {
        vm.expectRevert(InvalidState.selector);
        registry.register(address(0), rwaToken, issuer);
    }

    function test_register_revertsOnZeroRwaToken() public {
        vm.expectRevert(InvalidState.selector);
        registry.register(address(primary), address(0), issuer);
    }

    function test_register_revertsOnEoa() public {
        address eoa = address(0xE0A);
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, eoa));
        registry.register(eoa, rwaToken, issuer);
    }

    function test_register_revertsWhenRemoteNotEnrolled() public {
        MockREXPrimaryInfo unenrolled = new MockREXPrimaryInfo(wrwaRoute, PRUV_DOMAIN, navOracle, "1.0.1");
        vm.expectRevert(UnenrolledRemote.selector);
        registry.register(address(unenrolled), rwaToken, issuer);
    }

    function test_register_revertsWhenWrwaRouteZero() public {
        MockREXPrimaryInfo noRoute = new MockREXPrimaryInfo(address(0), PRUV_DOMAIN, navOracle, "1.0.1");
        noRoute.setRemoteRouter(PRUV_DOMAIN, bytes32(uint256(uint160(executor))));
        vm.expectRevert(InvalidState.selector);
        registry.register(address(noRoute), rwaToken, issuer);
    }

    function test_register_revertsOnDuplicate() public {
        registry.register(address(primary), rwaToken, issuer);
        vm.expectRevert(abi.encodeWithSelector(FundAlreadyRegistered.selector, address(primary)));
        registry.register(address(primary), rwaToken, issuer);
    }

    function test_renounceOwnership_reverts() public {
        vm.expectRevert(RenounceDisabled.selector);
        registry.renounceOwnership();
    }

    function _newPrimary() internal returns (MockREXPrimaryInfo p) {
        p = new MockREXPrimaryInfo(wrwaRoute, PRUV_DOMAIN, navOracle, "1.0.1");
        p.setRemoteRouter(PRUV_DOMAIN, bytes32(uint256(uint160(executor))));
    }

    function test_versionChain_threeVersionsInDeployOrder() public {
        MockREXPrimaryInfo v1 = _newPrimary();
        MockREXPrimaryInfo v2 = _newPrimary();
        MockREXPrimaryInfo v3 = _newPrimary();

        registry.register(address(v1), rwaToken, issuer);
        registry.register(address(v2), rwaToken, issuer);
        registry.register(address(v3), rwaToken, issuer);

        address[] memory chain = registry.versionsOf(_key(rwaToken));
        assertEq(chain.length, 3);
        assertEq(chain[0], address(v1));
        assertEq(chain[1], address(v2));
        assertEq(chain[2], address(v3));
        assertEq(registry.latestOf(_key(rwaToken)), address(v3));

        // Three versions of ONE fund is still one key.
        assertEq(registry.fundCount(), 1);
        assertEq(registry.keyAt(0), _key(rwaToken));
    }

    function test_twoFunds_haveIndependentChains() public {
        address otherToken = address(0xB0B);
        MockREXPrimaryInfo a = _newPrimary();
        MockREXPrimaryInfo b = _newPrimary();

        registry.register(address(a), rwaToken, issuer);
        registry.register(address(b), otherToken, issuer);

        assertEq(registry.fundCount(), 2);
        assertEq(registry.versionsOf(_key(rwaToken)).length, 1);
        assertEq(registry.versionsOf(_key(otherToken)).length, 1);
        assertEq(registry.latestOf(_key(rwaToken)), address(a));
        assertEq(registry.latestOf(_key(otherToken)), address(b));

        bytes32[] memory keys = registry.allKeys();
        assertEq(keys.length, 2);
        assertEq(keys[0], _key(rwaToken));
        assertEq(keys[1], _key(otherToken));
    }

    function test_latestOf_unknownKeyIsZero() public view {
        assertEq(registry.latestOf(_key(address(0xDEAD))), address(0));
        assertEq(registry.versionsOf(_key(address(0xDEAD))).length, 0);
    }

    function test_fundInfo_returnsStoredPlusLiveFields() public {
        registry.register(address(primary), rwaToken, issuer);

        (
            bytes32 key,
            address gotIssuer,
            IREXRegistry.FundStatus status,
            address gotExecutor,
            address gotWrwaRoute,
            address gotNavOracle,
            string memory version
        ) = registry.fundInfo(address(primary));

        assertEq(key, _key(rwaToken));
        assertEq(gotIssuer, issuer);
        assertEq(uint256(status), uint256(IREXRegistry.FundStatus.Active));
        assertEq(gotExecutor, executor);
        assertEq(gotWrwaRoute, wrwaRoute);
        assertEq(gotNavOracle, navOracle);
        assertEq(version, "1.0.1");
    }

    /// The ADR-021 decision-4 regression test: `remoteRouter` is mutable via `enrollRemote`, so a
    /// snapshot taken at registration would go stale. Re-enrolling AFTER registration must change
    /// what fundInfo reports.
    function test_fundInfo_reflectsReEnrollAfterRegistration() public {
        registry.register(address(primary), rwaToken, issuer);

        address newExecutor = address(0xE7ED);
        primary.setRemoteRouter(PRUV_DOMAIN, bytes32(uint256(uint160(newExecutor))));

        (,,, address gotExecutor,,,) = registry.fundInfo(address(primary));
        assertEq(gotExecutor, newExecutor);
    }

    function test_fundInfo_revertsForUnregistered() public {
        vm.expectRevert(abi.encodeWithSelector(FundNotRegistered.selector, address(0xC0FFEE)));
        registry.fundInfo(address(0xC0FFEE));
    }

    function test_setStatus_movesBetweenAllListedStates() public {
        registry.register(address(primary), rwaToken, issuer);

        registry.setStatus(address(primary), IREXRegistry.FundStatus.Retired);
        assertEq(uint256(registry.statusOf(address(primary))), uint256(IREXRegistry.FundStatus.Retired));

        registry.setStatus(address(primary), IREXRegistry.FundStatus.Pending);
        assertEq(uint256(registry.statusOf(address(primary))), uint256(IREXRegistry.FundStatus.Pending));

        registry.setStatus(address(primary), IREXRegistry.FundStatus.Active);
        assertEq(uint256(registry.statusOf(address(primary))), uint256(IREXRegistry.FundStatus.Active));
    }

    function test_setStatus_rejectsNone() public {
        registry.register(address(primary), rwaToken, issuer);
        vm.expectRevert(InvalidStatus.selector);
        registry.setStatus(address(primary), IREXRegistry.FundStatus.None);
    }

    function test_setStatus_revertsForUnregistered() public {
        vm.expectRevert(abi.encodeWithSelector(FundNotRegistered.selector, address(primary)));
        registry.setStatus(address(primary), IREXRegistry.FundStatus.Retired);
    }

    function test_setIssuer_updatesAndEmits() public {
        registry.register(address(primary), rwaToken, issuer);
        address newIssuer = address(0x15502);

        vm.expectEmit(true, false, false, true, address(registry));
        emit IREXRegistry.FundIssuerChanged(address(primary), newIssuer);
        registry.setIssuer(address(primary), newIssuer);

        (, address gotIssuer,) = registry.fund(address(primary));
        assertEq(gotIssuer, newIssuer);
    }

    function test_unregister_middleVersionPreservesOrder() public {
        MockREXPrimaryInfo v1 = _newPrimary();
        MockREXPrimaryInfo v2 = _newPrimary();
        MockREXPrimaryInfo v3 = _newPrimary();
        registry.register(address(v1), rwaToken, issuer);
        registry.register(address(v2), rwaToken, issuer);
        registry.register(address(v3), rwaToken, issuer);

        registry.unregister(address(v2));

        address[] memory chain = registry.versionsOf(_key(rwaToken));
        assertEq(chain.length, 2);
        assertEq(chain[0], address(v1));
        assertEq(chain[1], address(v3));
        assertEq(registry.latestOf(_key(rwaToken)), address(v3));
        assertFalse(registry.isRegistered(address(v2)));
        assertEq(registry.fundCount(), 1);
    }

    function test_unregister_lastVersionRemovesKey() public {
        registry.register(address(primary), rwaToken, issuer);

        vm.expectEmit(true, true, false, false, address(registry));
        emit IREXRegistry.FundUnregistered(_key(rwaToken), address(primary));
        registry.unregister(address(primary));

        assertEq(registry.fundCount(), 0);
        assertEq(registry.allKeys().length, 0);
        assertEq(registry.versionsOf(_key(rwaToken)).length, 0);
        assertFalse(registry.isRegistered(address(primary)));
    }

    function test_unregister_thenRegisterAgainWorks() public {
        registry.register(address(primary), rwaToken, issuer);
        registry.unregister(address(primary));
        registry.register(address(primary), rwaToken, issuer);

        assertTrue(registry.isRegistered(address(primary)));
        assertEq(registry.fundCount(), 1);
        assertEq(registry.versionsOf(_key(rwaToken)).length, 1);
    }

    function test_unregister_revertsForUnregistered() public {
        vm.expectRevert(abi.encodeWithSelector(FundNotRegistered.selector, address(primary)));
        registry.unregister(address(primary));
    }

    // ----------------------------------------------------------------------------------
    // registerBefore -- the exact-position restore path (SC7 review, ADR-021 amendment)
    // ----------------------------------------------------------------------------------

    /// @dev The whole point: restoring a mistakenly-unregistered OLDER version must NOT become
    /// `latestOf`. With plain `register` it would (it always appends at the tail).
    function test_registerBefore_restoresAnOlderVersionWithoutRegressingLatest() public {
        MockREXPrimaryInfo v1 = _newPrimary();
        MockREXPrimaryInfo v2 = _newPrimary();
        registry.register(address(v1), rwaToken, issuer);
        registry.register(address(v2), rwaToken, issuer);
        registry.unregister(address(v1));

        registry.registerBefore(address(v1), rwaToken, issuer, address(v2));

        address[] memory chain = registry.versionsOf(_key(rwaToken));
        assertEq(chain.length, 2);
        assertEq(chain[0], address(v1), "v1 back in front");
        assertEq(chain[1], address(v2), "v2 still the tail");
        assertEq(registry.latestOf(_key(rwaToken)), address(v2), "latest did NOT regress");
    }

    /// @dev Inserting into the middle of a longer chain keeps every other position.
    function test_registerBefore_insertsIntoTheMiddle() public {
        MockREXPrimaryInfo v1 = _newPrimary();
        MockREXPrimaryInfo v2 = _newPrimary();
        MockREXPrimaryInfo v3 = _newPrimary();
        registry.register(address(v1), rwaToken, issuer);
        registry.register(address(v2), rwaToken, issuer);
        registry.register(address(v3), rwaToken, issuer);
        registry.unregister(address(v2));

        registry.registerBefore(address(v2), rwaToken, issuer, address(v3));

        address[] memory chain = registry.versionsOf(_key(rwaToken));
        assertEq(chain.length, 3);
        assertEq(chain[0], address(v1));
        assertEq(chain[1], address(v2));
        assertEq(chain[2], address(v3));
    }

    function test_registerBefore_emitsFundRegistered() public {
        MockREXPrimaryInfo v2 = _newPrimary();
        registry.register(address(v2), rwaToken, issuer);

        vm.expectEmit(true, true, false, false);
        emit IREXRegistry.FundRegistered(_key(rwaToken), address(primary));
        registry.registerBefore(address(primary), rwaToken, issuer, address(v2));
    }

    /// @dev The successor must be in THIS key's chain -- otherwise there is no position to take,
    /// and silently appending would be the very regression this function exists to prevent.
    function test_registerBefore_revertsWhenSuccessorIsInAnotherChain() public {
        MockREXPrimaryInfo other = _newPrimary();
        registry.register(address(other), address(0xB0B), issuer);

        vm.expectRevert(abi.encodeWithSelector(NotInChain.selector, address(other), _key(rwaToken)));
        registry.registerBefore(address(primary), rwaToken, issuer, address(other));
    }

    function test_registerBefore_revertsForUnknownSuccessor() public {
        vm.expectRevert(abi.encodeWithSelector(NotInChain.selector, address(0xDEAD), _key(rwaToken)));
        registry.registerBefore(address(primary), rwaToken, issuer, address(0xDEAD));
    }

    /// @dev Same guards as `register`: already-registered, zero addresses, non-contract, and the
    /// two on-chain validations off the anchor.
    function test_registerBefore_revertsOnDuplicate() public {
        MockREXPrimaryInfo v2 = _newPrimary();
        registry.register(address(v2), rwaToken, issuer);
        registry.register(address(primary), rwaToken, issuer);

        vm.expectRevert(abi.encodeWithSelector(FundAlreadyRegistered.selector, address(primary)));
        registry.registerBefore(address(primary), rwaToken, issuer, address(v2));
    }

    function test_registerBefore_revertsWhenRemoteNotEnrolled() public {
        MockREXPrimaryInfo v2 = _newPrimary();
        registry.register(address(v2), rwaToken, issuer);
        MockREXPrimaryInfo unenrolled = new MockREXPrimaryInfo(wrwaRoute, PRUV_DOMAIN, navOracle, "1.0.1");

        vm.expectRevert(UnenrolledRemote.selector);
        registry.registerBefore(address(unenrolled), rwaToken, issuer, address(v2));
    }

    function test_registerBefore_revertsForNonOwner() public {
        MockREXPrimaryInfo v2 = _newPrimary();
        registry.register(address(v2), rwaToken, issuer);

        vm.prank(stranger);
        vm.expectRevert();
        registry.registerBefore(address(primary), rwaToken, issuer, address(v2));
    }

    // ----------------------------------------------------------------------------------
    // Guards + accessors this review found untested (SC7 review)
    // ----------------------------------------------------------------------------------

    /// @dev `register` rejects a zero rexPrimary and a zero rwaToken; accepting a zero issuer was
    /// the inconsistent third case -- a forgotten field would silently mean "unattested".
    function test_register_revertsOnZeroIssuer() public {
        vm.expectRevert(InvalidState.selector);
        registry.register(address(primary), rwaToken, address(0));
    }

    function test_setIssuer_revertsOnZeroIssuer() public {
        registry.register(address(primary), rwaToken, issuer);

        vm.expectRevert(InvalidState.selector);
        registry.setIssuer(address(primary), address(0));
    }

    /// @dev A named error, not a bare array panic -- a direct-RPC client (spec section 17.4's
    /// fallback) paginating with `keyAt` gets something it can decode.
    function test_keyAt_revertsOutOfBoundsWithNamedError() public {
        vm.expectRevert(abi.encodeWithSelector(IndexOutOfBounds.selector, uint256(0), uint256(0)));
        registry.keyAt(0);

        registry.register(address(primary), rwaToken, issuer);
        vm.expectRevert(abi.encodeWithSelector(IndexOutOfBounds.selector, uint256(1), uint256(1)));
        registry.keyAt(1);
    }

    /// @dev The convenience twin of `latestOf`, taking the token itself so a client never has to
    /// reproduce the bytes32 key packing by hand.
    function test_latestOfToken_matchesLatestOf() public {
        registry.register(address(primary), rwaToken, issuer);

        assertEq(registry.latestOfToken(rwaToken), address(primary));
        assertEq(registry.latestOfToken(rwaToken), registry.latestOf(_key(rwaToken)));
        assertEq(registry.latestOfToken(address(0xB0B)), address(0), "unknown token is zero");
    }

    /// @dev Deliberate asymmetry, pinned: `fund()` reads back all-zero for an unregistered address
    /// (cheap existence probe, matching `statusOf`/`isRegistered`) while `fundInfo()` reverts.
    function test_fund_onUnregisteredReturnsZeros() public view {
        (bytes32 key, address gotIssuer, IREXRegistry.FundStatus status) = registry.fund(address(0xDEAD));
        assertEq(key, bytes32(0));
        assertEq(gotIssuer, address(0));
        assertEq(uint256(status), uint256(IREXRegistry.FundStatus.None));
        assertFalse(registry.isRegistered(address(0xDEAD)));
    }

    /// @dev Pins the enumeration hazard `keyAt`'s NatSpec warns about: removing a key SWAPS the
    /// last one into its slot, so indices are not stable across transactions and a client that
    /// paginates `keyAt` across separate calls can miss a fund. `allKeys()` is the atomic read.
    function test_unregister_swapsTheLastKeyIntoTheRemovedSlot() public {
        MockREXPrimaryInfo a = _newPrimary();
        MockREXPrimaryInfo b = _newPrimary();
        MockREXPrimaryInfo c = _newPrimary();
        registry.register(address(a), address(0xA1), issuer);
        registry.register(address(b), address(0xA2), issuer);
        registry.register(address(c), address(0xA3), issuer);

        registry.unregister(address(a));

        assertEq(registry.fundCount(), 2);
        assertEq(registry.keyAt(0), _key(address(0xA3)), "last key swapped into slot 0");
        assertEq(registry.keyAt(1), _key(address(0xA2)));
    }

    function test_mutations_revertForNonOwner() public {
        registry.register(address(primary), rwaToken, issuer);
        vm.startPrank(stranger);
        vm.expectRevert();
        registry.setStatus(address(primary), IREXRegistry.FundStatus.Retired);
        vm.expectRevert();
        registry.setIssuer(address(primary), stranger);
        vm.expectRevert();
        registry.unregister(address(primary));
        vm.stopPrank();
    }
}
