// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {FeeQuote} from "../contracts/interfaces/FeeQuote.sol";
import {FeeRole} from "../contracts/interfaces/FeeRole.sol";
import {IBaseOrderBook} from "../contracts/interfaces/IBaseOrderBook.sol";
import {OrderBookWithFeeController} from "../contracts/OrderBookWithFeeController.sol";
import {Side} from "../contracts/interfaces/Side.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOrderBookFeeController} from "./mocks/MockOrderBookFeeController.sol";

interface VmHappyPath {
    function prank(address msgSender) external;
}

contract OrderBookHappyPathTest {
    VmHappyPath private constant vm = VmHappyPath(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant MAKER = address(0xA11CE);
    address private constant TAKER = address(0xB0B);
    address private constant RECIPIENT = address(0xCAFE);
    address private constant FEE_RECIPIENT = address(0xFEE);

    uint256 private constant BASE_TOTAL = 100e18;
    uint256 private constant QUOTE_TOTAL = 200e18;
    uint256 private constant TAKER_FEE = 2e18;

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
        base.mint(TAKER, BASE_TOTAL * 10);
        quote.mint(MAKER, QUOTE_TOTAL * 10);
        quote.mint(TAKER, QUOTE_TOTAL * 10);
    }

    function testMakesAndFillsSellOrder() public {
        uint256 orderId = _makeOrder(Side.SELL, BASE_TOTAL, QUOTE_TOTAL);

        vm.prank(TAKER);
        quote.approve(address(orderBook), QUOTE_TOTAL);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(orderId, BASE_TOTAL, RECIPIENT));

        _assertEq(quote.balanceOf(MAKER), QUOTE_TOTAL * 11);
        _assertEq(base.balanceOf(RECIPIENT), BASE_TOTAL);
        _assertEq(uint256(orderBook.statusOf(orderId)), uint256(IBaseOrderBook.OrderStatus.FILLED));
        _assertEq(orderBook.escrowLiability(address(base)), 0);
    }

    function testMakesAndFillsBuyOrder() public {
        uint256 orderId = _makeOrder(Side.BUY, BASE_TOTAL, QUOTE_TOTAL);

        vm.prank(TAKER);
        base.approve(address(orderBook), BASE_TOTAL);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(orderId, BASE_TOTAL, RECIPIENT));

        _assertEq(base.balanceOf(MAKER), BASE_TOTAL * 11);
        _assertEq(quote.balanceOf(RECIPIENT), QUOTE_TOTAL);
        _assertEq(uint256(orderBook.statusOf(orderId)), uint256(IBaseOrderBook.OrderStatus.FILLED));
        _assertEq(orderBook.escrowLiability(address(quote)), 0);
    }

    function testPartiallyFillsThenCompletesSellOrder() public {
        uint256 orderId = _makeOrder(Side.SELL, BASE_TOTAL, QUOTE_TOTAL);

        vm.prank(TAKER);
        quote.approve(address(orderBook), QUOTE_TOTAL);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(orderId, 40e18, RECIPIENT));

        _assertEq(orderBook.getOrder(orderId).remainingBaseAmount, 60e18);
        _assertEq(orderBook.remainingQuoteAmountOf(orderId), 120e18);
        _assertEq(orderBook.escrowLiability(address(base)), 60e18);

        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(orderId, 60e18, RECIPIENT));

        _assertEq(base.balanceOf(RECIPIENT), BASE_TOTAL);
        _assertEq(uint256(orderBook.statusOf(orderId)), uint256(IBaseOrderBook.OrderStatus.FILLED));
    }

    function testAmendsThenCancelsOrderAndRefundsEscrow() public {
        uint256 orderId = _makeOrder(Side.SELL, BASE_TOTAL, QUOTE_TOTAL);
        uint256 newBaseAmount = 120e18;
        uint256 newQuoteAmount = 300e18;

        vm.prank(MAKER);
        base.approve(address(orderBook), newBaseAmount - BASE_TOTAL);
        vm.prank(MAKER);
        uint256 replacementOrderId = orderBook.amendOrder(
            IBaseOrderBook.AmendOrderParams({
                orderId: orderId,
                expectedRemainingBaseAmount: BASE_TOTAL,
                newBaseAmount: newBaseAmount,
                newQuoteAmount: newQuoteAmount,
                newMinimumFillBaseAmount: 2,
                newExpiry: uint48(block.timestamp + 2 days)
            })
        );

        _assertEq(uint256(orderBook.statusOf(orderId)), uint256(IBaseOrderBook.OrderStatus.CANCELLED));
        _assertEq(orderBook.getOrder(replacementOrderId).remainingBaseAmount, newBaseAmount);
        _assertEq(orderBook.escrowLiability(address(base)), newBaseAmount);

        vm.prank(MAKER);
        orderBook.cancelOrder(replacementOrderId);

        _assertEq(base.balanceOf(MAKER), BASE_TOTAL * 10);
        _assertEq(orderBook.escrowLiability(address(base)), 0);
    }

    function testUsesLiveTakerFeeAndRoutesItToControllerRecipient() public {
        uint256 orderId = _makeOrder(Side.SELL, BASE_TOTAL, QUOTE_TOTAL);
        FeeQuote[] memory feeQuotes = new FeeQuote[](1);
        feeQuotes[0] = FeeQuote({token: address(quote), recipient: FEE_RECIPIENT, amount: TAKER_FEE});
        feeController.setQuotes(FeeRole.TAKER, feeQuotes);

        vm.prank(TAKER);
        quote.approve(address(orderBook), QUOTE_TOTAL + TAKER_FEE);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(orderId, BASE_TOTAL, RECIPIENT));

        _assertEq(quote.balanceOf(MAKER), QUOTE_TOTAL * 11);
        _assertEq(quote.balanceOf(FEE_RECIPIENT), TAKER_FEE);
        _assertEq(base.balanceOf(RECIPIENT), BASE_TOTAL);
    }

    function _makeOrder(Side side, uint256 baseAmount, uint256 quoteAmount) private returns (uint256 orderId) {
        MockERC20 escrowToken = side == Side.SELL ? base : quote;
        uint256 escrowAmount = side == Side.SELL ? baseAmount : quoteAmount;

        vm.prank(MAKER);
        escrowToken.approve(address(orderBook), escrowAmount);
        vm.prank(MAKER);
        orderId = orderBook.makeOrder(
            IBaseOrderBook.MakeOrderParams({
                side: side,
                totalBaseAmount: baseAmount,
                totalQuoteAmount: quoteAmount,
                minimumFillBaseAmount: 2,
                expiry: uint48(block.timestamp + 1 days)
            })
        );
    }

    function _takeParams(uint256 orderId, uint256 baseAmount, address recipient)
        private
        pure
        returns (IBaseOrderBook.TakeOrderParams memory params)
    {
        params = IBaseOrderBook.TakeOrderParams({
            orderId: orderId,
            baseAmount: baseAmount,
            recipient: recipient,
            maxBaseIn: type(uint256).max,
            maxQuoteIn: type(uint256).max,
            minBaseOut: 0,
            minQuoteOut: 0
        });
    }

    function _assertEq(uint256 actual, uint256 expected) private pure {
        require(actual == expected, "uint mismatch");
    }
}
