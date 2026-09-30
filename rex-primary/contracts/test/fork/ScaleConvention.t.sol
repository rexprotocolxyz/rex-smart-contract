// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";

/// @notice ADR-028 OQ-3, answered on deployed bytecode instead of assumed. D7 assumes Hyperlane's
/// convention is `localAmount * scale` outbound and `messageAmount / scale` inbound. Every route in
/// the estate was a 6/6 pair with `scale() == 1`, where that assumption is untestable -- until
/// Derryl's 2026-09-18 FakeUSDC set, whose BSC leg is 18-decimal (`scale() == 1`) against a
/// 6-decimal Sepolia leg (`scale() == 1e12`).
///
/// This drives the SEPOLIA route's real `handle` with a known wire amount and reads what it pays
/// out. Division and multiplication differ by 1e24 here, so the answer is unambiguous.
contract ScaleConventionTest is Test {
    address constant ROUTE = 0x9495AC4F129B9b1b6561469e56a55f417F84FF2d; // 6-decimal leg, scale 1e12
    address constant USDC = 0x756EfF2C697835bE39ea6D4B897305A207374cBE;
    address constant MAILBOX = 0x8233C1DfCBCe0F85A4F29dc6f4Db767FF6E4a3eA;
    address constant PRUV_PEER = 0x72404d68ABc045349E5553C78D65914aee17D51E;
    uint32 constant PRUV_DOMAIN = 7336;

    function test_inbound_divides_by_scale() public {
        vm.createSelectFork("https://ethereum-sepolia.publicnode.com");
        address who = makeAddr("recipient");
        deal(USDC, ROUTE, 1_000_000_000); // 1000 USDC of collateral to pay from

        (, bytes memory sc) = ROUTE.staticcall(abi.encodeWithSignature("scale()"));
        assertEq(abi.decode(sc, (uint256)), 1e12, "fixture assumption: this leg scales by 1e12");

        // Hyperlane TokenMessage: bytes32 recipient ++ uint256 amount. One whole USDC expressed in
        // the pair's canonical 18-decimal wire units.
        bytes memory message = abi.encodePacked(bytes32(uint256(uint160(who))), uint256(1e18));

        uint256 before = _bal(who);
        vm.prank(MAILBOX);
        (bool ok,) = ROUTE.call(
            abi.encodeWithSignature(
                "handle(uint32,bytes32,bytes)", PRUV_DOMAIN, bytes32(uint256(uint160(PRUV_PEER))), message
            )
        );
        assertTrue(ok, "the deployed route accepted the delivery");
        uint256 paid = _bal(who) - before;

        emit log_named_uint("wire amount", 1e18);
        emit log_named_uint("local paid out", paid);
        // 1e18 / 1e12 = 1e6 = one whole 6-decimal USDC. Multiplication would have needed 1e30.
        assertEq(paid, 1e6, "inbound DIVIDES by scale -- ADR-028 D7's assumed convention is correct");
    }

    function _bal(address who) internal view returns (uint256) {
        (, bytes memory r) = USDC.staticcall(abi.encodeWithSignature("balanceOf(address)", who));
        return abi.decode(r, (uint256));
    }
}
