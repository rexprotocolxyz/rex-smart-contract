// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

import {IBaseOrderBook} from "../contracts/interfaces/IBaseOrderBook.sol";
import {IOrderBookAdministration} from "../contracts/interfaces/IOrderBookAdministration.sol";
import {OrderBookWithFeeController} from "../contracts/OrderBookWithFeeController.sol";
import {Side} from "../contracts/interfaces/Side.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOrderBookFeeController} from "./mocks/MockOrderBookFeeController.sol";

interface VmLegacyMode {
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData, address emitter) external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function prank(address msgSender) external;
    function warp(uint256 newTimestamp) external;
}

contract OrderBookLegacyModeTest {
    VmLegacyMode private constant vm = VmLegacyMode(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant MAKER = address(0xA11CE);
    address private constant TAKER = address(0xB0B);
    address private constant RECIPIENT = address(0xCAFE);
    address private constant GUARDIAN = address(0x600D);
    address private constant UNAUTHORIZED = address(0xBAD);
    uint256 private constant BASE_TOTAL = 100e6;
    uint256 private constant QUOTE_TOTAL = 97e6;

    MockERC20 private base;
    MockERC20 private quote;
    OrderBookWithFeeController private orderBook;

    function setUp() public {
        base = new MockERC20();
        quote = new MockERC20();
        orderBook = new OrderBookWithFeeController(
            address(base), address(quote), address(this), new MockOrderBookFeeController(1 days), 100, 100
        );
        orderBook.setPauseGuardian(GUARDIAN);
        base.mint(MAKER, BASE_TOTAL * 8);
        quote.mint(TAKER, QUOTE_TOTAL * 8);
    }

    function testOnlyOwnerCanScheduleAndAnyoneCanExecuteLegacyModeAtDeadline() public {
        uint48 activationTime = uint48(block.timestamp + 10 days);

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, UNAUTHORIZED));
        orderBook.scheduleLegacyMode(activationTime);

        vm.prank(GUARDIAN);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, GUARDIAN));
        orderBook.scheduleLegacyMode(activationTime);

        require(!orderBook.legacyMode(), "legacy mode entered by unauthorized caller");
        require(orderBook.minimumLegacyModeDelay() == 7 days, "unexpected minimum legacy mode delay");

        vm.expectEmit(true, false, false, true, address(orderBook));
        emit IOrderBookAdministration.LegacyModeScheduled(address(this), activationTime);
        orderBook.scheduleLegacyMode(activationTime);

        require(!orderBook.legacyMode(), "scheduling entered legacy mode");
        require(orderBook.legacyModeActivationTime() == activationTime, "activation time not stored");

        vm.expectRevert(
            abi.encodeWithSelector(IOrderBookAdministration.LegacyModeAlreadyScheduled.selector, activationTime)
        );
        orderBook.scheduleLegacyMode(uint48(block.timestamp + 20 days));

        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderBookAdministration.LegacyModeNotReady.selector, activationTime, block.timestamp
            )
        );
        orderBook.executeLegacyMode();

        vm.warp(activationTime);
        vm.expectEmit(true, false, false, true, address(orderBook));
        emit IOrderBookAdministration.LegacyModeEntered(UNAUTHORIZED);
        vm.prank(UNAUTHORIZED);
        orderBook.executeLegacyMode();

        require(orderBook.legacyMode(), "legacy mode not entered");
        require(orderBook.legacyModeActivationTime() == 0, "executed schedule not cleared");

        vm.expectRevert(IOrderBookAdministration.LegacyModeAlreadyEnabled.selector);
        orderBook.scheduleLegacyMode(uint48(block.timestamp + 20 days));

        vm.expectRevert(IOrderBookAdministration.LegacyModeAlreadyEnabled.selector);
        orderBook.executeLegacyMode();

        vm.expectRevert(IOrderBookAdministration.LegacyModeAlreadyEnabled.selector);
        orderBook.cancelLegacyModeSchedule();
    }

    function testRejectsLegacyModeActivationBeforeMinimumDelay() public {
        uint48 earliestActivationTime = uint48(block.timestamp + orderBook.minimumLegacyModeDelay());
        uint48 requestedActivationTime = earliestActivationTime - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderBookAdministration.LegacyModeActivationTooEarly.selector,
                requestedActivationTime,
                earliestActivationTime
            )
        );
        orderBook.scheduleLegacyMode(requestedActivationTime);

        orderBook.scheduleLegacyMode(earliestActivationTime);
        require(orderBook.legacyModeActivationTime() == earliestActivationTime, "minimum activation time rejected");
    }

    function testOwnerAndGuardianCanCancelScheduledLegacyMode() public {
        uint48 firstExecuteAfter = _scheduleLegacyModeAtMinimumDelay();

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(
            abi.encodeWithSelector(IOrderBookAdministration.UnauthorizedLegacyModeCancellation.selector, UNAUTHORIZED)
        );
        orderBook.cancelLegacyModeSchedule();

        vm.expectEmit(true, false, false, true, address(orderBook));
        emit IOrderBookAdministration.LegacyModeScheduleCancelled(GUARDIAN, firstExecuteAfter);
        vm.prank(GUARDIAN);
        orderBook.cancelLegacyModeSchedule();

        require(orderBook.legacyModeActivationTime() == 0, "guardian cancellation did not clear schedule");
        require(!orderBook.legacyMode(), "cancellation entered legacy mode");

        vm.expectRevert(IOrderBookAdministration.NoLegacyModeScheduled.selector);
        orderBook.executeLegacyMode();

        vm.expectRevert(IOrderBookAdministration.NoLegacyModeScheduled.selector);
        orderBook.cancelLegacyModeSchedule();

        vm.warp(block.timestamp + 1 hours);
        uint48 secondExecuteAfter = uint48(block.timestamp + 10 days);
        orderBook.scheduleLegacyMode(secondExecuteAfter);
        require(orderBook.legacyModeActivationTime() == secondExecuteAfter, "requested activation time not stored");

        vm.warp(secondExecuteAfter);
        vm.expectEmit(true, false, false, true, address(orderBook));
        emit IOrderBookAdministration.LegacyModeScheduleCancelled(address(this), secondExecuteAfter);
        orderBook.cancelLegacyModeSchedule();
        require(!orderBook.legacyMode(), "mature cancellation entered legacy mode");
        require(orderBook.legacyModeActivationTime() == 0, "mature cancellation retained schedule");
    }

    function testScheduledLegacyModeDoesNotRestrictTrading() public {
        uint256 amendOrderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL, uint48(block.timestamp + 3 days));
        uint256 takeOrderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL, uint48(block.timestamp + 3 days));

        _scheduleLegacyModeAtMinimumDelay();

        uint256 newOrderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL, uint48(block.timestamp + 3 days));
        require(orderBook.statusOf(newOrderId) == IBaseOrderBook.OrderStatus.OPEN, "scheduled mode blocked make");

        vm.prank(MAKER);
        uint256 replacementOrderId = orderBook.amendOrder(
            IBaseOrderBook.AmendOrderParams({
                orderId: amendOrderId,
                expectedRemainingBaseAmount: BASE_TOTAL,
                newBaseAmount: BASE_TOTAL / 2,
                newQuoteAmount: QUOTE_TOTAL / 2,
                newMinimumFillBaseAmount: 0,
                newExpiry: uint48(block.timestamp + 3 days)
            })
        );
        require(
            orderBook.statusOf(replacementOrderId) == IBaseOrderBook.OrderStatus.OPEN, "scheduled mode blocked amend"
        );

        vm.prank(TAKER);
        quote.approve(address(orderBook), QUOTE_TOTAL);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(takeOrderId));
        require(orderBook.statusOf(takeOrderId) == IBaseOrderBook.OrderStatus.FILLED, "scheduled mode blocked take");
    }

    function testLegacyModeBlocksMakeAndAmendButAllowsTakeCancelAndSweep() public {
        uint256 amendOrderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL, uint48(block.timestamp + 10 days));
        uint256 takeOrderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL, uint48(block.timestamp + 10 days));
        uint256 cancelOrderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL, uint48(block.timestamp + 10 days));
        uint256 sweepOrderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL, uint48(block.timestamp + 1 days));
        uint256 batchSweepOrderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL, uint48(block.timestamp + 1 days));
        uint256 orderCountBeforeLegacyMode = orderBook.orderCount();

        _scheduleAndExecuteLegacyMode();

        vm.prank(MAKER);
        vm.expectRevert(IOrderBookAdministration.OrderBookInLegacyMode.selector);
        orderBook.makeOrder(_makeOrderParams(uint48(block.timestamp + 1 days)));

        vm.prank(MAKER);
        vm.expectRevert(IOrderBookAdministration.OrderBookInLegacyMode.selector);
        orderBook.amendOrder(
            IBaseOrderBook.AmendOrderParams({
                orderId: amendOrderId,
                expectedRemainingBaseAmount: BASE_TOTAL,
                newBaseAmount: BASE_TOTAL / 2,
                newQuoteAmount: QUOTE_TOTAL / 2,
                newMinimumFillBaseAmount: 0,
                newExpiry: uint48(block.timestamp + 2 days)
            })
        );

        require(orderBook.orderCount() == orderCountBeforeLegacyMode, "legacy mode allocated a new order id");
        require(orderBook.statusOf(amendOrderId) == IBaseOrderBook.OrderStatus.OPEN, "failed amend changed order");

        vm.prank(TAKER);
        quote.approve(address(orderBook), QUOTE_TOTAL);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(takeOrderId));
        require(orderBook.statusOf(takeOrderId) == IBaseOrderBook.OrderStatus.FILLED, "legacy fill failed");

        vm.prank(MAKER);
        orderBook.cancelOrder(cancelOrderId);
        require(orderBook.statusOf(cancelOrderId) == IBaseOrderBook.OrderStatus.CANCELLED, "legacy cancel failed");

        orderBook.sweepExpiredOrder(sweepOrderId);
        require(orderBook.statusOf(sweepOrderId) == IBaseOrderBook.OrderStatus.EXPIRED, "legacy sweep failed");

        uint256[] memory orderIds = new uint256[](1);
        orderIds[0] = batchSweepOrderId;
        orderBook.sweepExpiredOrders(orderIds);
        require(
            orderBook.statusOf(batchSweepOrderId) == IBaseOrderBook.OrderStatus.EXPIRED, "legacy batch sweep failed"
        );
    }

    function testPauseAndUnpausePreserveLegacyModeAndUserExits() public {
        uint256 takeOrderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL, uint48(block.timestamp + 10 days));
        uint256 cancelOrderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL, uint48(block.timestamp + 10 days));
        uint256 sweepOrderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL, uint48(block.timestamp + 1 days));

        vm.prank(GUARDIAN);
        orderBook.pause();
        _scheduleAndExecuteLegacyMode();

        vm.prank(TAKER);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        orderBook.takeOrder(_takeParams(takeOrderId));

        vm.prank(MAKER);
        orderBook.cancelOrder(cancelOrderId);
        require(orderBook.statusOf(cancelOrderId) == IBaseOrderBook.OrderStatus.CANCELLED, "paused cancel failed");

        orderBook.sweepExpiredOrder(sweepOrderId);
        require(orderBook.statusOf(sweepOrderId) == IBaseOrderBook.OrderStatus.EXPIRED, "paused sweep failed");

        orderBook.unpause();
        require(orderBook.legacyMode(), "unpause exited legacy mode");

        vm.prank(TAKER);
        quote.approve(address(orderBook), QUOTE_TOTAL);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(takeOrderId));
        require(orderBook.statusOf(takeOrderId) == IBaseOrderBook.OrderStatus.FILLED, "unpaused legacy fill failed");

        vm.prank(MAKER);
        vm.expectRevert(IOrderBookAdministration.OrderBookInLegacyMode.selector);
        orderBook.makeOrder(_makeOrderParams(uint48(block.timestamp + 1 days)));
    }

    function testQuoteFunctionsRemainAvailableInLegacyMode() public {
        uint256 orderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL, uint48(block.timestamp + 10 days));
        _scheduleAndExecuteLegacyMode();

        vm.prank(MAKER);
        orderBook.quoteMakeOrder(_makeOrderParams(uint48(block.timestamp + 1 days)));

        vm.prank(MAKER);
        orderBook.quoteAmendOrder(
            IBaseOrderBook.AmendOrderParams({
                orderId: orderId,
                expectedRemainingBaseAmount: BASE_TOTAL,
                newBaseAmount: BASE_TOTAL / 2,
                newQuoteAmount: QUOTE_TOTAL / 2,
                newMinimumFillBaseAmount: 0,
                newExpiry: uint48(block.timestamp + 2 days)
            })
        );

        vm.prank(TAKER);
        orderBook.quoteTakeOrder(orderId, BASE_TOTAL, RECIPIENT);
    }

    function _scheduleAndExecuteLegacyMode() private {
        uint48 activationTime = _scheduleLegacyModeAtMinimumDelay();
        vm.warp(activationTime);
        orderBook.executeLegacyMode();
    }

    function _scheduleLegacyModeAtMinimumDelay() private returns (uint48 activationTime) {
        activationTime = uint48(block.timestamp + orderBook.minimumLegacyModeDelay());
        orderBook.scheduleLegacyMode(activationTime);
    }

    function _makeSellOrder(uint256 baseAmount, uint256 quoteAmount, uint48 expiry) private returns (uint256 orderId) {
        vm.prank(MAKER);
        base.approve(address(orderBook), baseAmount);
        vm.prank(MAKER);
        orderId = orderBook.makeOrder(
            IBaseOrderBook.MakeOrderParams({
                side: Side.SELL,
                totalBaseAmount: baseAmount,
                totalQuoteAmount: quoteAmount,
                minimumFillBaseAmount: 0,
                expiry: expiry
            })
        );
    }

    function _makeOrderParams(uint48 expiry) private pure returns (IBaseOrderBook.MakeOrderParams memory) {
        return IBaseOrderBook.MakeOrderParams({
            side: Side.SELL,
            totalBaseAmount: BASE_TOTAL,
            totalQuoteAmount: QUOTE_TOTAL,
            minimumFillBaseAmount: 0,
            expiry: expiry
        });
    }

    function _takeParams(uint256 orderId) private pure returns (IBaseOrderBook.TakeOrderParams memory) {
        return IBaseOrderBook.TakeOrderParams({
            orderId: orderId,
            baseAmount: BASE_TOTAL,
            recipient: RECIPIENT,
            maxBaseIn: type(uint256).max,
            maxQuoteIn: QUOTE_TOTAL,
            minBaseOut: 0,
            minQuoteOut: 0
        });
    }
}
