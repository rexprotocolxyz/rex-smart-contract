// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {FeeQuote} from "../contracts/interfaces/FeeQuote.sol";
import {FeeRole} from "../contracts/interfaces/FeeRole.sol";
import {IBaseOrderBook} from "../contracts/interfaces/IBaseOrderBook.sol";
import {IOrderBookWithFee} from "../contracts/interfaces/IOrderBookWithFee.sol";
import {IOrderBookWithFeeController} from "../contracts/interfaces/IOrderBookWithFeeController.sol";
import {OrderBookWithFeeController} from "../contracts/OrderBookWithFeeController.sol";
import {Quote} from "../contracts/interfaces/Quote.sol";
import {SettlementQuote} from "../contracts/interfaces/SettlementQuote.sol";
import {Side} from "../contracts/interfaces/Side.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC20FeeOnTransfer} from "./mocks/MockERC20FeeOnTransfer.sol";
import {MockOrderBookFeeController} from "./mocks/MockOrderBookFeeController.sol";

interface Vm {
    function etch(address target, bytes calldata newRuntimeBytecode) external;
    function prank(address msgSender) external;
    function expectRevert(bytes calldata revertData) external;
    function warp(uint256 newTimestamp) external;
}

contract OrderBookFeeSettlementTest {
    Vm private constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant MAKER = address(0xA11CE);
    address private constant TAKER = address(0xB0B);
    address private constant RECIPIENT = address(0xCAFE);
    address private constant FEE_RECIPIENT = address(0xFEE);
    address private constant SECOND_FEE_RECIPIENT = address(0xFEE2);
    address private constant UNAUTHORIZED = address(0xBAD);
    address private constant BASE_TOKEN = 0xD8d3947a5E73d7C6e305875ddF809dcB90eabf95;
    address private constant QUOTE_TOKEN = 0x756EfF2C697835bE39ea6D4B897305A207374cBE;

    uint256 private constant BASE_TOTAL = 100e6;
    uint256 private constant QUOTE_TOTAL = 97e6;
    uint16 private constant MAXIMUM_MAKER_FEE_BPS = 100;
    uint16 private constant MAXIMUM_TAKER_FEE_BPS = 100;

    MockERC20 private base;
    MockERC20 private quote;
    MockOrderBookFeeController private feeController;
    OrderBookWithFeeController private orderBook;

    function setUp() public {
        MockERC20 runtimeSource = new MockERC20();
        vm.etch(BASE_TOKEN, address(runtimeSource).code);
        vm.etch(QUOTE_TOKEN, address(runtimeSource).code);

        base = MockERC20(BASE_TOKEN);
        quote = MockERC20(QUOTE_TOKEN);
        base.mint(MAKER, BASE_TOTAL);
        quote.mint(TAKER, QUOTE_TOTAL * 2);

        feeController = new MockOrderBookFeeController(1 days);
        orderBook = new OrderBookWithFeeController(
            BASE_TOKEN, QUOTE_TOKEN, address(this), feeController, MAXIMUM_MAKER_FEE_BPS, MAXIMUM_TAKER_FEE_BPS
        );
    }

    function testUsesLiveMockFeeForExistingOrder() public {
        uint256 orderId = _makeSellOrder();
        uint256 liveFeeAmount = 485_000;
        feeController.setQuotes(FeeRole.TAKER, _singleFeeQuote(QUOTE_TOKEN, FEE_RECIPIENT, liveFeeAmount));

        vm.prank(TAKER);
        (Quote[] memory takeQuotes,) = orderBook.quoteTakeOrder(orderId, BASE_TOTAL);
        _assertEq(takeQuotes[0].token, QUOTE_TOKEN);
        _assertEq(takeQuotes[0].amount, QUOTE_TOTAL + liveFeeAmount);

        vm.prank(TAKER);
        quote.approve(address(orderBook), takeQuotes[0].amount);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(orderId, takeQuotes[0].amount));

        _assertEq(quote.balanceOf(MAKER), QUOTE_TOTAL);
        _assertEq(quote.balanceOf(FEE_RECIPIENT), liveFeeAmount);
        _assertEq(base.balanceOf(RECIPIENT), BASE_TOTAL);
    }

    function testChargesLiveFeeIndependentlyForEachPartialFill() public {
        uint256 orderId = _makeSellOrder();
        uint256 feePerFill = 485_000;
        uint256 basePerFill = BASE_TOTAL / 2;
        uint256 quotePerFill = QUOTE_TOTAL / 2;
        feeController.setQuotes(FeeRole.TAKER, _singleFeeQuote(QUOTE_TOKEN, FEE_RECIPIENT, feePerFill));

        vm.prank(TAKER);
        quote.approve(address(orderBook), QUOTE_TOTAL + feePerFill * 2);

        for (uint256 i; i < 2; ++i) {
            vm.prank(TAKER);
            orderBook.takeOrder(
                IBaseOrderBook.TakeOrderParams({
                    orderId: orderId,
                    baseAmount: basePerFill,
                    recipient: RECIPIENT,
                    maxBaseIn: type(uint256).max,
                    maxQuoteIn: quotePerFill + feePerFill,
                    minBaseOut: 0,
                    minQuoteOut: 0
                })
            );
        }

        _assertEq(quote.balanceOf(MAKER), QUOTE_TOTAL);
        _assertEq(quote.balanceOf(FEE_RECIPIENT), feePerFill * 2);
        _assertEq(base.balanceOf(RECIPIENT), BASE_TOTAL);
    }

    function testAppliesMaximumFeeToCurrentFill() public {
        uint256 orderId = _makeSellOrder();
        uint256 baseAmount = 10_000;
        uint256 quoteAmount = 9_700;
        uint256 feeAmount = 100;
        uint256 maximumFeeAmount = 97;
        feeController.setQuotes(FeeRole.TAKER, _singleFeeQuote(QUOTE_TOKEN, FEE_RECIPIENT, feeAmount));

        vm.prank(TAKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderBookWithFee.FeeExceedsMaximum.selector, FeeRole.TAKER, QUOTE_TOKEN, feeAmount, maximumFeeAmount
            )
        );
        orderBook.quoteTakeOrder(orderId, baseAmount);

        _assertEq(quoteAmount * MAXIMUM_TAKER_FEE_BPS / 10_000, maximumFeeAmount);
    }

    function testExecutesScheduledFeeControllerUpdateAfterDelay() public {
        MockOrderBookFeeController replacement = new MockOrderBookFeeController(1 days);
        uint256 replacementFeeAmount = 485_000;
        replacement.setQuotes(FeeRole.TAKER, _singleFeeQuote(QUOTE_TOKEN, SECOND_FEE_RECIPIENT, replacementFeeAmount));

        orderBook.scheduleFeeControllerUpdate(replacement);
        _assertEq(address(orderBook.feeController()), address(feeController));
        _assertEq(address(orderBook.pendingFeeController()), address(replacement));

        vm.warp(block.timestamp + 1 days);
        orderBook.executeFeeControllerUpdate();

        _assertEq(address(orderBook.feeController()), address(replacement));
        _assertEq(address(orderBook.pendingFeeController()), address(0));
        uint256 orderId = _makeSellOrder();
        vm.prank(TAKER);
        (Quote[] memory takeQuotes,) = orderBook.quoteTakeOrder(orderId, BASE_TOTAL);
        _assertEq(takeQuotes[0].amount, QUOTE_TOTAL + replacementFeeAmount);

        vm.prank(TAKER);
        quote.approve(address(orderBook), takeQuotes[0].amount);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(orderId, takeQuotes[0].amount));
        _assertEq(quote.balanceOf(SECOND_FEE_RECIPIENT), replacementFeeAmount);
    }

    function testRecoversFromActiveControllerWithUnavailableDelay() public {
        MockOrderBookFeeController replacement = new MockOrderBookFeeController(2 days);
        feeController.setMinimumDelayUnavailable(true);

        _makeSellOrder();
        orderBook.scheduleFeeControllerUpdate(replacement);
        _assertEq(orderBook.feeControllerDelay(), 1 days);

        vm.warp(block.timestamp + 1 days);
        orderBook.executeFeeControllerUpdate();

        _assertEq(address(orderBook.feeController()), address(replacement));
        _assertEq(orderBook.feeControllerDelay(), 2 days);
    }

    function testRevalidatesPendingFeeControllerDuringExecution() public {
        MockOrderBookFeeController replacement = new MockOrderBookFeeController(2 days);
        orderBook.scheduleFeeControllerUpdate(replacement);
        replacement.setMinimumDelay(0);

        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderBookWithFeeController.FeeControllerHasNoTimelock.selector, address(replacement)
            )
        );
        orderBook.executeFeeControllerUpdate();

        _assertEq(address(orderBook.feeController()), address(feeController));
        _assertEq(address(orderBook.pendingFeeController()), address(replacement));
        replacement.setMinimumDelay(2 days);
        orderBook.executeFeeControllerUpdate();
        _assertEq(address(orderBook.feeController()), address(replacement));
        _assertEq(orderBook.feeControllerDelay(), 2 days);
    }

    function testOnlyOwnerCanScheduleFeeControllerUpdate() public {
        MockOrderBookFeeController replacement = new MockOrderBookFeeController(1 days);

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, UNAUTHORIZED));
        orderBook.scheduleFeeControllerUpdate(replacement);
    }

    function testRejectsMockFeeAboveMaximum() public {
        uint256 orderId = _makeSellOrder();
        feeController.setQuotes(FeeRole.TAKER, _singleFeeQuote(QUOTE_TOKEN, FEE_RECIPIENT, 970_001));

        vm.prank(TAKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderBookWithFee.FeeExceedsMaximum.selector, FeeRole.TAKER, QUOTE_TOKEN, 970_001, 970_000
            )
        );
        orderBook.quoteTakeOrder(orderId, BASE_TOTAL);
    }

    function testRejectsMakerFeeAboveMaximum() public {
        feeController.setQuotes(FeeRole.MAKER, _singleFeeQuote(QUOTE_TOKEN, FEE_RECIPIENT, 970_001));

        vm.prank(MAKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderBookWithFee.FeeExceedsMaximum.selector, FeeRole.MAKER, QUOTE_TOKEN, 970_001, 970_000
            )
        );
        orderBook.makeOrder(
            IBaseOrderBook.MakeOrderParams({
                side: Side.SELL,
                totalBaseAmount: BASE_TOTAL,
                totalQuoteAmount: QUOTE_TOTAL,
                minimumFillBaseAmount: 2,
                expiry: uint48(block.timestamp + 1 days)
            })
        );
    }

    function testAppliesMaximumFeeToAggregateControllerQuotes() public {
        uint256 orderId = _makeSellOrder();
        FeeQuote[] memory feeQuotes = new FeeQuote[](2);
        feeQuotes[0] = FeeQuote({token: QUOTE_TOKEN, recipient: FEE_RECIPIENT, amount: 500_000});
        feeQuotes[1] = FeeQuote({token: QUOTE_TOKEN, recipient: SECOND_FEE_RECIPIENT, amount: 470_001});
        feeController.setQuotes(FeeRole.TAKER, feeQuotes);

        vm.prank(TAKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderBookWithFee.FeeExceedsMaximum.selector, FeeRole.TAKER, QUOTE_TOKEN, 970_001, 970_000
            )
        );
        orderBook.quoteTakeOrder(orderId, BASE_TOTAL);
    }

    function testRejectsFeeInUnsupportedToken() public {
        uint256 orderId = _makeSellOrder();
        MockERC20 unsupportedToken = new MockERC20();
        feeController.setQuotes(FeeRole.TAKER, _singleFeeQuote(address(unsupportedToken), FEE_RECIPIENT, 1));

        vm.prank(TAKER);
        vm.expectRevert(
            abi.encodeWithSelector(IOrderBookWithFeeController.UnsupportedFeeToken.selector, address(unsupportedToken))
        );
        orderBook.quoteTakeOrder(orderId, BASE_TOTAL);
    }

    function testRejectsTaxedOutgoingTransferBeforeMinimumOutputCanBeBypassed() public {
        MockERC20 buyBase = new MockERC20();
        MockERC20FeeOnTransfer buyQuote = new MockERC20FeeOnTransfer();
        OrderBookWithFeeController taxedOrderBook = _deployOrderBook(address(buyBase), address(buyQuote));
        buyQuote.mint(MAKER, QUOTE_TOTAL);
        buyBase.mint(TAKER, BASE_TOTAL);
        uint256 orderId = _makeBuyOrderOn(taxedOrderBook, buyQuote);

        uint16 transferTaxBps = 1_000;
        uint256 receivedAmount = QUOTE_TOTAL - QUOTE_TOTAL * transferTaxBps / 10_000;
        buyQuote.setTransferTax(address(taxedOrderBook), transferTaxBps);
        vm.prank(TAKER);
        buyBase.approve(address(taxedOrderBook), BASE_TOTAL);

        vm.prank(TAKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBaseOrderBook.UnsupportedOutgoingTokenBehavior.selector,
                address(buyQuote),
                RECIPIENT,
                QUOTE_TOTAL,
                QUOTE_TOTAL,
                receivedAmount
            )
        );
        taxedOrderBook.takeOrder(
            IBaseOrderBook.TakeOrderParams({
                orderId: orderId,
                baseAmount: BASE_TOTAL,
                recipient: RECIPIENT,
                maxBaseIn: BASE_TOTAL,
                maxQuoteIn: 0,
                minBaseOut: 0,
                minQuoteOut: QUOTE_TOTAL
            })
        );

        _assertEq(buyQuote.balanceOf(RECIPIENT), 0);
        _assertEq(buyBase.balanceOf(TAKER), BASE_TOTAL);
        _assertEq(uint256(taxedOrderBook.statusOf(orderId)), uint256(IBaseOrderBook.OrderStatus.OPEN));
    }

    function testDeductsSellMakerFeeFromQuoteProceeds() public {
        uint256 makerFeeAmount = 970_000;
        feeController.setQuotes(FeeRole.MAKER, _singleFeeQuote(QUOTE_TOKEN, FEE_RECIPIENT, makerFeeAmount));

        uint256 orderId = _makeSellOrder();

        vm.prank(TAKER);
        quote.approve(address(orderBook), QUOTE_TOTAL);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(orderId, QUOTE_TOTAL));

        _assertEq(quote.balanceOf(MAKER), QUOTE_TOTAL - makerFeeAmount);
        _assertEq(quote.balanceOf(FEE_RECIPIENT), makerFeeAmount);
        _assertEq(base.balanceOf(RECIPIENT), BASE_TOTAL);
    }

    function testDeductsSellTakerBaseFeeFromOutput() public {
        uint256 takerFeeAmount = 1_000_000;
        feeController.setQuotes(FeeRole.TAKER, _singleFeeQuote(BASE_TOKEN, FEE_RECIPIENT, takerFeeAmount));
        uint256 orderId = _makeSellOrder();

        vm.prank(TAKER);
        (Quote[] memory approvals, SettlementQuote memory settlement) = orderBook.quoteTakeOrder(orderId, BASE_TOTAL);
        _assertEq(approvals[0].token, QUOTE_TOKEN);
        _assertEq(approvals[0].amount, QUOTE_TOTAL);
        _assertEq(settlement.outputFeeAmount, takerFeeAmount);
        _assertEq(settlement.netOutputAmount, BASE_TOTAL - takerFeeAmount);

        vm.prank(TAKER);
        quote.approve(address(orderBook), QUOTE_TOTAL);
        vm.prank(TAKER);
        orderBook.takeOrder(
            IBaseOrderBook.TakeOrderParams({
                orderId: orderId,
                baseAmount: BASE_TOTAL,
                recipient: RECIPIENT,
                maxBaseIn: type(uint256).max,
                maxQuoteIn: QUOTE_TOTAL,
                minBaseOut: BASE_TOTAL - takerFeeAmount,
                minQuoteOut: 0
            })
        );

        _assertEq(base.balanceOf(RECIPIENT), BASE_TOTAL - takerFeeAmount);
        _assertEq(base.balanceOf(FEE_RECIPIENT), takerFeeAmount);
        _assertEq(quote.balanceOf(MAKER), QUOTE_TOTAL);
    }

    function testAddsBuyTakerBaseFeeToInput() public {
        uint256 takerFeeAmount = 1_000_000;
        feeController.setQuotes(FeeRole.TAKER, _singleFeeQuote(BASE_TOKEN, FEE_RECIPIENT, takerFeeAmount));
        uint256 orderId = _makeBuyOrder(takerFeeAmount);

        vm.prank(TAKER);
        (Quote[] memory approvals, SettlementQuote memory settlement) = orderBook.quoteTakeOrder(orderId, BASE_TOTAL);
        _assertEq(approvals[0].token, BASE_TOKEN);
        _assertEq(approvals[0].amount, BASE_TOTAL + takerFeeAmount);
        _assertEq(settlement.inputFeeAmount, takerFeeAmount);
        _assertEq(settlement.totalInputAmount, BASE_TOTAL + takerFeeAmount);

        vm.prank(TAKER);
        base.approve(address(orderBook), BASE_TOTAL + takerFeeAmount);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeBuyParams(orderId, BASE_TOTAL + takerFeeAmount, QUOTE_TOTAL));

        _assertEq(base.balanceOf(MAKER), BASE_TOTAL * 2);
        _assertEq(base.balanceOf(FEE_RECIPIENT), takerFeeAmount);
        _assertEq(quote.balanceOf(RECIPIENT), QUOTE_TOTAL);
    }

    function testDeductsBuyTakerQuoteFeeFromOutput() public {
        uint256 takerFeeAmount = 970_000;
        feeController.setQuotes(FeeRole.TAKER, _singleFeeQuote(QUOTE_TOKEN, FEE_RECIPIENT, takerFeeAmount));
        uint256 orderId = _makeBuyOrder(0);

        vm.prank(TAKER);
        base.approve(address(orderBook), BASE_TOTAL);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeBuyParams(orderId, BASE_TOTAL, QUOTE_TOTAL - takerFeeAmount));

        _assertEq(base.balanceOf(MAKER), BASE_TOTAL * 2);
        _assertEq(quote.balanceOf(RECIPIENT), QUOTE_TOTAL - takerFeeAmount);
        _assertEq(quote.balanceOf(FEE_RECIPIENT), takerFeeAmount);
    }

    function testDeductsBuyMakerFeeFromBaseProceeds() public {
        uint256 makerFeeAmount = 1_000_000;
        feeController.setQuotes(FeeRole.MAKER, _singleFeeQuote(BASE_TOKEN, FEE_RECIPIENT, makerFeeAmount));
        uint256 orderId = _makeBuyOrder(0);

        vm.prank(TAKER);
        base.approve(address(orderBook), BASE_TOTAL);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeBuyParams(orderId, BASE_TOTAL, QUOTE_TOTAL));

        _assertEq(base.balanceOf(MAKER), BASE_TOTAL * 2 - makerFeeAmount);
        _assertEq(base.balanceOf(FEE_RECIPIENT), makerFeeAmount);
        _assertEq(quote.balanceOf(RECIPIENT), QUOTE_TOTAL);
    }

    function testRejectsMakerFeeInMakerInputToken() public {
        feeController.setQuotes(FeeRole.MAKER, _singleFeeQuote(BASE_TOKEN, FEE_RECIPIENT, 1));

        vm.prank(MAKER);
        base.approve(address(orderBook), BASE_TOTAL);
        vm.prank(MAKER);
        vm.expectRevert(
            abi.encodeWithSelector(IOrderBookWithFeeController.InvalidMakerFeeToken.selector, QUOTE_TOKEN, BASE_TOKEN)
        );
        orderBook.makeOrder(
            IBaseOrderBook.MakeOrderParams({
                side: Side.SELL,
                totalBaseAmount: BASE_TOTAL,
                totalQuoteAmount: QUOTE_TOTAL,
                minimumFillBaseAmount: 2,
                expiry: uint48(block.timestamp + 1 days)
            })
        );
    }

    function testRejectsMixedFeeTokensForOneRole() public {
        uint256 orderId = _makeSellOrder();
        FeeQuote[] memory feeQuotes = new FeeQuote[](2);
        feeQuotes[0] = FeeQuote({token: QUOTE_TOKEN, recipient: FEE_RECIPIENT, amount: 1});
        feeQuotes[1] = FeeQuote({token: BASE_TOKEN, recipient: SECOND_FEE_RECIPIENT, amount: 1});
        feeController.setQuotes(FeeRole.TAKER, feeQuotes);

        vm.prank(TAKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderBookWithFeeController.MixedFeeTokens.selector, FeeRole.TAKER, QUOTE_TOKEN, BASE_TOKEN
            )
        );
        orderBook.quoteTakeOrder(orderId, BASE_TOTAL);
    }

    function testEnforcesSellMinimumBaseOutput() public {
        uint256 takerFeeAmount = 1_000_000;
        feeController.setQuotes(FeeRole.TAKER, _singleFeeQuote(BASE_TOKEN, FEE_RECIPIENT, takerFeeAmount));
        uint256 orderId = _makeSellOrder();

        vm.prank(TAKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBaseOrderBook.BaseOutBelowMinimum.selector,
                BASE_TOTAL - takerFeeAmount,
                BASE_TOTAL - takerFeeAmount + 1
            )
        );
        orderBook.takeOrder(
            IBaseOrderBook.TakeOrderParams({
                orderId: orderId,
                baseAmount: BASE_TOTAL,
                recipient: RECIPIENT,
                maxBaseIn: type(uint256).max,
                maxQuoteIn: QUOTE_TOTAL,
                minBaseOut: BASE_TOTAL - takerFeeAmount + 1,
                minQuoteOut: 0
            })
        );
    }

    function testEnforcesSellMaximumQuoteInput() public {
        uint256 takerFeeAmount = 970_000;
        feeController.setQuotes(FeeRole.TAKER, _singleFeeQuote(QUOTE_TOKEN, FEE_RECIPIENT, takerFeeAmount));
        uint256 orderId = _makeSellOrder();

        vm.prank(TAKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBaseOrderBook.QuoteInExceedsMaximum.selector,
                QUOTE_TOTAL + takerFeeAmount,
                QUOTE_TOTAL + takerFeeAmount - 1
            )
        );
        orderBook.takeOrder(_takeParams(orderId, QUOTE_TOTAL + takerFeeAmount - 1));
    }

    function testEnforcesBuyMaximumBaseInput() public {
        uint256 takerFeeAmount = 1_000_000;
        feeController.setQuotes(FeeRole.TAKER, _singleFeeQuote(BASE_TOKEN, FEE_RECIPIENT, takerFeeAmount));
        uint256 orderId = _makeBuyOrder(takerFeeAmount);

        vm.prank(TAKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBaseOrderBook.BaseInExceedsMaximum.selector,
                BASE_TOTAL + takerFeeAmount,
                BASE_TOTAL + takerFeeAmount - 1
            )
        );
        orderBook.takeOrder(_takeBuyParams(orderId, BASE_TOTAL + takerFeeAmount - 1, 0));
    }

    function testEnforcesBuyMinimumQuoteOutput() public {
        uint256 takerFeeAmount = 970_000;
        feeController.setQuotes(FeeRole.TAKER, _singleFeeQuote(QUOTE_TOKEN, FEE_RECIPIENT, takerFeeAmount));
        uint256 orderId = _makeBuyOrder(0);

        vm.prank(TAKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBaseOrderBook.QuoteOutBelowMinimum.selector,
                QUOTE_TOTAL - takerFeeAmount,
                QUOTE_TOTAL - takerFeeAmount + 1
            )
        );
        orderBook.takeOrder(_takeBuyParams(orderId, BASE_TOTAL, QUOTE_TOTAL - takerFeeAmount + 1));
    }

    function testRoutesSplitFeesToControllerRecipients() public {
        uint256 orderId = _makeSellOrder();
        FeeQuote[] memory feeQuotes = new FeeQuote[](2);
        feeQuotes[0] = FeeQuote({token: QUOTE_TOKEN, recipient: FEE_RECIPIENT, amount: 200_000});
        feeQuotes[1] = FeeQuote({token: QUOTE_TOKEN, recipient: SECOND_FEE_RECIPIENT, amount: 285_000});
        feeController.setQuotes(FeeRole.TAKER, feeQuotes);

        vm.prank(TAKER);
        quote.approve(address(orderBook), QUOTE_TOTAL + 485_000);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(orderId, QUOTE_TOTAL + 485_000));

        _assertEq(quote.balanceOf(FEE_RECIPIENT), 200_000);
        _assertEq(quote.balanceOf(SECOND_FEE_RECIPIENT), 285_000);
        _assertEq(quote.balanceOf(MAKER), QUOTE_TOTAL);
    }

    function testAcceptsMaximumFeeQuotesPerRole() public {
        uint256 orderId = _makeSellOrder();
        uint256 maximumQuoteCount = orderBook.maximumFeeQuotesPerRole();
        FeeQuote[] memory makerFees = new FeeQuote[](maximumQuoteCount);
        FeeQuote[] memory takerFees = new FeeQuote[](maximumQuoteCount);
        for (uint256 i; i < maximumQuoteCount; ++i) {
            makerFees[i] = FeeQuote({token: QUOTE_TOKEN, recipient: FEE_RECIPIENT, amount: 1});
            takerFees[i] = FeeQuote({token: QUOTE_TOKEN, recipient: SECOND_FEE_RECIPIENT, amount: 1});
        }
        feeController.setQuotes(FeeRole.MAKER, makerFees);
        feeController.setQuotes(FeeRole.TAKER, takerFees);

        vm.prank(TAKER);
        quote.approve(address(orderBook), QUOTE_TOTAL + maximumQuoteCount);
        vm.prank(TAKER);
        orderBook.takeOrder(_takeParams(orderId, QUOTE_TOTAL + maximumQuoteCount));

        _assertEq(quote.balanceOf(MAKER), QUOTE_TOTAL - maximumQuoteCount);
        _assertEq(quote.balanceOf(FEE_RECIPIENT), maximumQuoteCount);
        _assertEq(quote.balanceOf(SECOND_FEE_RECIPIENT), maximumQuoteCount);
    }

    function testRejectsFeeQuotesAboveMaximum() public {
        uint256 orderId = _makeSellOrder();
        uint256 maximumQuoteCount = orderBook.maximumFeeQuotesPerRole();
        FeeQuote[] memory feeQuotes = new FeeQuote[](maximumQuoteCount + 1);
        for (uint256 i; i < feeQuotes.length; ++i) {
            feeQuotes[i] = FeeQuote({token: QUOTE_TOKEN, recipient: FEE_RECIPIENT, amount: 0});
        }
        feeController.setQuotes(FeeRole.TAKER, feeQuotes);

        vm.prank(TAKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderBookWithFeeController.TooManyFeeQuotes.selector,
                FeeRole.TAKER,
                maximumQuoteCount + 1,
                maximumQuoteCount
            )
        );
        orderBook.quoteTakeOrder(orderId, BASE_TOTAL);
    }

    function testRejectsInvalidControllerFeeRecipient() public {
        uint256 orderId = _makeSellOrder();
        feeController.setQuotes(FeeRole.TAKER, _singleFeeQuote(QUOTE_TOKEN, address(0), 1));

        vm.prank(TAKER);
        vm.expectRevert(abi.encodeWithSelector(IOrderBookWithFeeController.InvalidFeeRecipient.selector, address(0)));
        orderBook.quoteTakeOrder(orderId, BASE_TOTAL);

        feeController.setQuotes(FeeRole.TAKER, _singleFeeQuote(QUOTE_TOKEN, address(orderBook), 1));
        vm.prank(TAKER);
        vm.expectRevert(
            abi.encodeWithSelector(IOrderBookWithFeeController.InvalidFeeRecipient.selector, address(orderBook))
        );
        orderBook.quoteTakeOrder(orderId, BASE_TOTAL);
    }

    function _makeSellOrder() private returns (uint256 orderId) {
        vm.prank(MAKER);
        IERC20(BASE_TOKEN).approve(address(orderBook), BASE_TOTAL);
        vm.prank(MAKER);
        orderId = orderBook.makeOrder(
            IBaseOrderBook.MakeOrderParams({
                side: Side.SELL,
                totalBaseAmount: BASE_TOTAL,
                totalQuoteAmount: QUOTE_TOTAL,
                minimumFillBaseAmount: 2,
                expiry: uint48(block.timestamp + 1 days)
            })
        );
    }

    function _makeBuyOrder(uint256 additionalTakerBase) private returns (uint256 orderId) {
        quote.mint(MAKER, QUOTE_TOTAL);
        base.mint(TAKER, BASE_TOTAL + additionalTakerBase);
        vm.prank(MAKER);
        quote.approve(address(orderBook), QUOTE_TOTAL);
        vm.prank(MAKER);
        orderId = orderBook.makeOrder(
            IBaseOrderBook.MakeOrderParams({
                side: Side.BUY,
                totalBaseAmount: BASE_TOTAL,
                totalQuoteAmount: QUOTE_TOTAL,
                minimumFillBaseAmount: 2,
                expiry: uint48(block.timestamp + 1 days)
            })
        );
    }

    function _deployOrderBook(address baseToken, address quoteToken)
        private
        returns (OrderBookWithFeeController deployed)
    {
        deployed = new OrderBookWithFeeController(
            baseToken, quoteToken, address(this), feeController, MAXIMUM_MAKER_FEE_BPS, MAXIMUM_TAKER_FEE_BPS
        );
    }

    function _makeBuyOrderOn(OrderBookWithFeeController targetOrderBook, IERC20 buyQuote)
        private
        returns (uint256 orderId)
    {
        vm.prank(MAKER);
        buyQuote.approve(address(targetOrderBook), QUOTE_TOTAL);
        vm.prank(MAKER);
        orderId = targetOrderBook.makeOrder(
            IBaseOrderBook.MakeOrderParams({
                side: Side.BUY,
                totalBaseAmount: BASE_TOTAL,
                totalQuoteAmount: QUOTE_TOTAL,
                minimumFillBaseAmount: 2,
                expiry: uint48(block.timestamp + 1 days)
            })
        );
    }

    function _takeParams(uint256 orderId, uint256 maxQuoteIn)
        private
        pure
        returns (IBaseOrderBook.TakeOrderParams memory params)
    {
        params = IBaseOrderBook.TakeOrderParams({
            orderId: orderId,
            baseAmount: BASE_TOTAL,
            recipient: RECIPIENT,
            maxBaseIn: type(uint256).max,
            maxQuoteIn: maxQuoteIn,
            minBaseOut: 0,
            minQuoteOut: 0
        });
    }

    function _takeBuyParams(uint256 orderId, uint256 maxBaseIn, uint256 minQuoteOut)
        private
        pure
        returns (IBaseOrderBook.TakeOrderParams memory params)
    {
        params = IBaseOrderBook.TakeOrderParams({
            orderId: orderId,
            baseAmount: BASE_TOTAL,
            recipient: RECIPIENT,
            maxBaseIn: maxBaseIn,
            maxQuoteIn: type(uint256).max,
            minBaseOut: 0,
            minQuoteOut: minQuoteOut
        });
    }

    function _singleFeeQuote(address token, address recipient, uint256 amount)
        private
        pure
        returns (FeeQuote[] memory quotes)
    {
        quotes = new FeeQuote[](1);
        quotes[0] = FeeQuote({token: token, recipient: recipient, amount: amount});
    }

    function _assertEq(uint256 actual, uint256 expected) private pure {
        require(actual == expected, "uint mismatch");
    }

    function _assertEq(address actual, address expected) private pure {
        require(actual == expected, "address mismatch");
    }
}
