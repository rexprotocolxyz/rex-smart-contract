// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FeeQuote} from "../contracts/interfaces/FeeQuote.sol";
import {FeeRole} from "../contracts/interfaces/FeeRole.sol";
import {IBaseOrderBook} from "../contracts/interfaces/IBaseOrderBook.sol";
import {OrderBookWithFeeController} from "../contracts/OrderBookWithFeeController.sol";
import {Quote} from "../contracts/interfaces/Quote.sol";
import {SettlementQuote} from "../contracts/interfaces/SettlementQuote.sol";
import {Side} from "../contracts/interfaces/Side.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOrderBookFeeController} from "./mocks/MockOrderBookFeeController.sol";

interface VmQuoteEquivalence {
    function prank(address msgSender) external;
}

contract OrderBookQuoteEquivalenceTest {
    VmQuoteEquivalence private constant vm =
        VmQuoteEquivalence(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant MAKER = address(0xA11CE);
    address private constant FEE_RECIPIENT = address(0xFEE);
    uint256 private constant BASE_TOTAL = 100e6;
    uint256 private constant QUOTE_TOTAL = 97e6;

    MockERC20 private base;
    MockERC20 private quote;
    MockOrderBookFeeController private feeController;
    OrderBookWithFeeController private orderBook;

    function setUp() public {
        base = new MockERC20();
        quote = new MockERC20();
        feeController = new MockOrderBookFeeController(1 days);
        orderBook =
            new OrderBookWithFeeController(address(base), address(quote), address(this), feeController, 100, 100);

        base.mint(MAKER, BASE_TOTAL * 10);
        quote.mint(MAKER, QUOTE_TOTAL * 10);
    }

    function testQuoteMakeSellMatchesEscrowExecutionAndSettlement() public {
        uint256 makerFee = 500_000;
        uint256 takerOutputFee = 1_000_000;
        feeController.setQuotes(FeeRole.MAKER, _singleFeeQuote(address(quote), FEE_RECIPIENT, makerFee));
        feeController.setQuotes(FeeRole.TAKER, _singleFeeQuote(address(base), FEE_RECIPIENT, takerOutputFee));
        IBaseOrderBook.MakeOrderParams memory params = _makeParams(Side.SELL, BASE_TOTAL, QUOTE_TOTAL);

        vm.prank(MAKER);
        (Quote[] memory approvals, SettlementQuote memory settlement) = orderBook.quoteMakeOrder(params);

        _assertSingleQuote(approvals, address(base), BASE_TOTAL);
        _assertSettlement(
            settlement, address(quote), QUOTE_TOTAL, 0, address(base), BASE_TOTAL, takerOutputFee, makerFee
        );

        uint256 makerBalanceBefore = base.balanceOf(MAKER);
        vm.prank(MAKER);
        base.approve(address(orderBook), approvals[0].amount);
        vm.prank(MAKER);
        uint256 orderId = orderBook.makeOrder(params);

        require(makerBalanceBefore - base.balanceOf(MAKER) == approvals[0].amount, "sell approval mismatch");
        require(orderBook.escrowLiability(address(base)) == approvals[0].amount, "sell liability mismatch");
        require(base.balanceOf(address(orderBook)) == approvals[0].amount, "sell escrow mismatch");
        require(orderBook.getOrder(orderId).remainingBaseAmount == BASE_TOTAL, "sell order amount mismatch");
        require(base.balanceOf(FEE_RECIPIENT) == 0, "fee charged during make");
        require(quote.balanceOf(FEE_RECIPIENT) == 0, "fee charged during make");
    }

    function testQuoteMakeBuyMatchesEscrowExecutionAndSettlement() public {
        uint256 makerFee = 500_000;
        uint256 takerInputFee = 1_000_000;
        feeController.setQuotes(FeeRole.MAKER, _singleFeeQuote(address(base), FEE_RECIPIENT, makerFee));
        feeController.setQuotes(FeeRole.TAKER, _singleFeeQuote(address(base), FEE_RECIPIENT, takerInputFee));
        IBaseOrderBook.MakeOrderParams memory params = _makeParams(Side.BUY, BASE_TOTAL, QUOTE_TOTAL);

        vm.prank(MAKER);
        (Quote[] memory approvals, SettlementQuote memory settlement) = orderBook.quoteMakeOrder(params);

        _assertSingleQuote(approvals, address(quote), QUOTE_TOTAL);
        _assertSettlement(
            settlement, address(base), BASE_TOTAL, takerInputFee, address(quote), QUOTE_TOTAL, 0, makerFee
        );

        uint256 makerBalanceBefore = quote.balanceOf(MAKER);
        vm.prank(MAKER);
        quote.approve(address(orderBook), approvals[0].amount);
        vm.prank(MAKER);
        uint256 orderId = orderBook.makeOrder(params);

        require(makerBalanceBefore - quote.balanceOf(MAKER) == approvals[0].amount, "buy approval mismatch");
        require(orderBook.escrowLiability(address(quote)) == approvals[0].amount, "buy liability mismatch");
        require(quote.balanceOf(address(orderBook)) == approvals[0].amount, "buy escrow mismatch");
        require(orderBook.remainingQuoteAmountOf(orderId) == QUOTE_TOTAL, "buy principal mismatch");
        require(base.balanceOf(FEE_RECIPIENT) == 0, "fee charged during make");
    }

    function testQuoteAmendSellIncreaseMatchesAdditionalEscrowExecution() public {
        uint256 makerFee = 600_000;
        uint256 takerInputFee = 700_000;
        feeController.setQuotes(FeeRole.MAKER, _singleFeeQuote(address(quote), FEE_RECIPIENT, makerFee));
        feeController.setQuotes(FeeRole.TAKER, _singleFeeQuote(address(quote), FEE_RECIPIENT, takerInputFee));
        uint256 orderId = _makeOrder(Side.SELL, BASE_TOTAL, QUOTE_TOTAL);
        uint256 newBaseAmount = 120e6;
        uint256 newQuoteAmount = 120e6;
        IBaseOrderBook.AmendOrderParams memory params = _amendParams(orderId, BASE_TOTAL, newBaseAmount, newQuoteAmount);

        uint256 approvalAmount =
            _quoteAndAssertSellIncrease(params, newBaseAmount, newQuoteAmount, takerInputFee, makerFee);

        uint256 makerBalanceBefore = base.balanceOf(MAKER);
        vm.prank(MAKER);
        base.approve(address(orderBook), approvalAmount);
        vm.prank(MAKER);
        uint256 newOrderId = orderBook.amendOrder(params);

        require(makerBalanceBefore - base.balanceOf(MAKER) == approvalAmount, "amend approval mismatch");
        require(orderBook.escrowLiability(address(base)) == newBaseAmount, "amend liability mismatch");
        require(base.balanceOf(address(orderBook)) == newBaseAmount, "amend escrow mismatch");
        _assertReplacement(orderId, newOrderId, newBaseAmount, newQuoteAmount);
    }

    function testQuoteAmendBuyDecreaseMatchesRefundExecution() public {
        uint256 makerFee = 500_000;
        uint256 takerOutputFee = 200_000;
        feeController.setQuotes(FeeRole.MAKER, _singleFeeQuote(address(base), FEE_RECIPIENT, makerFee));
        feeController.setQuotes(FeeRole.TAKER, _singleFeeQuote(address(quote), FEE_RECIPIENT, takerOutputFee));
        uint256 orderId = _makeOrder(Side.BUY, BASE_TOTAL, QUOTE_TOTAL);
        uint256 newBaseAmount = 60e6;
        uint256 newQuoteAmount = 50e6;
        IBaseOrderBook.AmendOrderParams memory params = _amendParams(orderId, BASE_TOTAL, newBaseAmount, newQuoteAmount);

        uint256 refundAmount =
            _quoteAndAssertBuyDecrease(params, newBaseAmount, newQuoteAmount, takerOutputFee, makerFee);

        uint256 makerBalanceBefore = quote.balanceOf(MAKER);
        vm.prank(MAKER);
        uint256 newOrderId = orderBook.amendOrder(params);

        require(quote.balanceOf(MAKER) - makerBalanceBefore == refundAmount, "amend refund mismatch");
        require(orderBook.escrowLiability(address(quote)) == newQuoteAmount, "amend liability mismatch");
        require(quote.balanceOf(address(orderBook)) == newQuoteAmount, "amend escrow mismatch");
        require(orderBook.remainingQuoteAmountOf(orderId) == 0, "old quote principal retained");
        require(orderBook.remainingQuoteAmountOf(newOrderId) == newQuoteAmount, "new quote principal mismatch");
        _assertReplacement(orderId, newOrderId, newBaseAmount, newQuoteAmount);
    }

    function testQuoteAmendSameEscrowRequiresNoApprovalOrRefund() public {
        uint256 orderId = _makeOrder(Side.SELL, BASE_TOTAL, QUOTE_TOTAL);
        uint256 newQuoteAmount = 110e6;
        IBaseOrderBook.AmendOrderParams memory params = _amendParams(orderId, BASE_TOTAL, BASE_TOTAL, newQuoteAmount);

        vm.prank(MAKER);
        (Quote[] memory approvals, Quote[] memory refunds,) = orderBook.quoteAmendOrder(params);

        require(approvals.length == 0, "unexpected equal-escrow approval");
        require(refunds.length == 0, "unexpected equal-escrow refund");
        uint256 makerBalanceBefore = base.balanceOf(MAKER);
        vm.prank(MAKER);
        uint256 newOrderId = orderBook.amendOrder(params);

        require(base.balanceOf(MAKER) == makerBalanceBefore, "equal escrow changed maker balance");
        require(orderBook.escrowLiability(address(base)) == BASE_TOTAL, "equal escrow changed liability");
        _assertReplacement(orderId, newOrderId, BASE_TOTAL, newQuoteAmount);
    }

    function _quoteAndAssertSellIncrease(
        IBaseOrderBook.AmendOrderParams memory params,
        uint256 newBaseAmount,
        uint256 newQuoteAmount,
        uint256 takerInputFee,
        uint256 makerFee
    ) private returns (uint256 approvalAmount) {
        vm.prank(MAKER);
        (Quote[] memory approvals, Quote[] memory refunds, SettlementQuote memory settlement) =
            orderBook.quoteAmendOrder(params);

        _assertSingleQuote(approvals, address(base), newBaseAmount - BASE_TOTAL);
        require(refunds.length == 0, "unexpected increase refund");
        _assertSettlement(
            settlement, address(quote), newQuoteAmount, takerInputFee, address(base), newBaseAmount, 0, makerFee
        );
        return approvals[0].amount;
    }

    function _quoteAndAssertBuyDecrease(
        IBaseOrderBook.AmendOrderParams memory params,
        uint256 newBaseAmount,
        uint256 newQuoteAmount,
        uint256 takerOutputFee,
        uint256 makerFee
    ) private returns (uint256 refundAmount) {
        vm.prank(MAKER);
        (Quote[] memory approvals, Quote[] memory refunds, SettlementQuote memory settlement) =
            orderBook.quoteAmendOrder(params);

        require(approvals.length == 0, "unexpected decrease approval");
        _assertSingleQuote(refunds, address(quote), QUOTE_TOTAL - newQuoteAmount);
        _assertSettlement(
            settlement, address(base), newBaseAmount, 0, address(quote), newQuoteAmount, takerOutputFee, makerFee
        );
        return refunds[0].amount;
    }

    function _makeOrder(Side side, uint256 baseAmount, uint256 quoteAmount) private returns (uint256 orderId) {
        address escrowToken = side == Side.SELL ? address(base) : address(quote);
        uint256 escrowAmount = side == Side.SELL ? baseAmount : quoteAmount;
        vm.prank(MAKER);
        MockERC20(escrowToken).approve(address(orderBook), escrowAmount);
        vm.prank(MAKER);
        orderId = orderBook.makeOrder(_makeParams(side, baseAmount, quoteAmount));
    }

    function _makeParams(Side side, uint256 baseAmount, uint256 quoteAmount)
        private
        view
        returns (IBaseOrderBook.MakeOrderParams memory)
    {
        return IBaseOrderBook.MakeOrderParams({
            side: side,
            totalBaseAmount: baseAmount,
            totalQuoteAmount: quoteAmount,
            minimumFillBaseAmount: 2,
            expiry: uint48(block.timestamp + 1 days)
        });
    }

    function _amendParams(
        uint256 orderId,
        uint256 expectedRemainingBaseAmount,
        uint256 newBaseAmount,
        uint256 newQuoteAmount
    ) private view returns (IBaseOrderBook.AmendOrderParams memory) {
        return IBaseOrderBook.AmendOrderParams({
            orderId: orderId,
            expectedRemainingBaseAmount: expectedRemainingBaseAmount,
            newBaseAmount: newBaseAmount,
            newQuoteAmount: newQuoteAmount,
            newMinimumFillBaseAmount: 2,
            newExpiry: uint48(block.timestamp + 2 days)
        });
    }

    function _assertReplacement(
        uint256 oldOrderId,
        uint256 newOrderId,
        uint256 expectedBaseAmount,
        uint256 expectedQuoteAmount
    ) private view {
        require(orderBook.statusOf(oldOrderId) == IBaseOrderBook.OrderStatus.CANCELLED, "old order not cancelled");
        IBaseOrderBook.Order memory replacement = orderBook.getOrder(newOrderId);
        require(replacement.status == IBaseOrderBook.OrderStatus.OPEN, "replacement not open");
        require(replacement.totalBaseAmount == expectedBaseAmount, "replacement base mismatch");
        require(replacement.remainingBaseAmount == expectedBaseAmount, "replacement remainder mismatch");
        require(replacement.totalQuoteAmount == expectedQuoteAmount, "replacement quote mismatch");
    }

    function _assertSingleQuote(Quote[] memory quotes, address expectedToken, uint256 expectedAmount) private pure {
        require(quotes.length == 1, "quote count mismatch");
        require(quotes[0].token == expectedToken, "quote token mismatch");
        require(quotes[0].amount == expectedAmount, "quote amount mismatch");
    }

    function _assertSettlement(
        SettlementQuote memory settlement,
        address expectedInputToken,
        uint256 expectedGrossInput,
        uint256 expectedInputFee,
        address expectedOutputToken,
        uint256 expectedGrossOutput,
        uint256 expectedOutputFee,
        uint256 expectedMakerFee
    ) private pure {
        require(settlement.inputToken == expectedInputToken, "settlement input token mismatch");
        require(settlement.grossInputAmount == expectedGrossInput, "settlement gross input mismatch");
        require(settlement.inputFeeAmount == expectedInputFee, "settlement input fee mismatch");
        require(settlement.totalInputAmount == expectedGrossInput + expectedInputFee, "settlement total input mismatch");
        require(settlement.outputToken == expectedOutputToken, "settlement output token mismatch");
        require(settlement.grossOutputAmount == expectedGrossOutput, "settlement gross output mismatch");
        require(settlement.outputFeeAmount == expectedOutputFee, "settlement output fee mismatch");
        require(settlement.netOutputAmount == expectedGrossOutput - expectedOutputFee, "settlement net output mismatch");
        require(settlement.makerFeeAmount == expectedMakerFee, "settlement maker fee mismatch");
    }

    function _singleFeeQuote(address token, address recipient, uint256 amount)
        private
        pure
        returns (FeeQuote[] memory quotes)
    {
        quotes = new FeeQuote[](1);
        quotes[0] = FeeQuote({token: token, recipient: recipient, amount: amount});
    }
}
