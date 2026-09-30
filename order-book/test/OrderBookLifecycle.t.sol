// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IBaseOrderBook} from "../contracts/interfaces/IBaseOrderBook.sol";
import {OrderBookWithFeeController} from "../contracts/OrderBookWithFeeController.sol";
import {Side} from "../contracts/interfaces/Side.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOrderBookFeeController} from "./mocks/MockOrderBookFeeController.sol";
import {MockERC20TransferRestricted} from "./mocks/MockERC20TransferRestricted.sol";

interface VmLifecycle {
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData, address emitter) external;
    function expectRevert(bytes calldata revertData) external;
    function prank(address msgSender) external;
    function warp(uint256 newTimestamp) external;
}

contract OrderBookLifecycleTest {
    VmLifecycle private constant vm = VmLifecycle(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant MAKER = address(0xA11CE);
    address private constant TAKER = address(0xB0B);
    address private constant RECIPIENT = address(0xCAFE);
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
        base.mint(MAKER, BASE_TOTAL * 3);
        quote.mint(TAKER, QUOTE_TOTAL * 3);
    }

    function testAmendAfterPartialFillAdjustsEscrow() public {
        uint256 orderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL);
        uint256 filledBase = 40e6;
        uint256 filledQuote = 38_800_000;

        vm.prank(TAKER);
        quote.approve(address(orderBook), filledQuote);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(orderId, filledBase, filledQuote));

        uint256 replacementBase = 80e6;
        uint256 replacementQuote = 80e6;
        vm.prank(MAKER);
        base.approve(address(orderBook), replacementBase - (BASE_TOTAL - filledBase));
        vm.prank(MAKER);
        uint256 replacementOrderId = orderBook.amendOrder(
            IBaseOrderBook.AmendOrderParams({
                orderId: orderId,
                expectedRemainingBaseAmount: BASE_TOTAL - filledBase,
                newBaseAmount: replacementBase,
                newQuoteAmount: replacementQuote,
                newMinimumFillBaseAmount: 2,
                newExpiry: uint48(block.timestamp + 2 days)
            })
        );

        require(orderBook.statusOf(orderId) == IBaseOrderBook.OrderStatus.CANCELLED, "old order remains open");
        IBaseOrderBook.Order memory replacement = orderBook.getOrder(replacementOrderId);
        require(replacement.remainingBaseAmount == replacementBase, "replacement amount mismatch");
        require(base.balanceOf(address(orderBook)) == replacementBase, "escrow mismatch");
    }

    function testExpiredOrderCanBeSweptAndRefunded() public {
        uint256 orderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL);
        vm.warp(block.timestamp + 1 days);

        orderBook.sweepExpiredOrder(orderId);

        require(orderBook.statusOf(orderId) == IBaseOrderBook.OrderStatus.EXPIRED, "wrong status");
        require(base.balanceOf(MAKER) == BASE_TOTAL * 3, "maker not refunded");
        require(base.balanceOf(address(orderBook)) == 0, "escrow not released");
    }

    function testCancelAtExactExpiryFinalizesExpiredAndRefunds() public {
        uint256 orderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL);
        uint48 expiry = orderBook.getOrder(orderId).expiry;
        vm.warp(expiry);

        vm.expectEmit(true, true, true, true, address(orderBook));
        emit IBaseOrderBook.ExpiredOrderSwept(orderId, MAKER, MAKER);
        vm.prank(MAKER);
        orderBook.cancelOrder(orderId);

        require(orderBook.statusOf(orderId) == IBaseOrderBook.OrderStatus.EXPIRED, "cancel did not finalize expiry");
        require(orderBook.escrowLiability(address(base)) == 0, "cancel did not release liability");
        require(base.balanceOf(address(orderBook)) == 0, "cancel left escrow in order book");
        require(base.balanceOf(MAKER) == BASE_TOTAL * 3, "maker not refunded by cancel");
    }

    function testCancelBuyAfterExpiryFinalizesAndRefundsQuoteEscrow() public {
        quote.mint(MAKER, QUOTE_TOTAL);
        uint256 orderId = _makeBuyOrder(BASE_TOTAL, QUOTE_TOTAL);
        uint48 expiry = orderBook.getOrder(orderId).expiry;
        vm.warp(uint256(expiry) + 1);

        vm.expectEmit(true, true, true, true, address(orderBook));
        emit IBaseOrderBook.ExpiredOrderSwept(orderId, MAKER, MAKER);
        vm.prank(MAKER);
        orderBook.cancelOrder(orderId);

        require(orderBook.statusOf(orderId) == IBaseOrderBook.OrderStatus.EXPIRED, "buy cancel status mismatch");
        require(orderBook.remainingQuoteAmountOf(orderId) == 0, "buy quote principal not cleared");
        require(orderBook.escrowLiability(address(quote)) == 0, "buy quote liability not released");
        require(quote.balanceOf(address(orderBook)) == 0, "buy quote escrow retained");
        require(quote.balanceOf(MAKER) == QUOTE_TOTAL, "buy maker not refunded");
    }

    function testExpiredOrderSweepCreditsRefundAndMakerWithdrawsToAlternateRecipient() public {
        MockERC20TransferRestricted restrictedBase = new MockERC20TransferRestricted();
        OrderBookWithFeeController restrictedOrderBook = new OrderBookWithFeeController(
            address(restrictedBase), address(quote), address(this), new MockOrderBookFeeController(1 days), 100, 100
        );
        restrictedBase.mint(MAKER, BASE_TOTAL);
        vm.prank(MAKER);
        restrictedBase.approve(address(restrictedOrderBook), BASE_TOTAL);
        vm.prank(MAKER);
        uint256 orderId = restrictedOrderBook.makeOrder(
            IBaseOrderBook.MakeOrderParams({
                side: Side.SELL,
                totalBaseAmount: BASE_TOTAL,
                totalQuoteAmount: QUOTE_TOTAL,
                minimumFillBaseAmount: BASE_TOTAL,
                expiry: uint48(block.timestamp + 1 days)
            })
        );
        vm.warp(block.timestamp + 1 days);

        restrictedBase.setTransfersPaused(true);
        restrictedOrderBook.sweepExpiredOrder(orderId);
        require(restrictedOrderBook.statusOf(orderId) == IBaseOrderBook.OrderStatus.EXPIRED, "order not finalized");
        require(
            restrictedOrderBook.claimableRefund(MAKER, address(restrictedBase)) == BASE_TOTAL,
            "failed refund not credited"
        );
        require(
            restrictedOrderBook.escrowLiability(address(restrictedBase)) == BASE_TOTAL,
            "refund credit not retained as liability"
        );

        restrictedBase.setTransfersPaused(false);
        restrictedBase.setRecipientBlocked(MAKER, true);
        vm.expectRevert(abi.encodeWithSelector(MockERC20TransferRestricted.RecipientBlocked.selector, MAKER));
        vm.prank(MAKER);
        restrictedOrderBook.withdrawRefund(address(restrictedBase), MAKER);
        require(
            restrictedOrderBook.claimableRefund(MAKER, address(restrictedBase)) == BASE_TOTAL,
            "failed withdrawal consumed credit"
        );

        vm.prank(MAKER);
        uint256 withdrawn = restrictedOrderBook.withdrawRefund(address(restrictedBase), RECIPIENT);
        require(withdrawn == BASE_TOTAL, "wrong withdrawn amount");
        require(restrictedOrderBook.remainingQuoteAmountOf(orderId) == 0, "quote liability not finalized");
        require(restrictedOrderBook.escrowLiability(address(restrictedBase)) == 0, "escrow liability not released");
        require(restrictedOrderBook.claimableRefund(MAKER, address(restrictedBase)) == 0, "credit not consumed");
        require(restrictedBase.balanceOf(RECIPIENT) == BASE_TOTAL, "alternate recipient not refunded");
    }

    function testRejectsRefundWithdrawalWithoutCreditAndDirectRefundExecution() public {
        vm.expectRevert(abi.encodeWithSelector(IBaseOrderBook.NoRefundAvailable.selector, MAKER, address(base)));
        vm.prank(MAKER);
        orderBook.withdrawRefund(address(base), RECIPIENT);

        vm.expectRevert(abi.encodeWithSelector(IBaseOrderBook.UnauthorizedRefundExecutor.selector, address(this)));
        orderBook.executeRefund(MAKER, address(base), RECIPIENT);
    }

    function testAmendmentDecreaseCreditsBlockedMakerAndPreservesReplacementEscrow() public {
        MockERC20TransferRestricted restrictedBase = new MockERC20TransferRestricted();
        OrderBookWithFeeController restrictedOrderBook = new OrderBookWithFeeController(
            address(restrictedBase), address(quote), address(this), new MockOrderBookFeeController(1 days), 100, 100
        );
        restrictedBase.mint(MAKER, BASE_TOTAL);
        vm.prank(MAKER);
        restrictedBase.approve(address(restrictedOrderBook), BASE_TOTAL);
        vm.prank(MAKER);
        uint256 orderId = restrictedOrderBook.makeOrder(
            IBaseOrderBook.MakeOrderParams({
                side: Side.SELL,
                totalBaseAmount: BASE_TOTAL,
                totalQuoteAmount: QUOTE_TOTAL,
                minimumFillBaseAmount: 2,
                expiry: uint48(block.timestamp + 1 days)
            })
        );

        uint256 replacementBase = 60e6;
        uint256 refundAmount = BASE_TOTAL - replacementBase;
        restrictedBase.setRecipientBlocked(MAKER, true);
        vm.prank(MAKER);
        uint256 replacementOrderId = restrictedOrderBook.amendOrder(
            IBaseOrderBook.AmendOrderParams({
                orderId: orderId,
                expectedRemainingBaseAmount: BASE_TOTAL,
                newBaseAmount: replacementBase,
                newQuoteAmount: 60e6,
                newMinimumFillBaseAmount: 2,
                newExpiry: uint48(block.timestamp + 2 days)
            })
        );

        require(
            restrictedOrderBook.claimableRefund(MAKER, address(restrictedBase)) == refundAmount,
            "amend refund not credited"
        );
        require(
            restrictedOrderBook.escrowLiability(address(restrictedBase)) == BASE_TOTAL, "combined liability mismatch"
        );
        require(
            restrictedOrderBook.getOrder(replacementOrderId).remainingBaseAmount == replacementBase,
            "replacement escrow mismatch"
        );

        vm.prank(MAKER);
        restrictedOrderBook.withdrawRefund(address(restrictedBase), RECIPIENT);
        require(
            restrictedOrderBook.escrowLiability(address(restrictedBase)) == replacementBase,
            "replacement liability changed by refund"
        );
        require(restrictedBase.balanceOf(RECIPIENT) == refundAmount, "alternate amendment refund missing");
    }

    function testBatchSweepSkipsIneligibleOrders() public {
        uint256 expiredOrderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL);
        uint256 openOrderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL);
        vm.warp(block.timestamp + 1 days);

        uint256[] memory orderIds = new uint256[](3);
        orderIds[0] = expiredOrderId;
        orderIds[1] = openOrderId;
        orderIds[2] = 999;
        orderBook.sweepExpiredOrders(orderIds);

        require(orderBook.statusOf(expiredOrderId) == IBaseOrderBook.OrderStatus.EXPIRED, "first not swept");
        require(orderBook.statusOf(openOrderId) == IBaseOrderBook.OrderStatus.EXPIRED, "second not swept");
    }

    function testAcceptsMaximumSweepBatchSize() public {
        uint256 maximumBatchSize = orderBook.maximumSweepBatchSize();
        uint256[] memory orderIds = new uint256[](maximumBatchSize);
        for (uint256 i; i < maximumBatchSize; ++i) {
            orderIds[i] = _makeSellOrder(1, 1);
        }
        vm.warp(block.timestamp + 1 days);

        orderBook.sweepExpiredOrders(orderIds);

        require(orderBook.escrowLiability(address(base)) == 0, "batch did not release all escrow");
        require(base.balanceOf(address(orderBook)) == 0, "batch left escrow balance");
    }

    function testRejectsSweepBatchAboveMaximum() public {
        uint256 maximumBatchSize = orderBook.maximumSweepBatchSize();
        uint256[] memory orderIds = new uint256[](maximumBatchSize + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IBaseOrderBook.SweepBatchTooLarge.selector, maximumBatchSize + 1, maximumBatchSize)
        );
        orderBook.sweepExpiredOrders(orderIds);
    }

    function testPauseBlocksNewTradingButNotCancellation() public {
        uint256 orderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL);
        orderBook.pause();

        vm.prank(MAKER);
        orderBook.cancelOrder(orderId);

        require(orderBook.statusOf(orderId) == IBaseOrderBook.OrderStatus.CANCELLED, "cancel blocked while paused");
    }

    function testRecoversOnlyDirectlyTransferredExcess() public {
        uint256 orderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL);
        uint256 excess = 123;
        base.mint(address(orderBook), excess);

        orderBook.recoverExcessToken(address(base), RECIPIENT);

        IBaseOrderBook.Order memory order = orderBook.getOrder(orderId);
        require(base.balanceOf(address(orderBook)) == order.remainingBaseAmount, "escrow was recovered");
        require(base.balanceOf(RECIPIENT) == excess, "excess not recovered");
    }

    function testReconcilesSellOrderQuoteRemainderAndBaseLiability() public {
        uint256 orderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL);
        uint256 filledBase = 40e6;
        uint256 filledQuote = 38_800_000;

        require(orderBook.remainingQuoteAmountOf(orderId) == QUOTE_TOTAL, "initial quote remainder mismatch");
        require(orderBook.escrowLiability(address(base)) == BASE_TOTAL, "initial base liability mismatch");

        vm.prank(TAKER);
        quote.approve(address(orderBook), filledQuote);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(orderId, filledBase, filledQuote));

        require(
            orderBook.remainingQuoteAmountOf(orderId) == QUOTE_TOTAL - filledQuote, "partial quote remainder mismatch"
        );
        require(orderBook.escrowLiability(address(base)) == BASE_TOTAL - filledBase, "partial base liability mismatch");

        vm.prank(MAKER);
        orderBook.cancelOrder(orderId);
        require(orderBook.remainingQuoteAmountOf(orderId) == 0, "closed quote remainder not zero");
        require(orderBook.escrowLiability(address(base)) == 0, "closed base liability not zero");
    }

    function testReconcilesBuyOrderQuoteRemainderAndQuoteLiability() public {
        uint256 filledBase = 40e6;
        uint256 filledQuote = 38_800_000;
        quote.mint(MAKER, QUOTE_TOTAL);
        base.mint(TAKER, filledBase);
        uint256 orderId = _makeBuyOrder(BASE_TOTAL, QUOTE_TOTAL);

        require(orderBook.remainingQuoteAmountOf(orderId) == QUOTE_TOTAL, "initial quote remainder mismatch");
        require(orderBook.escrowLiability(address(quote)) == QUOTE_TOTAL, "initial quote liability mismatch");

        vm.prank(TAKER);
        base.approve(address(orderBook), filledBase);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(orderId, filledBase, filledQuote));

        require(
            orderBook.remainingQuoteAmountOf(orderId) == QUOTE_TOTAL - filledQuote, "partial quote remainder mismatch"
        );
        require(
            orderBook.escrowLiability(address(quote)) == QUOTE_TOTAL - filledQuote, "partial quote liability mismatch"
        );

        vm.prank(MAKER);
        orderBook.cancelOrder(orderId);
        require(orderBook.remainingQuoteAmountOf(orderId) == 0, "closed quote remainder not zero");
        require(orderBook.escrowLiability(address(quote)) == 0, "closed quote liability not zero");
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
                minimumFillBaseAmount: baseAmount == 1 ? 1 : 2,
                expiry: uint48(block.timestamp + 1 days)
            })
        );
    }

    function _makeBuyOrder(uint256 baseAmount, uint256 quoteAmount) private returns (uint256 orderId) {
        vm.prank(MAKER);
        quote.approve(address(orderBook), quoteAmount);
        vm.prank(MAKER);
        orderId = orderBook.makeOrder(
            IBaseOrderBook.MakeOrderParams({
                side: Side.BUY,
                totalBaseAmount: baseAmount,
                totalQuoteAmount: quoteAmount,
                minimumFillBaseAmount: baseAmount == 1 ? 1 : 2,
                expiry: uint48(block.timestamp + 1 days)
            })
        );
    }

    function _takeParams(uint256 orderId, uint256 baseAmount, uint256 quoteAmount)
        private
        pure
        returns (IBaseOrderBook.TakeOrderParams memory)
    {
        return IBaseOrderBook.TakeOrderParams({
            orderId: orderId,
            baseAmount: baseAmount,
            recipient: RECIPIENT,
            maxBaseIn: type(uint256).max,
            maxQuoteIn: quoteAmount,
            minBaseOut: 0,
            minQuoteOut: 0
        });
    }
}
