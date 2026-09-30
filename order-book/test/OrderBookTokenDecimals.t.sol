// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BPSOrderBookFeeController} from "../contracts/BPSOrderBookFeeController.sol";
import {IBaseOrderBook} from "../contracts/interfaces/IBaseOrderBook.sol";
import {OrderBookWithFeeController} from "../contracts/OrderBookWithFeeController.sol";
import {Quote} from "../contracts/interfaces/Quote.sol";
import {SettlementQuote} from "../contracts/interfaces/SettlementQuote.sol";
import {Side} from "../contracts/interfaces/Side.sol";
import {TakerFeeToken} from "../contracts/interfaces/TakerFeeToken.sol";
import {MockERC20Decimals} from "./mocks/MockERC20Decimals.sol";
import {MockOrderBookFeeController} from "./mocks/MockOrderBookFeeController.sol";

interface VmTokenDecimals {
    function prank(address msgSender) external;
}

contract OrderBookTokenDecimalsTest {
    VmTokenDecimals private constant vm = VmTokenDecimals(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant MAKER = address(0xA11CE);
    address private constant TAKER = address(0xB0B);
    address private constant RECIPIENT = address(0xCAFE);
    address private constant FEE_RECIPIENT = address(0xFEE);

    function testFillsWBTCUSDCSELLOrderUsingNativeTokenUnits() public {
        (MockERC20Decimals base, MockERC20Decimals quote, OrderBookWithFeeController orderBook) = _deploy(8, 6);
        uint256 baseTotal = 1e8;
        uint256 quoteTotal = 100_000e6;
        uint256 firstBaseFill = 25_000_000;
        uint256 firstQuoteFill = 25_000e6;

        base.mint(MAKER, baseTotal);
        quote.mint(TAKER, quoteTotal);
        uint256 orderId = _make(orderBook, base, quote, Side.SELL, baseTotal, quoteTotal);

        vm.prank(TAKER);
        quote.approve(address(orderBook), quoteTotal);
        vm.prank(TAKER);
        (, SettlementQuote memory firstQuote) = orderBook.quoteTakeOrder(orderId, firstBaseFill, RECIPIENT);
        _assertEq(firstQuote.grossInputAmount, firstQuoteFill);
        _assertEq(firstQuote.grossOutputAmount, firstBaseFill);

        vm.prank(TAKER);
        orderBook.takeOrder(_take(orderId, firstBaseFill));
        _assertEq(orderBook.getOrder(orderId).remainingBaseAmount, baseTotal - firstBaseFill);
        _assertEq(orderBook.remainingQuoteAmountOf(orderId), quoteTotal - firstQuoteFill);

        vm.prank(TAKER);
        orderBook.takeOrder(_take(orderId, baseTotal - firstBaseFill));
        _assertEq(quote.balanceOf(MAKER), quoteTotal);
        _assertEq(base.balanceOf(RECIPIENT), baseTotal);
        _assertEq(orderBook.remainingQuoteAmountOf(orderId), 0);
    }

    function testFillsWBTCUSDCBUYOrderUsingNativeTokenUnits() public {
        (MockERC20Decimals base, MockERC20Decimals quote, OrderBookWithFeeController orderBook) = _deploy(8, 6);
        uint256 baseTotal = 1e8;
        uint256 quoteTotal = 100_000e6;
        uint256 firstBaseFill = 25_000_000;
        uint256 firstQuoteFill = 25_000e6;

        quote.mint(MAKER, quoteTotal);
        base.mint(TAKER, baseTotal);
        uint256 orderId = _make(orderBook, base, quote, Side.BUY, baseTotal, quoteTotal);

        vm.prank(TAKER);
        base.approve(address(orderBook), baseTotal);
        vm.prank(TAKER);
        (, SettlementQuote memory firstQuote) = orderBook.quoteTakeOrder(orderId, firstBaseFill, RECIPIENT);
        _assertEq(firstQuote.grossInputAmount, firstBaseFill);
        _assertEq(firstQuote.grossOutputAmount, firstQuoteFill);

        vm.prank(TAKER);
        orderBook.takeOrder(_take(orderId, firstBaseFill));
        _assertEq(orderBook.getOrder(orderId).remainingBaseAmount, baseTotal - firstBaseFill);
        _assertEq(orderBook.remainingQuoteAmountOf(orderId), quoteTotal - firstQuoteFill);

        vm.prank(TAKER);
        orderBook.takeOrder(_take(orderId, baseTotal - firstBaseFill));
        _assertEq(base.balanceOf(MAKER), baseTotal);
        _assertEq(quote.balanceOf(RECIPIENT), quoteTotal);
        _assertEq(orderBook.remainingQuoteAmountOf(orderId), 0);
    }

    function testETHUSDCSellPartialsReconcileCumulativeRounding() public {
        (MockERC20Decimals base, MockERC20Decimals quote, OrderBookWithFeeController orderBook) = _deploy(18, 6);
        uint256 baseTotal = 1e18;
        uint256 quoteTotal = 2_500e6;
        uint256 firstBaseFill = 333_333_333_333_333_333;
        uint256 secondBaseFill = firstBaseFill;
        uint256 finalBaseFill = baseTotal - firstBaseFill - secondBaseFill;

        base.mint(MAKER, baseTotal);
        quote.mint(TAKER, quoteTotal);
        uint256 orderId = _make(orderBook, base, quote, Side.SELL, baseTotal, quoteTotal);
        vm.prank(TAKER);
        quote.approve(address(orderBook), quoteTotal);

        _assertQuotedAndTake(orderBook, orderId, firstBaseFill, 833_333_334);
        _assertQuotedAndTake(orderBook, orderId, secondBaseFill, 833_333_333);
        _assertQuotedAndTake(orderBook, orderId, finalBaseFill, 833_333_333);

        _assertEq(quote.balanceOf(MAKER), quoteTotal);
        _assertEq(base.balanceOf(RECIPIENT), baseTotal);
        _assertEq(orderBook.remainingQuoteAmountOf(orderId), 0);
    }

    function testWBTCUSDCBpsFeesRemainDenominatedInFeeToken() public {
        MockERC20Decimals base = new MockERC20Decimals("Wrapped BTC", "WBTC", 8);
        MockERC20Decimals quote = new MockERC20Decimals("USD Coin", "USDC", 6);
        BPSOrderBookFeeController feeController =
            new BPSOrderBookFeeController(10, 10, 100, 100, TakerFeeToken.BASE, FEE_RECIPIENT, 1 days, address(this));
        OrderBookWithFeeController orderBook =
            new OrderBookWithFeeController(address(base), address(quote), address(this), feeController, 100, 100);
        uint256 baseTotal = 1e8;
        uint256 quoteTotal = 100_000e6;

        base.mint(MAKER, baseTotal);
        quote.mint(TAKER, quoteTotal);
        uint256 orderId = _make(orderBook, base, quote, Side.SELL, baseTotal, quoteTotal);
        vm.prank(TAKER);
        quote.approve(address(orderBook), quoteTotal);

        vm.prank(TAKER);
        (, SettlementQuote memory settlement) = orderBook.quoteTakeOrder(orderId, baseTotal, RECIPIENT);
        _assertEq(settlement.makerFeeAmount, 100e6);
        _assertEq(settlement.outputFeeAmount, 100_000);
        _assertEq(settlement.netOutputAmount, 99_900_000);

        vm.prank(TAKER);
        orderBook.takeOrder(_take(orderId, baseTotal));
        _assertEq(quote.balanceOf(MAKER), 99_900e6);
        _assertEq(base.balanceOf(RECIPIENT), 99_900_000);
        _assertEq(quote.balanceOf(FEE_RECIPIENT), 100e6);
        _assertEq(base.balanceOf(FEE_RECIPIENT), 100_000);
    }

    function _deploy(uint8 baseDecimals, uint8 quoteDecimals)
        private
        returns (MockERC20Decimals base, MockERC20Decimals quote, OrderBookWithFeeController orderBook)
    {
        base = new MockERC20Decimals("Base", "BASE", baseDecimals);
        quote = new MockERC20Decimals("Quote", "QUOTE", quoteDecimals);
        MockOrderBookFeeController feeController = new MockOrderBookFeeController(1 days);
        orderBook =
            new OrderBookWithFeeController(address(base), address(quote), address(this), feeController, 100, 100);
    }

    function _make(
        OrderBookWithFeeController orderBook,
        MockERC20Decimals base,
        MockERC20Decimals quote,
        Side side,
        uint256 baseAmount,
        uint256 quoteAmount
    ) private returns (uint256 orderId) {
        MockERC20Decimals escrowToken = side == Side.SELL ? base : quote;
        vm.prank(MAKER);
        escrowToken.approve(address(orderBook), side == Side.SELL ? baseAmount : quoteAmount);
        vm.prank(MAKER);
        orderId = orderBook.makeOrder(
            IBaseOrderBook.MakeOrderParams({
                side: side,
                totalBaseAmount: baseAmount,
                totalQuoteAmount: quoteAmount,
                minimumFillBaseAmount: baseAmount / quoteAmount + 1,
                expiry: uint48(block.timestamp + 1 days)
            })
        );
    }

    function _assertQuotedAndTake(
        OrderBookWithFeeController orderBook,
        uint256 orderId,
        uint256 baseAmount,
        uint256 expectedQuoteAmount
    ) private {
        vm.prank(TAKER);
        (Quote[] memory approvals, SettlementQuote memory settlement) =
            orderBook.quoteTakeOrder(orderId, baseAmount, RECIPIENT);
        _assertEq(approvals[0].amount, expectedQuoteAmount);
        _assertEq(settlement.grossInputAmount, expectedQuoteAmount);

        vm.prank(TAKER);
        orderBook.takeOrder(_take(orderId, baseAmount));
    }

    function _take(uint256 orderId, uint256 baseAmount)
        private
        pure
        returns (IBaseOrderBook.TakeOrderParams memory params)
    {
        params = IBaseOrderBook.TakeOrderParams({
            orderId: orderId,
            baseAmount: baseAmount,
            recipient: RECIPIENT,
            maxBaseIn: type(uint256).max,
            maxQuoteIn: type(uint256).max,
            minBaseOut: 0,
            minQuoteOut: 0
        });
    }

    function _assertEq(uint256 actual, uint256 expected) private pure {
        require(actual == expected, "not equal");
    }
}
