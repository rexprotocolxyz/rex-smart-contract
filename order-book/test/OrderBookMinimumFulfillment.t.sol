// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IBaseOrderBook} from "../contracts/interfaces/IBaseOrderBook.sol";
import {BPSOrderBookFeeController} from "../contracts/BPSOrderBookFeeController.sol";
import {OrderBookWithFeeController} from "../contracts/OrderBookWithFeeController.sol";
import {Quote} from "../contracts/interfaces/Quote.sol";
import {SettlementQuote} from "../contracts/interfaces/SettlementQuote.sol";
import {Side} from "../contracts/interfaces/Side.sol";
import {TakerFeeToken} from "../contracts/interfaces/TakerFeeToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC20Decimals} from "./mocks/MockERC20Decimals.sol";
import {MockOrderBookFeeController} from "./mocks/MockOrderBookFeeController.sol";

interface VmMinimumFulfillment {
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData, address emitter) external;
    function expectRevert(bytes calldata revertData) external;
    function prank(address msgSender) external;
}

/// @notice Regression coverage for maker-defined minimum base-token fulfillment amounts.
contract OrderBookMinimumFulfillmentTest {
    VmMinimumFulfillment private constant vm =
        VmMinimumFulfillment(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant MAKER = address(0xA11CE);
    address private constant TAKER = address(0xB0B);
    address private constant RECIPIENT = address(0xCAFE);
    address private constant FEE_RECIPIENT = address(0xFEE);
    uint256 private constant TOTAL_BASE = 100;
    uint256 private constant TOTAL_QUOTE = 100;
    uint256 private constant MINIMUM_FILL = 30;
    uint16 private constant FEE_BPS = 1_000;

    MockERC20 private base;
    MockERC20 private quote;
    OrderBookWithFeeController private orderBook;

    function setUp() public {
        base = new MockERC20();
        quote = new MockERC20();
        orderBook = new OrderBookWithFeeController(
            address(base), address(quote), address(this), new MockOrderBookFeeController(1 days), 100, 100
        );
        base.mint(MAKER, TOTAL_BASE * 3);
        base.mint(TAKER, TOTAL_BASE * 3);
        quote.mint(MAKER, TOTAL_QUOTE * 3);
        quote.mint(TAKER, TOTAL_QUOTE * 3);
    }

    function testRejectsMinimumFulfillmentAboveOrderAmountAtMakeAndAmend() public {
        vm.prank(MAKER);
        base.approve(address(orderBook), TOTAL_BASE);
        vm.prank(MAKER);
        vm.expectRevert(
            abi.encodeWithSelector(IBaseOrderBook.InvalidMinimumFillAmount.selector, TOTAL_BASE + 1, TOTAL_BASE)
        );
        orderBook.makeOrder(_makeParams(Side.SELL, TOTAL_BASE + 1));

        uint256 orderId = _makeOrder(Side.SELL, MINIMUM_FILL);
        vm.prank(MAKER);
        vm.expectRevert(
            abi.encodeWithSelector(IBaseOrderBook.InvalidMinimumFillAmount.selector, TOTAL_BASE + 1, TOTAL_BASE)
        );
        orderBook.amendOrder(_amendParams(orderId, TOTAL_BASE + 1));
    }

    function testZeroMinimumDisablesMinimumAtMakeAndAmend() public {
        uint256 orderId = _makeOrder(Side.SELL, 0);
        require(orderBook.getOrder(orderId).minimumFillBaseAmount == 0, "zero minimum not stored");

        vm.prank(MAKER);
        uint256 replacementId = orderBook.amendOrder(_amendParams(orderId, 0));
        require(orderBook.getOrder(replacementId).minimumFillBaseAmount == 0, "zero amended minimum not stored");
    }

    function testZeroMinimumAllowsSmallPartialAndDoesNotCancelSmallRemainder() public {
        uint256 orderId = _makeOrder(Side.SELL, 0);
        uint256 takenBase = TOTAL_BASE - 1;

        vm.prank(TAKER);
        quote.approve(address(orderBook), takenBase);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(orderId, takenBase));

        IBaseOrderBook.Order memory order = orderBook.getOrder(orderId);
        require(order.status == IBaseOrderBook.OrderStatus.OPEN, "zero-minimum remainder was cancelled");
        require(order.remainingBaseAmount == 1, "wrong base remainder");
        require(orderBook.remainingQuoteAmountOf(orderId) == 1, "wrong quote remainder");
        require(orderBook.escrowLiability(address(base)) == 1, "wrong remainder liability");
    }

    function testRejectsMinimumFulfillmentThatCanRoundToZeroQuote() public {
        vm.prank(MAKER);
        base.approve(address(orderBook), TOTAL_BASE);
        vm.prank(MAKER);
        vm.expectRevert(
            abi.encodeWithSelector(IBaseOrderBook.MinimumFillCannotProduceQuoteAmount.selector, 49, TOTAL_BASE, 2)
        );
        orderBook.makeOrder(
            IBaseOrderBook.MakeOrderParams({
                side: Side.SELL,
                totalBaseAmount: TOTAL_BASE,
                totalQuoteAmount: 2,
                minimumFillBaseAmount: 49,
                expiry: uint48(block.timestamp + 1 days)
            })
        );
    }

    function testRejectsPartialTakeBelowMinimumButPermitsFullFill() public {
        uint256 orderId = _makeOrder(Side.SELL, MINIMUM_FILL);

        vm.prank(TAKER);
        vm.expectRevert(
            abi.encodeWithSelector(IBaseOrderBook.TakeAmountBelowMinimum.selector, MINIMUM_FILL - 1, MINIMUM_FILL)
        );
        orderBook.quoteTakeOrder(orderId, MINIMUM_FILL - 1);

        vm.prank(TAKER);
        quote.approve(address(orderBook), TOTAL_QUOTE);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(orderId, TOTAL_BASE));
        require(orderBook.statusOf(orderId) == IBaseOrderBook.OrderStatus.FILLED, "full fill rejected");
    }

    function testSellDustRemainderIsCancelledRefundedAndEmitsLifecycleEvents() public {
        uint256 orderId = _makeOrder(Side.SELL, MINIMUM_FILL);
        uint256 takenBase = 80;
        uint256 cancelledBase = TOTAL_BASE - takenBase;

        vm.prank(TAKER);
        quote.approve(address(orderBook), takenBase);
        vm.expectEmit(true, true, true, true, address(orderBook));
        emit IBaseOrderBook.OrderTaken(orderId, TAKER, RECIPIENT, takenBase, takenBase, cancelledBase);
        vm.expectEmit(true, true, false, true, address(orderBook));
        emit IBaseOrderBook.OrderCancelled(orderId, MAKER);
        vm.expectEmit(true, true, true, true, address(orderBook));
        emit IBaseOrderBook.OrderRemainderCancelled(orderId, TAKER, MAKER, cancelledBase, cancelledBase);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(orderId, takenBase));

        IBaseOrderBook.Order memory order = orderBook.getOrder(orderId);
        require(order.status == IBaseOrderBook.OrderStatus.CANCELLED, "wrong dust status");
        require(order.remainingBaseAmount == cancelledBase, "historical base remainder lost");
        require(orderBook.remainingQuoteAmountOf(orderId) == 0, "quote remainder not cleared");
        require(orderBook.escrowLiability(address(base)) == 0, "base liability retained");
        require(base.balanceOf(MAKER) == TOTAL_BASE * 3 - takenBase, "maker dust was not refunded");
        require(quote.balanceOf(MAKER) == TOTAL_QUOTE * 3 + takenBase, "maker fill proceeds wrong");
        require(base.balanceOf(RECIPIENT) == takenBase, "taker settlement includes dust");
    }

    function testBuyDustRemainderIsCancelledAndRefundsQuoteEscrow() public {
        uint256 totalQuote = 200;
        vm.prank(MAKER);
        quote.approve(address(orderBook), totalQuote);
        vm.prank(MAKER);
        uint256 orderId = orderBook.makeOrder(
            IBaseOrderBook.MakeOrderParams({
                side: Side.BUY,
                totalBaseAmount: TOTAL_BASE,
                totalQuoteAmount: totalQuote,
                minimumFillBaseAmount: MINIMUM_FILL,
                expiry: uint48(block.timestamp + 1 days)
            })
        );
        uint256 takenBase = 80;
        uint256 takenQuote = 160;
        uint256 cancelledBase = TOTAL_BASE - takenBase;

        vm.prank(TAKER);
        base.approve(address(orderBook), takenBase);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(orderId, takenBase));

        IBaseOrderBook.Order memory order = orderBook.getOrder(orderId);
        require(order.status == IBaseOrderBook.OrderStatus.CANCELLED, "wrong dust status");
        require(order.remainingBaseAmount == cancelledBase, "historical base remainder lost");
        require(orderBook.remainingQuoteAmountOf(orderId) == 0, "quote escrow not cleared");
        require(orderBook.escrowLiability(address(quote)) == 0, "quote liability retained");
        require(quote.balanceOf(MAKER) == TOTAL_QUOTE * 3 - takenQuote, "maker quote dust was not refunded");
        require(base.balanceOf(MAKER) == TOTAL_BASE * 3 + takenBase, "maker base proceeds wrong");
        require(quote.balanceOf(RECIPIENT) == takenQuote, "taker output includes dust");
    }

    function testRemainderEqualToMinimumStaysOpenAndQuoteMatchesExecution() public {
        uint256 orderId = _makeOrder(Side.SELL, MINIMUM_FILL);
        uint256 takenBase = TOTAL_BASE - MINIMUM_FILL;
        vm.prank(TAKER);
        (Quote[] memory approvals, SettlementQuote memory settlement) =
            orderBook.quoteTakeOrder(orderId, takenBase, RECIPIENT);
        require(approvals[0].amount == takenBase, "quote approval mismatch");
        require(settlement.grossInputAmount == takenBase, "quote settlement mismatch");

        vm.prank(TAKER);
        quote.approve(address(orderBook), approvals[0].amount);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(orderId, takenBase));

        IBaseOrderBook.Order memory order = orderBook.getOrder(orderId);
        require(order.status == IBaseOrderBook.OrderStatus.OPEN, "minimum remainder was cancelled");
        require(order.remainingBaseAmount == MINIMUM_FILL, "minimum remainder changed");
        require(orderBook.remainingQuoteAmountOf(orderId) == MINIMUM_FILL, "quote remainder changed");
    }

    function testSellDustQuoteAndBpsFeesUseOnlyFilledPrincipal() public {
        BPSOrderBookFeeController feeController = new BPSOrderBookFeeController(
            FEE_BPS, FEE_BPS, FEE_BPS, FEE_BPS, TakerFeeToken.QUOTE, FEE_RECIPIENT, 1 days, address(this)
        );
        OrderBookWithFeeController feeOrderBook = new OrderBookWithFeeController(
            address(base), address(quote), address(this), feeController, FEE_BPS, FEE_BPS
        );
        uint256 takenBase = 80;
        uint256 expectedFeePerRole = 8;

        vm.prank(MAKER);
        base.approve(address(feeOrderBook), TOTAL_BASE);
        vm.prank(MAKER);
        uint256 orderId = feeOrderBook.makeOrder(_makeParams(Side.SELL, MINIMUM_FILL));

        vm.prank(TAKER);
        (Quote[] memory approvals, SettlementQuote memory settlement) =
            feeOrderBook.quoteTakeOrder(orderId, takenBase, RECIPIENT);
        require(approvals.length == 1, "wrong approval count");
        require(approvals[0].token == address(quote), "wrong approval token");
        require(approvals[0].amount == 88, "approval includes cancelled dust");
        require(settlement.grossInputAmount == takenBase, "wrong gross input");
        require(settlement.inputFeeAmount == expectedFeePerRole, "taker fee uses total order");
        require(settlement.totalInputAmount == 88, "wrong total input");
        require(settlement.netOutputAmount == takenBase, "wrong net output");
        require(settlement.makerFeeAmount == expectedFeePerRole, "maker fee uses total order");

        vm.prank(TAKER);
        quote.approve(address(feeOrderBook), approvals[0].amount);
        vm.prank(TAKER);
        feeOrderBook.takeOrder(_boundedTakeParams(orderId, takenBase, Side.SELL, settlement));

        require(feeOrderBook.statusOf(orderId) == IBaseOrderBook.OrderStatus.CANCELLED, "dust order stayed open");
        require(feeOrderBook.remainingQuoteAmountOf(orderId) == 0, "quote remainder retained");
        require(feeOrderBook.escrowLiability(address(base)) == 0, "dust liability retained");
        require(base.balanceOf(MAKER) == TOTAL_BASE * 3 - takenBase, "maker base dust not refunded");
        require(quote.balanceOf(MAKER) == TOTAL_QUOTE * 3 + 72, "wrong maker net proceeds");
        require(quote.balanceOf(TAKER) == TOTAL_QUOTE * 3 - 88, "wrong taker input");
        require(base.balanceOf(RECIPIENT) == takenBase, "wrong taker output");
        require(quote.balanceOf(FEE_RECIPIENT) == expectedFeePerRole * 2, "fees include cancelled dust");
        require(base.balanceOf(address(feeOrderBook)) == 0, "base remained in order book");
        require(quote.balanceOf(address(feeOrderBook)) == 0, "quote remained in order book");
    }

    function testBuyDustQuoteAndBpsFeesUseOnlyFilledPrincipal() public {
        BPSOrderBookFeeController feeController = new BPSOrderBookFeeController(
            FEE_BPS, FEE_BPS, FEE_BPS, FEE_BPS, TakerFeeToken.BASE, FEE_RECIPIENT, 1 days, address(this)
        );
        OrderBookWithFeeController feeOrderBook = new OrderBookWithFeeController(
            address(base), address(quote), address(this), feeController, FEE_BPS, FEE_BPS
        );
        uint256 totalQuote = 200;
        uint256 takenBase = 80;
        uint256 takenQuote = 160;
        uint256 expectedFeePerRole = 8;

        vm.prank(MAKER);
        quote.approve(address(feeOrderBook), totalQuote);
        vm.prank(MAKER);
        uint256 orderId = feeOrderBook.makeOrder(
            IBaseOrderBook.MakeOrderParams({
                side: Side.BUY,
                totalBaseAmount: TOTAL_BASE,
                totalQuoteAmount: totalQuote,
                minimumFillBaseAmount: MINIMUM_FILL,
                expiry: uint48(block.timestamp + 1 days)
            })
        );

        vm.prank(TAKER);
        (Quote[] memory approvals, SettlementQuote memory settlement) =
            feeOrderBook.quoteTakeOrder(orderId, takenBase, RECIPIENT);
        require(approvals.length == 1, "wrong approval count");
        require(approvals[0].token == address(base), "wrong approval token");
        require(approvals[0].amount == 88, "approval includes cancelled dust");
        require(settlement.grossInputAmount == takenBase, "wrong gross input");
        require(settlement.inputFeeAmount == expectedFeePerRole, "taker fee uses total order");
        require(settlement.totalInputAmount == 88, "wrong total input");
        require(settlement.grossOutputAmount == takenQuote, "wrong gross output");
        require(settlement.netOutputAmount == takenQuote, "wrong net output");
        require(settlement.makerFeeAmount == expectedFeePerRole, "maker fee uses total order");

        vm.prank(TAKER);
        base.approve(address(feeOrderBook), approvals[0].amount);
        vm.prank(TAKER);
        feeOrderBook.takeOrder(_boundedTakeParams(orderId, takenBase, Side.BUY, settlement));

        require(feeOrderBook.statusOf(orderId) == IBaseOrderBook.OrderStatus.CANCELLED, "dust order stayed open");
        require(feeOrderBook.remainingQuoteAmountOf(orderId) == 0, "quote remainder retained");
        require(feeOrderBook.escrowLiability(address(quote)) == 0, "dust liability retained");
        require(quote.balanceOf(MAKER) == TOTAL_QUOTE * 3 - takenQuote, "quote dust was not refunded");
        require(base.balanceOf(MAKER) == TOTAL_BASE * 3 + 72, "wrong maker net proceeds");
        require(base.balanceOf(TAKER) == TOTAL_BASE * 3 - 88, "wrong taker input");
        require(quote.balanceOf(RECIPIENT) == takenQuote, "wrong taker output");
        require(base.balanceOf(FEE_RECIPIENT) == expectedFeePerRole * 2, "fees include cancelled dust");
        require(base.balanceOf(address(feeOrderBook)) == 0, "base remained in order book");
        require(quote.balanceOf(address(feeOrderBook)) == 0, "quote remained in order book");
    }

    function testAmendmentStoresReplacementMinimumFulfillment() public {
        uint256 orderId = _makeOrder(Side.SELL, MINIMUM_FILL);
        vm.prank(MAKER);
        uint256 replacementId = orderBook.amendOrder(_amendParams(orderId, 40));
        require(orderBook.getOrder(replacementId).minimumFillBaseAmount == 40, "amended minimum not stored");
    }

    function testFuzzAcceptedFillNeverLeavesAnOpenOrderBelowMinimum(uint256 seed) public {
        uint256 orderId = _makeOrder(Side.SELL, MINIMUM_FILL);
        uint256 takenBase = MINIMUM_FILL + seed % (TOTAL_BASE - MINIMUM_FILL + 1);
        vm.prank(TAKER);
        quote.approve(address(orderBook), takenBase);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(orderId, takenBase));

        IBaseOrderBook.Order memory order = orderBook.getOrder(orderId);
        if (order.status == IBaseOrderBook.OrderStatus.OPEN) {
            require(order.remainingBaseAmount >= MINIMUM_FILL, "open order is dust");
            require(orderBook.remainingQuoteAmountOf(orderId) != 0, "open order lacks quote principal");
        } else {
            require(
                order.status == IBaseOrderBook.OrderStatus.FILLED
                    || order.status == IBaseOrderBook.OrderStatus.CANCELLED,
                "bad terminal status"
            );
            require(orderBook.remainingQuoteAmountOf(orderId) == 0, "closed order has quote liability");
        }
    }

    function testDifferentTokenDecimalsUseNativeBaseUnitsForMinimumAndDust() public {
        MockERC20Decimals decimalBase = new MockERC20Decimals("Ether", "ETH", 18);
        MockERC20Decimals decimalQuote = new MockERC20Decimals("USD Coin", "USDC", 6);
        OrderBookWithFeeController decimalOrderBook = new OrderBookWithFeeController(
            address(decimalBase), address(decimalQuote), address(this), new MockOrderBookFeeController(1 days), 100, 100
        );
        uint256 totalBaseAmount = 1e18;
        uint256 totalQuoteAmount = 2_500e6;
        uint256 minimumFillBaseAmount = 4e17;
        uint256 takenBaseAmount = 7e17;

        decimalBase.mint(MAKER, totalBaseAmount);
        decimalQuote.mint(TAKER, totalQuoteAmount);
        vm.prank(MAKER);
        decimalBase.approve(address(decimalOrderBook), totalBaseAmount);
        vm.prank(MAKER);
        uint256 orderId = decimalOrderBook.makeOrder(
            IBaseOrderBook.MakeOrderParams({
                side: Side.SELL,
                totalBaseAmount: totalBaseAmount,
                totalQuoteAmount: totalQuoteAmount,
                minimumFillBaseAmount: minimumFillBaseAmount,
                expiry: uint48(block.timestamp + 1 days)
            })
        );
        vm.prank(TAKER);
        decimalQuote.approve(address(decimalOrderBook), 1_750e6);
        vm.prank(TAKER);
        decimalOrderBook.takeOrder(_takeParams(orderId, takenBaseAmount));

        IBaseOrderBook.Order memory order = decimalOrderBook.getOrder(orderId);
        require(order.status == IBaseOrderBook.OrderStatus.CANCELLED, "decimal dust was not cancelled");
        require(order.remainingBaseAmount == 3e17, "wrong native base remainder");
        require(decimalBase.balanceOf(MAKER) == 3e17, "native base dust not refunded");
        require(decimalOrderBook.escrowLiability(address(decimalBase)) == 0, "decimal liability retained");
    }

    function _makeOrder(Side side, uint256 minimumFillBaseAmount) private returns (uint256 orderId) {
        MockERC20 escrowToken = side == Side.SELL ? base : quote;
        vm.prank(MAKER);
        escrowToken.approve(address(orderBook), TOTAL_BASE);
        vm.prank(MAKER);
        orderId = orderBook.makeOrder(_makeParams(side, minimumFillBaseAmount));
    }

    function _makeParams(Side side, uint256 minimumFillBaseAmount)
        private
        view
        returns (IBaseOrderBook.MakeOrderParams memory)
    {
        return IBaseOrderBook.MakeOrderParams({
            side: side,
            totalBaseAmount: TOTAL_BASE,
            totalQuoteAmount: TOTAL_QUOTE,
            minimumFillBaseAmount: minimumFillBaseAmount,
            expiry: uint48(block.timestamp + 1 days)
        });
    }

    function _amendParams(uint256 orderId, uint256 minimumFillBaseAmount)
        private
        view
        returns (IBaseOrderBook.AmendOrderParams memory)
    {
        return IBaseOrderBook.AmendOrderParams({
            orderId: orderId,
            expectedRemainingBaseAmount: TOTAL_BASE,
            newBaseAmount: TOTAL_BASE,
            newQuoteAmount: TOTAL_QUOTE,
            newMinimumFillBaseAmount: minimumFillBaseAmount,
            newExpiry: uint48(block.timestamp + 2 days)
        });
    }

    function _takeParams(uint256 orderId, uint256 baseAmount)
        private
        pure
        returns (IBaseOrderBook.TakeOrderParams memory)
    {
        return IBaseOrderBook.TakeOrderParams({
            orderId: orderId,
            baseAmount: baseAmount,
            recipient: RECIPIENT,
            maxBaseIn: type(uint256).max,
            maxQuoteIn: type(uint256).max,
            minBaseOut: 0,
            minQuoteOut: 0
        });
    }

    function _boundedTakeParams(uint256 orderId, uint256 baseAmount, Side side, SettlementQuote memory settlement)
        private
        pure
        returns (IBaseOrderBook.TakeOrderParams memory)
    {
        return IBaseOrderBook.TakeOrderParams({
            orderId: orderId,
            baseAmount: baseAmount,
            recipient: RECIPIENT,
            maxBaseIn: side == Side.BUY ? settlement.totalInputAmount : 0,
            maxQuoteIn: side == Side.SELL ? settlement.totalInputAmount : 0,
            minBaseOut: side == Side.SELL ? settlement.netOutputAmount : 0,
            minQuoteOut: side == Side.BUY ? settlement.netOutputAmount : 0
        });
    }
}
