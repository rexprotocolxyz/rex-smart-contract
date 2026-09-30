// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IBaseOrderBook} from "../../contracts/interfaces/IBaseOrderBook.sol";
import {IOrderBookAdministration} from "../../contracts/interfaces/IOrderBookAdministration.sol";
import {OrderBookWithFeeController} from "../../contracts/OrderBookWithFeeController.sol";
import {Quote} from "../../contracts/interfaces/Quote.sol";
import {SettlementQuote} from "../../contracts/interfaces/SettlementQuote.sol";
import {Side} from "../../contracts/interfaces/Side.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

interface VmTradingHandler {
    function prank(address msgSender) external;
    function warp(uint256 newTimestamp) external;
}

interface IFeeRecipientController {
    function feeRecipient() external view returns (address);
}

/// @notice Stateful invariant actions for order creation, settlement, cancellation, and expiry.
contract OrderBookTradingHandler {
    VmTradingHandler private constant vm = VmTradingHandler(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant MAKER = address(0xA11CE);
    address private constant TAKER = address(0xB0B);
    uint256 private constant MAX_ACTION_AMOUNT = 1e18;

    OrderBookWithFeeController public immutable orderBook;
    MockERC20 private immutable _base;
    MockERC20 private immutable _quote;

    constructor(OrderBookWithFeeController orderBook_, MockERC20 base, MockERC20 quote) {
        orderBook = orderBook_;
        _base = base;
        _quote = quote;
        base.mint(MAKER, type(uint128).max);
        base.mint(TAKER, type(uint128).max);
        quote.mint(MAKER, type(uint128).max);
        quote.mint(TAKER, type(uint128).max);
        vm.prank(MAKER);
        base.approve(address(orderBook_), type(uint256).max);
        vm.prank(MAKER);
        quote.approve(address(orderBook_), type(uint256).max);
        vm.prank(TAKER);
        base.approve(address(orderBook_), type(uint256).max);
        vm.prank(TAKER);
        quote.approve(address(orderBook_), type(uint256).max);
    }

    function makeSell(uint256 baseSeed, uint256 quoteSeed) external {
        _makeOrder(Side.SELL, baseSeed, quoteSeed);
    }

    function makeBuy(uint256 baseSeed, uint256 quoteSeed) external {
        _makeOrder(Side.BUY, baseSeed, quoteSeed);
    }

    function take(uint256 orderSeed, uint256 amountSeed) external {
        uint256 count = orderBook.orderCount();
        if (count == 0) return;
        uint256 orderId = orderSeed % count + 1;
        IBaseOrderBook.Order memory order = orderBook.getOrder(orderId);
        if (order.status != IBaseOrderBook.OrderStatus.OPEN) return;

        uint256 baseAmount = amountSeed % order.remainingBaseAmount + 1;
        vm.prank(TAKER);
        try orderBook.quoteTakeOrder(orderId, baseAmount, TAKER) returns (
            Quote[] memory, SettlementQuote memory settlement
        ) {
            address feeRecipient = IFeeRecipientController(address(orderBook.feeController())).feeRecipient();
            uint256 baseFeeBalanceBefore = _base.balanceOf(feeRecipient);
            uint256 quoteFeeBalanceBefore = _quote.balanceOf(feeRecipient);

            vm.prank(TAKER);
            orderBook.takeOrder(
                IBaseOrderBook.TakeOrderParams({
                    orderId: orderId,
                    baseAmount: baseAmount,
                    recipient: TAKER,
                    maxBaseIn: type(uint256).max,
                    maxQuoteIn: type(uint256).max,
                    minBaseOut: 0,
                    minQuoteOut: 0
                })
            );

            (uint256 expectedBaseFee, uint256 expectedQuoteFee) = _feeAmounts(settlement);
            require(
                _base.balanceOf(feeRecipient) - baseFeeBalanceBefore == expectedBaseFee, "base fee settlement mismatch"
            );
            require(
                _quote.balanceOf(feeRecipient) - quoteFeeBalanceBefore == expectedQuoteFee,
                "quote fee settlement mismatch"
            );
        } catch {
            // Some randomly selected partial amounts cannot produce a nonzero quote delta.
            return;
        }
    }

    function warpPastExpiry(uint256 orderSeed, uint256 extraTimeSeed) external {
        uint256 count = orderBook.orderCount();
        if (count == 0) return;
        uint256 orderId = orderSeed % count + 1;
        IBaseOrderBook.Order memory order = orderBook.getOrder(orderId);
        if (order.status != IBaseOrderBook.OrderStatus.OPEN) return;

        vm.warp(uint256(order.expiry) + extraTimeSeed % 1 days);
        require(orderBook.statusOf(orderId) == IBaseOrderBook.OrderStatus.EXPIRED, "warp did not expire order");
    }

    function sweepExpired(uint256 orderSeed) external {
        uint256 count = orderBook.orderCount();
        if (count == 0) return;
        uint256 orderId = orderSeed % count + 1;
        if (!_isUnsweptExpired(orderId)) return;

        IBaseOrderBook.Order memory order = orderBook.getOrder(orderId);
        (MockERC20 escrowToken, uint256 expectedRefund) = _remainingMakerEscrow(order);
        uint256 makerBalanceBefore = escrowToken.balanceOf(order.maker);
        uint256 liabilityBefore = orderBook.escrowLiability(address(escrowToken));

        orderBook.sweepExpiredOrder(orderId);

        require(escrowToken.balanceOf(order.maker) - makerBalanceBefore == expectedRefund, "incorrect sweep refund");
        require(
            liabilityBefore - orderBook.escrowLiability(address(escrowToken)) == expectedRefund,
            "incorrect sweep liability reduction"
        );
        require(orderBook.remainingQuoteAmountOf(orderId) == 0, "single sweep retained quote liability");
    }

    function sweepExpiredBatch(uint256 startSeed, uint256 sizeSeed) external {
        uint256 count = orderBook.orderCount();
        if (count == 0) return;
        uint256 maximumSize = count < 8 ? count : 8;
        uint256 size = sizeSeed % maximumSize + 1;
        uint256[] memory orderIds = new uint256[](size);
        uint256 start = startSeed % count;
        uint256 expectedBaseRefund;
        uint256 expectedQuoteRefund;
        for (uint256 i; i < size; ++i) {
            uint256 orderId = (start + i) % count + 1;
            orderIds[i] = orderId;
            if (!_isUnsweptExpired(orderId)) continue;
            IBaseOrderBook.Order memory order = orderBook.getOrder(orderId);
            (, uint256 expectedRefund) = _remainingMakerEscrow(order);
            if (order.side == Side.SELL) {
                expectedBaseRefund += expectedRefund;
            } else {
                expectedQuoteRefund += expectedRefund;
            }
        }

        uint256 makerBaseBalanceBefore = _base.balanceOf(MAKER);
        uint256 makerQuoteBalanceBefore = _quote.balanceOf(MAKER);
        uint256 baseLiabilityBefore = orderBook.escrowLiability(address(_base));
        uint256 quoteLiabilityBefore = orderBook.escrowLiability(address(_quote));
        orderBook.sweepExpiredOrders(orderIds);

        require(_base.balanceOf(MAKER) - makerBaseBalanceBefore == expectedBaseRefund, "incorrect batch base refund");
        require(
            _quote.balanceOf(MAKER) - makerQuoteBalanceBefore == expectedQuoteRefund, "incorrect batch quote refund"
        );
        require(
            baseLiabilityBefore - orderBook.escrowLiability(address(_base)) == expectedBaseRefund,
            "incorrect batch base liability reduction"
        );
        require(
            quoteLiabilityBefore - orderBook.escrowLiability(address(_quote)) == expectedQuoteRefund,
            "incorrect batch quote liability reduction"
        );
        for (uint256 i; i < size; ++i) {
            uint256 orderId = orderIds[i];
            IBaseOrderBook.Order memory order = orderBook.getOrder(orderId);
            if (order.status == IBaseOrderBook.OrderStatus.EXPIRED) {
                require(orderBook.remainingQuoteAmountOf(orderId) == 0, "batch sweep retained quote liability");
            }
        }
    }

    function cancel(uint256 orderSeed) external {
        uint256 count = orderBook.orderCount();
        if (count == 0) return;
        uint256 orderId = orderSeed % count + 1;
        IBaseOrderBook.Order memory order = orderBook.getOrder(orderId);
        bool effectivelyExpired = order.status == IBaseOrderBook.OrderStatus.EXPIRED;
        if (order.status != IBaseOrderBook.OrderStatus.OPEN && !effectivelyExpired) return;
        if (effectivelyExpired && orderBook.remainingQuoteAmountOf(orderId) == 0) return;

        (MockERC20 escrowToken, uint256 expectedRefund) = _remainingMakerEscrow(order);
        uint256 makerBalanceBefore = escrowToken.balanceOf(order.maker);
        uint256 liabilityBefore = orderBook.escrowLiability(address(escrowToken));
        vm.prank(order.maker);
        orderBook.cancelOrder(orderId);

        IBaseOrderBook.OrderStatus expectedStatus =
            effectivelyExpired ? IBaseOrderBook.OrderStatus.EXPIRED : IBaseOrderBook.OrderStatus.CANCELLED;
        require(orderBook.statusOf(orderId) == expectedStatus, "cancel finalized with unexpected status");
        require(escrowToken.balanceOf(order.maker) - makerBalanceBefore == expectedRefund, "incorrect cancel refund");
        require(
            liabilityBefore - orderBook.escrowLiability(address(escrowToken)) == expectedRefund,
            "incorrect cancel liability reduction"
        );
        require(orderBook.remainingQuoteAmountOf(orderId) == 0, "cancel retained quote liability");
    }

    function amend(uint256 orderSeed, uint256 baseSeed, uint256 quoteSeed) external {
        uint256 count = orderBook.orderCount();
        if (orderBook.legacyMode()) {
            uint256 legacyOrderId = count == 0 ? 1 : orderSeed % count + 1;
            uint256 expectedRemainingBaseAmount = count == 0 ? 0 : orderBook.getOrder(legacyOrderId).remainingBaseAmount;
            (uint256 legacyBaseAmount, uint256 legacyQuoteAmount) = _amounts(baseSeed, quoteSeed);
            vm.prank(MAKER);
            try orderBook.amendOrder(
                IBaseOrderBook.AmendOrderParams({
                    orderId: legacyOrderId,
                    expectedRemainingBaseAmount: expectedRemainingBaseAmount,
                    newBaseAmount: legacyBaseAmount,
                    newQuoteAmount: legacyQuoteAmount,
                    newMinimumFillBaseAmount: quoteSeed % 2 == 0 ? 0 : legacyBaseAmount / 2 + 1,
                    newExpiry: uint48(block.timestamp + 7 days)
                })
            ) returns (
                uint256
            ) {
                revert("amend succeeded in legacy mode");
            } catch (bytes memory reason) {
                _requireLegacyModeRevert(reason, "unexpected legacy amend revert");
            }
            require(orderBook.orderCount() == count, "legacy amend changed order count");
            return;
        }
        if (count == 0) return;
        uint256 orderId = orderSeed % count + 1;
        IBaseOrderBook.Order memory order = orderBook.getOrder(orderId);
        if (order.status != IBaseOrderBook.OrderStatus.OPEN) return;
        (uint256 baseAmount, uint256 quoteAmount) = _amounts(baseSeed, quoteSeed);

        vm.prank(MAKER);
        try orderBook.amendOrder(
            IBaseOrderBook.AmendOrderParams({
                orderId: orderId,
                expectedRemainingBaseAmount: order.remainingBaseAmount,
                newBaseAmount: baseAmount,
                newQuoteAmount: quoteAmount,
                newMinimumFillBaseAmount: quoteSeed % 2 == 0 ? 0 : baseAmount / 2 + 1,
                newExpiry: uint48(block.timestamp + 7 days)
            })
        ) {
            return;
        } catch {
            // Invalid stateful actions are intentionally ignored by the invariant handler.
            return;
        }
    }

    function _makeOrder(Side side, uint256 baseSeed, uint256 quoteSeed) private {
        (uint256 baseAmount, uint256 quoteAmount) = _amounts(baseSeed, quoteSeed);
        IBaseOrderBook.MakeOrderParams memory params = IBaseOrderBook.MakeOrderParams({
            side: side,
            totalBaseAmount: baseAmount,
            totalQuoteAmount: quoteAmount,
            minimumFillBaseAmount: baseSeed % 2 == 0 ? 0 : baseAmount / 2 + 1,
            expiry: uint48(block.timestamp + 7 days)
        });

        if (orderBook.legacyMode()) {
            uint256 count = orderBook.orderCount();
            vm.prank(MAKER);
            try orderBook.makeOrder(params) returns (uint256) {
                revert("make succeeded in legacy mode");
            } catch (bytes memory reason) {
                _requireLegacyModeRevert(reason, "unexpected legacy make revert");
            }
            require(orderBook.orderCount() == count, "legacy make changed order count");
            return;
        }

        vm.prank(MAKER);
        orderBook.makeOrder(params);
    }

    function _feeAmounts(SettlementQuote memory settlement) private view returns (uint256 baseFee, uint256 quoteFee) {
        uint256 inputFees = settlement.makerFeeAmount + settlement.inputFeeAmount;
        if (settlement.inputToken == address(_base)) {
            baseFee += inputFees;
        } else {
            quoteFee += inputFees;
        }
        if (settlement.outputToken == address(_base)) {
            baseFee += settlement.outputFeeAmount;
        } else {
            quoteFee += settlement.outputFeeAmount;
        }
    }

    function _amounts(uint256 baseSeed, uint256 quoteSeed)
        private
        pure
        returns (uint256 baseAmount, uint256 quoteAmount)
    {
        baseAmount = baseSeed % MAX_ACTION_AMOUNT + 1;
        quoteAmount = baseAmount + quoteSeed % baseAmount;
    }

    function _remainingMakerEscrow(IBaseOrderBook.Order memory order)
        private
        view
        returns (MockERC20 escrowToken, uint256 amount)
    {
        if (order.side == Side.SELL) return (_base, order.remainingBaseAmount);
        return (_quote, orderBook.remainingQuoteAmountOf(order.id));
    }

    function _requireLegacyModeRevert(bytes memory reason, string memory failureMessage) private pure {
        bytes memory expectedReason = abi.encodeWithSelector(IOrderBookAdministration.OrderBookInLegacyMode.selector);
        require(keccak256(reason) == keccak256(expectedReason), failureMessage);
    }

    function _isUnsweptExpired(uint256 orderId) private view returns (bool) {
        return orderBook.statusOf(orderId) == IBaseOrderBook.OrderStatus.EXPIRED
            && orderBook.remainingQuoteAmountOf(orderId) != 0;
    }
}
