// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;
import "forge-std/Test.sol";
import "./MockERC20.sol";
import "@rex-shared-mocks/MockRWAToken.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import "@rex-shared-mocks/MockCollateralWarpRoute.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract MocksTest is Test {
    function test_rwatoken_deposit_mints_shares_pulls_asset() public {
        MockERC20 usdc = new MockERC20("USDC", 6);
        MockRWAToken vault = new MockRWAToken(address(usdc));
        usdc.mint(address(this), 100e6);
        usdc.approve(address(vault), 100e6);
        uint256 shares = vault.deposit(100e6, address(this));
        assertEq(shares, 100e6);
        assertEq(usdc.balanceOf(address(vault)), 100e6);
        assertEq(vault.balanceOf(address(this)), 100e6);
    }

    function test_mailbox_records_on_dispatch_delivers_on_process() public {
        vm.deal(address(this), 1 ether);
        MockMailbox home = new MockMailbox(1); // home domain
        Recorder r = new Recorder();
        uint256 fee = home.quoteDispatch(7336, bytes32(uint256(uint160(address(r)))), hex"abcd");
        assertGt(fee, 0); // honest fee model: non-zero by default
        bytes32 id = home.dispatch{value: fee}(7336, bytes32(uint256(uint160(address(r)))), hex"abcd");
        assertFalse(home.delivered(id)); // dispatch only records — not delivered yet
        assertEq(r.lastBody(), hex""); // recipient NOT called on dispatch
        home.process(id); // relayer delivers in a separate call (no nesting)
        assertTrue(home.delivered(id));
        assertEq(r.lastBody(), hex"abcd");
        assertEq(r.lastOrigin(), uint32(1)); // origin = dispatching mailbox domain
        assertEq(r.lastSender(), bytes32(uint256(uint160(address(this))))); // sender = the dispatcher
    }

    function test_collateral_route_deliverTokens_unlocks() public {
        MockERC20 tok = new MockERC20("USDC", 6);
        MockCollateralWarpRoute route = new MockCollateralWarpRoute(IERC20(address(tok)));
        route.setGasQuote(0);
        tok.mint(address(this), 100e6);
        tok.approve(address(route), 100e6);
        route.transferRemote{value: 0}(1, bytes32(uint256(1)), 100e6); // lock 100e6 here
        assertEq(tok.balanceOf(address(route)), 100e6);

        address recip = makeAddr("recip");
        route.deliverTokens(bytes32(uint256(uint160(recip))), 40e6); // unlock 40e6
        assertEq(tok.balanceOf(recip), 40e6, "unlocked to recipient");
        assertEq(tok.balanceOf(address(route)), 60e6, "remainder stays locked");
    }
}

contract Recorder {
    bytes public lastBody;
    uint32 public lastOrigin;
    bytes32 public lastSender;

    function handle(uint32 o, bytes32 s, bytes calldata b) external {
        lastOrigin = o;
        lastSender = s;
        lastBody = b;
    }
}
