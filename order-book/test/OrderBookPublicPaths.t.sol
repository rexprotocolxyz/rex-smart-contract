// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {IBaseOrderBook} from "../contracts/interfaces/IBaseOrderBook.sol";
import {IOrderBookAdministration} from "../contracts/interfaces/IOrderBookAdministration.sol";
import {OrderBookWithFeeController} from "../contracts/OrderBookWithFeeController.sol";
import {Side} from "../contracts/interfaces/Side.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOrderBookFeeController} from "./mocks/MockOrderBookFeeController.sol";

interface VmPublicPaths {
    function prank(address msgSender) external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
}

contract OrderBookPublicPathsTest {
    VmPublicPaths private constant vm = VmPublicPaths(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant MAKER = address(0xA11CE);
    address private constant GUARDIAN = address(0x600D);
    address private constant SECOND_GUARDIAN = address(0x600D2);
    address private constant NEW_OWNER = address(0x0B0B);
    address private constant UNAUTHORIZED = address(0xBAD);

    MockERC20 private base;
    MockERC20 private quote;
    OrderBookWithFeeController private orderBook;

    function setUp() public {
        base = new MockERC20();
        quote = new MockERC20();
        orderBook = new OrderBookWithFeeController(
            address(base), address(quote), address(this), new MockOrderBookFeeController(1 days), 100, 100
        );
        base.mint(MAKER, 1_000e6);
    }

    function testPaginatesOrdersFromDefaultAndExplicitCursors() public {
        uint256 firstOrderId = _makeSellOrder(10e6, 20e6);
        uint256 secondOrderId = _makeSellOrder(20e6, 30e6);
        uint256 thirdOrderId = _makeSellOrder(30e6, 40e6);

        (IBaseOrderBook.Order[] memory firstPage, uint256 nextCursor) = orderBook.getOrders(0, 2);
        require(firstPage.length == 2, "first page length mismatch");
        require(firstPage[0].id == firstOrderId, "first page first id mismatch");
        require(firstPage[1].id == secondOrderId, "first page second id mismatch");
        require(nextCursor == thirdOrderId, "first page cursor mismatch");

        (IBaseOrderBook.Order[] memory secondPage, uint256 finalCursor) = orderBook.getOrders(nextCursor, 2);
        require(secondPage.length == 1, "second page length mismatch");
        require(secondPage[0].id == thirdOrderId, "second page id mismatch");
        require(finalCursor == 0, "final cursor mismatch");

        (IBaseOrderBook.Order[] memory emptyPage, uint256 emptyCursor) = orderBook.getOrders(thirdOrderId + 1, 2);
        require(emptyPage.length == 0, "out-of-range page not empty");
        require(emptyCursor == 0, "out-of-range cursor mismatch");
    }

    function testRotatesGuardianAndOwnerCanUnpause() public {
        orderBook.setPauseGuardian(GUARDIAN);
        require(orderBook.pauseGuardian() == GUARDIAN, "guardian not installed");

        vm.prank(GUARDIAN);
        orderBook.pause();
        require(orderBook.paused(), "guardian did not pause");

        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, GUARDIAN));
        orderBook.unpause();

        orderBook.unpause();
        require(!orderBook.paused(), "owner did not unpause");

        orderBook.setPauseGuardian(SECOND_GUARDIAN);
        require(orderBook.pauseGuardian() == SECOND_GUARDIAN, "guardian not rotated");

        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(IOrderBookAdministration.UnauthorizedPauseCaller.selector, GUARDIAN));
        orderBook.pause();

        vm.prank(SECOND_GUARDIAN);
        orderBook.pause();
        require(orderBook.paused(), "new guardian did not pause");
        orderBook.unpause();
    }

    function testTransfersOwnershipInTwoStepsAndPreservesOwnerControls() public {
        orderBook.transferOwnership(NEW_OWNER);
        require(orderBook.owner() == address(this), "ownership transferred before acceptance");
        require(orderBook.pendingOwner() == NEW_OWNER, "pending owner mismatch");

        vm.prank(NEW_OWNER);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, NEW_OWNER));
        orderBook.setPauseGuardian(GUARDIAN);

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, UNAUTHORIZED));
        orderBook.acceptOwnership();

        vm.prank(NEW_OWNER);
        orderBook.acceptOwnership();
        require(orderBook.owner() == NEW_OWNER, "new owner not installed");
        require(orderBook.pendingOwner() == address(0), "pending owner not cleared");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        orderBook.setPauseGuardian(GUARDIAN);

        vm.prank(NEW_OWNER);
        orderBook.setPauseGuardian(GUARDIAN);
        require(orderBook.pauseGuardian() == GUARDIAN, "new owner control failed");

        vm.prank(NEW_OWNER);
        vm.expectRevert(OrderBookWithFeeController.OwnershipRenunciationDisabled.selector);
        orderBook.renounceOwnership();
        require(orderBook.owner() == NEW_OWNER, "ownership was renounced");
    }

    function _makeSellOrder(uint256 baseAmount, uint256 quoteAmount) private returns (uint256 orderId) {
        vm.prank(MAKER);
        base.approve(address(orderBook), baseAmount);
        vm.prank(MAKER);
        orderId = orderBook.makeOrder(
            IBaseOrderBook.MakeOrderParams({
                side: Side.SELL,
                totalBaseAmount: baseAmount,
                totalQuoteAmount: quoteAmount,
                minimumFillBaseAmount: 2,
                expiry: uint48(block.timestamp + 1 days)
            })
        );
    }
}
