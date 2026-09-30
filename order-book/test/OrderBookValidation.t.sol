// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IBaseOrderBook} from "../contracts/interfaces/IBaseOrderBook.sol";
import {IGovernedOrderBookFeeController} from "../contracts/interfaces/IGovernedOrderBookFeeController.sol";
import {IOrderBookAdministration} from "../contracts/interfaces/IOrderBookAdministration.sol";
import {IOrderBookWithFee} from "../contracts/interfaces/IOrderBookWithFee.sol";
import {IOrderBookWithFeeController} from "../contracts/interfaces/IOrderBookWithFeeController.sol";
import {OrderBookWithFeeController} from "../contracts/OrderBookWithFeeController.sol";
import {Side} from "../contracts/interfaces/Side.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC20FeeOnTransfer} from "./mocks/MockERC20FeeOnTransfer.sol";
import {MockOrderBookFeeController} from "./mocks/MockOrderBookFeeController.sol";

interface VmValidation {
    function prank(address msgSender) external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function warp(uint256 newTimestamp) external;
}

contract OrderBookValidationTest {
    VmValidation private constant vm = VmValidation(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant MAKER = address(0xA11CE);
    address private constant TAKER = address(0xB0B);
    address private constant RECIPIENT = address(0xCAFE);
    address private constant EOA = address(0xBEEF);
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
        orderBook = _deploy(address(base), address(quote), feeController, 100, 100);
        base.mint(MAKER, BASE_TOTAL * 2);
        quote.mint(MAKER, QUOTE_TOTAL * 2);
        base.mint(TAKER, BASE_TOTAL * 2);
        quote.mint(TAKER, QUOTE_TOTAL * 2);
    }

    function testRejectsInvalidConstructorConfiguration() public {
        vm.expectRevert(IBaseOrderBook.ZeroAddress.selector);
        _deploy(address(0), address(quote), feeController, 100, 100);

        vm.expectRevert(abi.encodeWithSelector(IBaseOrderBook.IdenticalTokens.selector, address(base)));
        _deploy(address(base), address(base), feeController, 100, 100);

        vm.expectRevert(abi.encodeWithSelector(IOrderBookWithFee.InvalidMaximumMakerFeeBps.selector, 10_000));
        _deploy(address(base), address(quote), feeController, 10_000, 100);

        vm.expectRevert(abi.encodeWithSelector(IOrderBookWithFee.InvalidMaximumTakerFeeBps.selector, 10_000));
        _deploy(address(base), address(quote), feeController, 100, 10_000);

        vm.expectRevert(abi.encodeWithSelector(IBaseOrderBook.TokenIsNotContract.selector, EOA));
        _deploy(EOA, address(quote), feeController, 100, 100);
    }

    function testRejectsInvalidFeeControllerAndUnauthorisedPause() public {
        vm.expectRevert(IBaseOrderBook.ZeroAddress.selector);
        _deploy(address(base), address(quote), IGovernedOrderBookFeeController(address(0)), 100, 100);

        vm.expectRevert(abi.encodeWithSelector(IOrderBookWithFeeController.FeeControllerIsNotContract.selector, EOA));
        orderBook.scheduleFeeControllerUpdate(IGovernedOrderBookFeeController(EOA));

        vm.prank(EOA);
        vm.expectRevert(abi.encodeWithSelector(IOrderBookAdministration.UnauthorizedPauseCaller.selector, EOA));
        orderBook.pause();
    }

    function testRejectsFeeControllerDelayOutsideBounds() public {
        MockOrderBookFeeController shortDelayController =
            new MockOrderBookFeeController(orderBook.minimumFeeControllerDelay() - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderBookWithFeeController.FeeControllerDelayOutOfBounds.selector,
                address(shortDelayController),
                orderBook.minimumFeeControllerDelay() - 1,
                orderBook.minimumFeeControllerDelay(),
                orderBook.maximumFeeControllerDelay()
            )
        );
        _deploy(address(base), address(quote), shortDelayController, 100, 100);

        MockOrderBookFeeController longDelayController =
            new MockOrderBookFeeController(orderBook.maximumFeeControllerDelay() + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderBookWithFeeController.FeeControllerDelayOutOfBounds.selector,
                address(longDelayController),
                orderBook.maximumFeeControllerDelay() + 1,
                orderBook.minimumFeeControllerDelay(),
                orderBook.maximumFeeControllerDelay()
            )
        );
        orderBook.scheduleFeeControllerUpdate(longDelayController);
    }

    function testAcceptsFeeControllerDelayBounds() public {
        MockOrderBookFeeController minimumDelayController =
            new MockOrderBookFeeController(orderBook.minimumFeeControllerDelay());
        OrderBookWithFeeController minimumDelayOrderBook =
            _deploy(address(base), address(quote), minimumDelayController, 100, 100);
        require(
            minimumDelayOrderBook.feeControllerDelay() == minimumDelayOrderBook.minimumFeeControllerDelay(),
            "minimum delay rejected"
        );

        MockOrderBookFeeController maximumDelayController =
            new MockOrderBookFeeController(orderBook.maximumFeeControllerDelay());
        orderBook.scheduleFeeControllerUpdate(maximumDelayController);
        require(address(orderBook.pendingFeeController()) == address(maximumDelayController), "maximum delay rejected");
    }

    function testFeeControllerUpdateRequiresDelayAndCanBeCancelled() public {
        MockOrderBookFeeController replacement = new MockOrderBookFeeController(1 days);

        vm.expectRevert(IOrderBookWithFeeController.NoFeeControllerUpdateScheduled.selector);
        orderBook.executeFeeControllerUpdate();

        orderBook.scheduleFeeControllerUpdate(replacement);
        uint48 executeAfter = orderBook.feeControllerUpdateTime();
        require(address(orderBook.pendingFeeController()) == address(replacement), "pending controller mismatch");

        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderBookWithFeeController.FeeControllerUpdateNotReady.selector, executeAfter, block.timestamp
            )
        );
        orderBook.executeFeeControllerUpdate();

        orderBook.cancelFeeControllerUpdate();
        require(address(orderBook.pendingFeeController()) == address(0), "pending controller not cleared");

        vm.expectRevert(IOrderBookWithFeeController.NoFeeControllerUpdateScheduled.selector);
        orderBook.executeFeeControllerUpdate();
    }

    function testRejectsTaxedEscrowInput() public {
        MockERC20FeeOnTransfer taxedBase = new MockERC20FeeOnTransfer();
        OrderBookWithFeeController taxedOrderBook = _deploy(address(taxedBase), address(quote), feeController, 100, 100);
        taxedBase.mint(MAKER, BASE_TOTAL);
        taxedBase.setTransferTax(MAKER, 1_000);
        vm.prank(MAKER);
        taxedBase.approve(address(taxedOrderBook), BASE_TOTAL);

        vm.prank(MAKER);
        vm.expectRevert(
            abi.encodeWithSelector(
                IBaseOrderBook.UnsupportedTokenBehavior.selector, address(taxedBase), BASE_TOTAL, BASE_TOTAL * 9 / 10
            )
        );
        taxedOrderBook.makeOrder(_makeParams(Side.SELL, BASE_TOTAL, QUOTE_TOTAL));
    }

    function testRejectsInvalidTakeRequests() public {
        uint256 orderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL);

        vm.prank(TAKER);
        vm.expectRevert(IBaseOrderBook.ZeroAddress.selector);
        orderBook.takeOrder(_takeParams(orderId, 1, address(0)));

        vm.prank(MAKER);
        vm.expectRevert(abi.encodeWithSelector(IBaseOrderBook.MakerCannotTakeOwnOrder.selector, orderId));
        orderBook.quoteTakeOrder(orderId, 1);

        vm.prank(TAKER);
        vm.expectRevert(abi.encodeWithSelector(IBaseOrderBook.InvalidTakeAmount.selector, 0, BASE_TOTAL));
        orderBook.quoteTakeOrder(orderId, 0);
    }

    function testCancellationExpiryAndPaginationBoundaries() public {
        require(orderBook.statusOf(999) == IBaseOrderBook.OrderStatus.NONE, "unknown status mismatch");
        vm.expectRevert(abi.encodeWithSelector(IBaseOrderBook.OrderNotFound.selector, 999));
        orderBook.remainingQuoteAmountOf(999);
        require(orderBook.escrowLiability(EOA) == 0, "unexpected liability");

        vm.expectRevert(abi.encodeWithSelector(IBaseOrderBook.InvalidPageSize.selector, 0, 100));
        orderBook.getOrders(0, 0);

        uint256 orderId = _makeSellOrder(BASE_TOTAL, QUOTE_TOTAL);
        vm.prank(TAKER);
        vm.expectRevert(abi.encodeWithSelector(IBaseOrderBook.NotOrderMaker.selector, orderId, TAKER));
        orderBook.cancelOrder(orderId);

        vm.warp(block.timestamp + 1 days);
        vm.prank(TAKER);
        vm.expectRevert(abi.encodeWithSelector(IBaseOrderBook.OrderExpired.selector, orderId));
        orderBook.quoteTakeOrder(orderId, 1);
        orderBook.sweepExpiredOrder(orderId);

        require(orderBook.statusOf(orderId) == IBaseOrderBook.OrderStatus.EXPIRED, "expiry sweep failed");
    }

    function _deploy(
        address baseToken,
        address quoteToken,
        IGovernedOrderBookFeeController controller,
        uint16 maximumMakerFeeBps,
        uint16 maximumTakerFeeBps
    ) private returns (OrderBookWithFeeController deployed) {
        deployed = new OrderBookWithFeeController(
            baseToken, quoteToken, address(this), controller, maximumMakerFeeBps, maximumTakerFeeBps
        );
    }

    function _makeSellOrder(uint256 baseAmount, uint256 quoteAmount) private returns (uint256 orderId) {
        vm.prank(MAKER);
        base.approve(address(orderBook), baseAmount);
        vm.prank(MAKER);
        orderId = orderBook.makeOrder(_makeParams(Side.SELL, baseAmount, quoteAmount));
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

    function _takeParams(uint256 orderId, uint256 baseAmount, address recipient)
        private
        pure
        returns (IBaseOrderBook.TakeOrderParams memory)
    {
        return IBaseOrderBook.TakeOrderParams({
            orderId: orderId,
            baseAmount: baseAmount,
            recipient: recipient,
            maxBaseIn: type(uint256).max,
            maxQuoteIn: type(uint256).max,
            minBaseOut: 0,
            minQuoteOut: 0
        });
    }
}
