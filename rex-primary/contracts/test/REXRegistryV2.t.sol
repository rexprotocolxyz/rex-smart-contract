// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {REXRegistryV2} from "../src/REXRegistryV2.sol";
import {IREXRegistryV2} from "@rex-shared/IREXRegistryV2.sol";
import {
    FundAlreadyRegistered,
    FundNotRegistered,
    NotAContract,
    IndexOutOfBounds,
    InvalidStatus
} from "@rex-shared/IREXRegistry.sol";
import {InvalidState, UnenrolledRemote, RenounceDisabled} from "@rex-shared/Errors.sol";
import {FundNotEmpty} from "@rex-shared/IREXRegistryV2.sol";
import {MockREXPrimaryInfo} from "./mocks/MockREXPrimaryInfo.sol";
import {MockREXPrimaryEmptiness} from "./mocks/MockREXPrimaryEmptiness.sol";

contract REXRegistryV2Test is Test {
    uint32 constant PRUV_DOMAIN = 7336;

    REXRegistryV2 internal registry;
    address internal stranger = address(0xBEEF);
    address internal rwaToken = address(0xA11CE);
    address internal issuer = address(0x1554E4);
    address internal executor = address(0xE7EC);

    MockREXPrimaryInfo internal primary;
    MockREXPrimaryInfo internal sibling;

    function setUp() public {
        registry = new REXRegistryV2();
        primary = new MockREXPrimaryInfo(address(0x0FF0), PRUV_DOMAIN, address(0x0FACE), "1.4.0");
        primary.setRemoteRouter(PRUV_DOMAIN, bytes32(uint256(uint160(executor))));
        sibling = new MockREXPrimaryInfo(address(0x0FF0), PRUV_DOMAIN, address(0x0FACE), "1.4.0");
        sibling.setRemoteRouter(PRUV_DOMAIN, bytes32(uint256(uint160(executor))));
    }

    function test_register_stores_the_row_and_bumps_revision() public {
        assertEq(registry.revision(), 0);
        registry.register(address(primary), rwaToken, issuer);

        IREXRegistryV2.Fund memory f = registry.fund(address(primary));
        assertEq(f.rexPrimary, address(primary));
        assertEq(f.rwaToken, rwaToken);
        assertEq(f.issuer, issuer);
        assertEq(uint8(f.status), uint8(IREXRegistryV2.FundStatus.Active));
        assertEq(registry.fundCount(), 1);
        assertEq(registry.revision(), 1);
    }

    function test_register_emits_FundRegistered() public {
        vm.expectEmit(true, true, false, true, address(registry));
        emit IREXRegistryV2.FundRegistered(address(primary), rwaToken, issuer);
        registry.register(address(primary), rwaToken, issuer);
    }

    /// The whole point of v2: two live funds on ONE rwaToken, neither displacing the other.
    function test_two_funds_may_share_one_rwa_token() public {
        registry.register(address(primary), rwaToken, issuer);
        registry.register(address(sibling), rwaToken, issuer);

        assertEq(registry.fundCount(), 2);
        IREXRegistryV2.Fund[] memory all = registry.allFunds();
        assertEq(all.length, 2);
        assertEq(all[0].rexPrimary, address(primary));
        assertEq(all[1].rexPrimary, address(sibling));
        // Both resolvable by their OWN address — no notion of one superseding the other.
        assertEq(registry.fund(address(primary)).rexPrimary, address(primary));
        assertEq(registry.fund(address(sibling)).rexPrimary, address(sibling));
    }

    function test_unregistered_address_reads_back_empty_and_never_reverts() public view {
        IREXRegistryV2.Fund memory f = registry.fund(address(0xDEAD));
        assertEq(f.rexPrimary, address(0));
        assertEq(uint8(f.status), uint8(IREXRegistryV2.FundStatus.None));
        assertEq(uint8(registry.statusOf(address(0xDEAD))), uint8(IREXRegistryV2.FundStatus.None));
    }

    function test_register_rejects_a_duplicate() public {
        registry.register(address(primary), rwaToken, issuer);
        vm.expectRevert(abi.encodeWithSelector(FundAlreadyRegistered.selector, address(primary)));
        registry.register(address(primary), rwaToken, issuer);
    }

    function test_register_rejects_zero_arguments() public {
        vm.expectRevert(InvalidState.selector);
        registry.register(address(0), rwaToken, issuer);
        vm.expectRevert(InvalidState.selector);
        registry.register(address(primary), address(0), issuer);
        vm.expectRevert(InvalidState.selector);
        registry.register(address(primary), rwaToken, address(0));
    }

    function test_register_rejects_an_eoa() public {
        vm.expectRevert(abi.encodeWithSelector(NotAContract.selector, stranger));
        registry.register(stranger, rwaToken, issuer);
    }

    /// A contract with code but no REXPrimary getters and no fallback: the call reverts with
    /// EMPTY returndata -- no selector, no decodable error, not even a Panic. `vm.expectRevert()`
    /// stays bare because there is nothing to pin it to.
    function test_register_rejects_a_contract_that_is_not_a_rex_primary() public {
        address notAPrimary = address(new NotAPrimary());
        vm.expectRevert();
        registry.register(notAPrimary, rwaToken, issuer);
    }

    function test_register_rejects_an_unenrolled_remote() public {
        MockREXPrimaryInfo bare = new MockREXPrimaryInfo(address(0x0FF0), PRUV_DOMAIN, address(0x0FACE), "1.4.0");
        vm.expectRevert(UnenrolledRemote.selector);
        registry.register(address(bare), rwaToken, issuer);
    }

    function test_register_rejects_a_zero_wrwa_route() public {
        MockREXPrimaryInfo noRoute = new MockREXPrimaryInfo(address(0), PRUV_DOMAIN, address(0x0FACE), "1.4.0");
        noRoute.setRemoteRouter(PRUV_DOMAIN, bytes32(uint256(uint160(executor))));
        vm.expectRevert(InvalidState.selector);
        registry.register(address(noRoute), rwaToken, issuer);
    }

    function test_register_is_owner_only() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.register(address(primary), rwaToken, issuer);
    }

    function test_fundAt_reverts_past_the_end() public {
        registry.register(address(primary), rwaToken, issuer);
        assertEq(registry.fundAt(0).rexPrimary, address(primary));
        vm.expectRevert(abi.encodeWithSelector(IndexOutOfBounds.selector, uint256(1), uint256(1)));
        registry.fundAt(1);
    }

    function test_renounce_is_disabled() public {
        vm.expectRevert(RenounceDisabled.selector);
        registry.renounceOwnership();
    }

    function test_setStatus_changes_the_row_and_emits() public {
        registry.register(address(primary), rwaToken, issuer);
        vm.expectEmit(true, false, false, true, address(registry));
        emit IREXRegistryV2.FundStatusChanged(address(primary), uint8(IREXRegistryV2.FundStatus.Retired));
        registry.setStatus(address(primary), IREXRegistryV2.FundStatus.Retired);
        assertEq(uint8(registry.statusOf(address(primary))), uint8(IREXRegistryV2.FundStatus.Retired));
    }

    /// A poller gates on `revision`. Storing the value that is already there is still a call the
    /// poller must not miss, so it bumps.
    function test_setStatus_bumps_revision_even_when_nothing_changes() public {
        registry.register(address(primary), rwaToken, issuer);
        uint256 before = registry.revision();
        registry.setStatus(address(primary), IREXRegistryV2.FundStatus.Active); // already Active
        assertEq(registry.revision(), before + 1);
    }

    function test_setStatus_rejects_None() public {
        registry.register(address(primary), rwaToken, issuer);
        vm.expectRevert(InvalidStatus.selector);
        registry.setStatus(address(primary), IREXRegistryV2.FundStatus.None);
    }

    function test_setStatus_rejects_an_unregistered_fund() public {
        vm.expectRevert(abi.encodeWithSelector(FundNotRegistered.selector, address(primary)));
        registry.setStatus(address(primary), IREXRegistryV2.FundStatus.Retired);
    }

    function test_setStatus_is_owner_only() public {
        registry.register(address(primary), rwaToken, issuer);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.setStatus(address(primary), IREXRegistryV2.FundStatus.Retired);
    }

    function test_setIssuer_changes_the_row_bumps_revision_and_emits() public {
        registry.register(address(primary), rwaToken, issuer);
        address corrected = address(0xC0FFEE);
        uint256 before = registry.revision();
        vm.expectEmit(true, false, false, true, address(registry));
        emit IREXRegistryV2.FundIssuerChanged(address(primary), corrected);
        registry.setIssuer(address(primary), corrected);
        assertEq(registry.fund(address(primary)).issuer, corrected);
        assertEq(registry.revision(), before + 1);
    }

    function test_setIssuer_rejects_zero() public {
        registry.register(address(primary), rwaToken, issuer);
        vm.expectRevert(InvalidState.selector);
        registry.setIssuer(address(primary), address(0));
    }

    function test_setIssuer_rejects_an_unregistered_fund() public {
        vm.expectRevert(abi.encodeWithSelector(FundNotRegistered.selector, address(primary)));
        registry.setIssuer(address(primary), address(0xC0FFEE));
    }

    function _emptyPrimary() internal returns (MockREXPrimaryEmptiness m) {
        m = new MockREXPrimaryEmptiness(address(0x0FF0), PRUV_DOMAIN);
        m.setRemoteRouter(PRUV_DOMAIN, bytes32(uint256(uint160(executor))));
        m.makeEmpty();
    }

    function test_unregister_removes_an_empty_shutdown_fund() public {
        MockREXPrimaryEmptiness m = _emptyPrimary();
        registry.register(address(m), rwaToken, issuer);
        uint256 before = registry.revision();

        vm.expectEmit(true, false, false, false, address(registry));
        emit IREXRegistryV2.FundUnregistered(address(m));
        registry.unregister(address(m));

        assertEq(registry.fundCount(), 0);
        assertEq(uint8(registry.statusOf(address(m))), uint8(IREXRegistryV2.FundStatus.None));
        assertEq(registry.revision(), before + 1);
    }

    /// WindDown keeps the redeem book open (REXPrimary.sol:867), so zero balances are not enough.
    function test_unregister_refuses_a_wound_down_but_empty_fund() public {
        MockREXPrimaryEmptiness m = _emptyPrimary();
        m.setState(3); // WindDown
        registry.register(address(m), rwaToken, issuer);
        vm.expectRevert(abi.encodeWithSelector(FundNotEmpty.selector, address(m)));
        registry.unregister(address(m));
    }

    /// Each of the six counters alone must block removal.
    function test_unregister_refuses_when_any_single_counter_is_non_zero() public {
        for (uint256 i = 0; i < 6; ++i) {
            MockREXPrimaryEmptiness m = _emptyPrimary();
            if (i == 0) m.setHeldEscrowUSDC(1);
            if (i == 1) m.setSettledRedeemUSDC(1);
            if (i == 2) m.setLiveRedeemEscrow(1);
            if (i == 3) m.setSettledUnclaimed(1);
            if (i == 4) m.setOutstandingSubBatches(1);
            if (i == 5) m.setOutstandingRedeemBatches(1);
            registry.register(address(m), rwaToken, issuer);
            vm.expectRevert(abi.encodeWithSelector(FundNotEmpty.selector, address(m)));
            registry.unregister(address(m));
        }
        assertEq(registry.fundCount(), 6);
    }

    /// `allFunds` is an array with swap-and-pop removal: the moved row's index entry must be
    /// rewritten, or `fund()` returns the wrong row for it.
    function test_unregister_of_a_middle_row_keeps_every_other_row_resolvable() public {
        MockREXPrimaryEmptiness a = _emptyPrimary();
        MockREXPrimaryEmptiness b = _emptyPrimary();
        MockREXPrimaryEmptiness c = _emptyPrimary();
        registry.register(address(a), rwaToken, issuer);
        registry.register(address(b), rwaToken, issuer);
        registry.register(address(c), rwaToken, issuer);

        registry.unregister(address(b));

        assertEq(registry.fundCount(), 2);
        assertEq(registry.fund(address(a)).rexPrimary, address(a));
        assertEq(registry.fund(address(c)).rexPrimary, address(c));
        assertEq(uint8(registry.statusOf(address(b))), uint8(IREXRegistryV2.FundStatus.None));
        // c was swapped into b's slot; fundAt must agree with fund().
        assertEq(registry.fundAt(1).rexPrimary, address(c));
    }

    function test_unregister_of_the_last_row_is_a_plain_pop() public {
        MockREXPrimaryEmptiness a = _emptyPrimary();
        MockREXPrimaryEmptiness b = _emptyPrimary();
        registry.register(address(a), rwaToken, issuer);
        registry.register(address(b), rwaToken, issuer);
        registry.unregister(address(b));
        assertEq(registry.fundCount(), 1);
        assertEq(registry.fundAt(0).rexPrimary, address(a));
    }

    function test_an_unregistered_fund_can_be_registered_again() public {
        MockREXPrimaryEmptiness m = _emptyPrimary();
        registry.register(address(m), rwaToken, issuer);
        registry.unregister(address(m));
        registry.register(address(m), rwaToken, issuer);
        assertEq(uint8(registry.statusOf(address(m))), uint8(IREXRegistryV2.FundStatus.Active));
    }

    function test_unregister_rejects_an_unregistered_fund() public {
        vm.expectRevert(abi.encodeWithSelector(FundNotRegistered.selector, address(primary)));
        registry.unregister(address(primary));
    }

    function test_unregister_is_owner_only() public {
        MockREXPrimaryEmptiness m = _emptyPrimary();
        registry.register(address(m), rwaToken, issuer);
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        registry.unregister(address(m));
    }

    /// A REXPrimary that predates the emptiness getters can never be unregistered. That is the
    /// intended fail-closed ending, asserted rather than discovered: `MockREXPrimaryInfo` has the
    /// three register getters and none of the seven.
    function test_unregister_reverts_for_a_primary_without_the_emptiness_getters() public {
        registry.register(address(primary), rwaToken, issuer);
        vm.expectRevert();
        registry.unregister(address(primary));
        assertEq(registry.fundCount(), 1);
    }
}

/// @dev Has code, but none of the getters `register` reads.
contract NotAPrimary {
    uint256 public x;
}
