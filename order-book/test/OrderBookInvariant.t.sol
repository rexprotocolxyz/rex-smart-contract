// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {BPSOrderBookFeeController} from "../contracts/BPSOrderBookFeeController.sol";
import {IBaseOrderBook} from "../contracts/interfaces/IBaseOrderBook.sol";
import {OrderBookWithFeeController} from "../contracts/OrderBookWithFeeController.sol";
import {Side} from "../contracts/interfaces/Side.sol";
import {TakerFeeToken} from "../contracts/interfaces/TakerFeeToken.sol";
import {OrderBookGovernanceHandler} from "./handlers/OrderBookGovernanceHandler.sol";
import {OrderBookTradingHandler} from "./handlers/OrderBookTradingHandler.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Stateful invariant suite for order-book accounting, lifecycle, and fee-controller transitions.
/// @dev Foundry repeatedly calls randomized functions on the handlers returned by `targetContracts()`, then checks every
///      `invariant_*` function. Guide: https://www.getfoundry.sh/guides/invariant-testing
contract OrderBookInvariantTest {
    address private constant OWNER = address(0x0A11CE);
    address private constant FEE_RECIPIENT_A = address(0xFEEA);
    address private constant FEE_RECIPIENT_B = address(0xFEEB);
    uint256 private constant EXPECTED_MINIMUM_LEGACY_MODE_DELAY = 7 days;

    MockERC20 private base;
    MockERC20 private quote;
    OrderBookWithFeeController private orderBook;
    BPSOrderBookFeeController private controllerA;
    BPSOrderBookFeeController private controllerB;
    OrderBookGovernanceHandler private governanceHandler;
    OrderBookTradingHandler private tradingHandler;
    address[] private _targetedContracts;

    function setUp() public {
        base = new MockERC20();
        quote = new MockERC20();
        controllerA =
            new BPSOrderBookFeeController(25, 50, 100, 100, TakerFeeToken.QUOTE, FEE_RECIPIENT_A, 1 days, OWNER);
        controllerB =
            new BPSOrderBookFeeController(75, 100, 100, 100, TakerFeeToken.BASE, FEE_RECIPIENT_B, 1 days, OWNER);
        orderBook = new OrderBookWithFeeController(address(base), address(quote), OWNER, controllerA, 100, 100);
        tradingHandler = new OrderBookTradingHandler(orderBook, base, quote);
        governanceHandler = new OrderBookGovernanceHandler(orderBook, controllerA, controllerB);
        _targetedContracts.push(address(tradingHandler));
        _targetedContracts.push(address(governanceHandler));
    }

    function targetContracts() external view returns (address[] memory targetedContracts_) {
        return _targetedContracts;
    }

    function invariant_escrowBalancesEqualOpenOrderLiabilities() public view {
        (uint256 baseLiability, uint256 quoteLiability) = _liabilities();
        require(base.balanceOf(address(orderBook)) == baseLiability, "base liability mismatch");
        require(quote.balanceOf(address(orderBook)) == quoteLiability, "quote liability mismatch");
        require(orderBook.escrowLiability(address(base)) == baseLiability, "tracked base liability mismatch");
        require(orderBook.escrowLiability(address(quote)) == quoteLiability, "tracked quote liability mismatch");
    }

    function invariant_allocatedOrderIdsAreSequential() public view {
        uint256 count = orderBook.orderCount();
        for (uint256 orderId = 1; orderId <= count; ++orderId) {
            require(orderBook.getOrder(orderId).id == orderId, "non-sequential order id");
        }
    }

    function invariant_feeControllerIsValidated() public view {
        address activeController = address(orderBook.feeController());
        require(
            activeController == address(controllerA) || activeController == address(controllerB),
            "unexpected active controller"
        );
        require(orderBook.feeControllerDelay() == 1 days, "cached controller delay mismatch");

        address pendingController = address(orderBook.pendingFeeController());
        if (pendingController != address(0)) {
            require(
                pendingController == address(controllerA) || pendingController == address(controllerB),
                "unexpected pending controller"
            );
            require(pendingController != activeController, "active controller rescheduled");
        }
    }

    function invariant_expiryAndFinalizationPreserveOrderState() public view {
        uint256 count = orderBook.orderCount();
        for (uint256 orderId = 1; orderId <= count; ++orderId) {
            IBaseOrderBook.Order memory order = orderBook.getOrder(orderId);
            uint256 remainingQuoteAmount = orderBook.remainingQuoteAmountOf(orderId);
            require(orderBook.statusOf(orderId) == order.status, "status getter mismatch");

            if (order.status == IBaseOrderBook.OrderStatus.OPEN) {
                require(block.timestamp < order.expiry, "open order passed expiry");
                require(remainingQuoteAmount != 0, "open order lost quote liability");
                require(
                    order.remainingBaseAmount >= order.minimumFillBaseAmount, "open order is below minimum fulfillment"
                );
            } else if (order.status == IBaseOrderBook.OrderStatus.EXPIRED) {
                require(block.timestamp >= order.expiry, "order expired before deadline");
            } else {
                require(remainingQuoteAmount == 0, "closed order retained quote liability");
            }
        }
    }

    function invariant_legacyModeLifecycleIsConsistent() public view {
        require(
            orderBook.minimumLegacyModeDelay() == EXPECTED_MINIMUM_LEGACY_MODE_DELAY,
            "unexpected minimum legacy mode delay"
        );
        require(!governanceHandler.legacyModeActivatedBeforeDeadline(), "legacy mode activated before deadline");
        require(!governanceHandler.legacyModeActivatedWithoutSchedule(), "legacy mode activated without schedule");

        bool legacyModeEverEntered = governanceHandler.legacyModeEverEntered();
        if (legacyModeEverEntered) {
            uint48 executionDeadline = governanceHandler.legacyModeDeadlineAtExecution();
            require(orderBook.legacyMode(), "legacy mode was reversed");
            require(executionDeadline != 0, "legacy execution lacked recorded deadline");
            require(block.timestamp >= executionDeadline, "legacy mode active before recorded deadline");
            require(orderBook.legacyModeActivationTime() == 0, "executed legacy schedule retained deadline");
            require(
                orderBook.orderCount() == governanceHandler.orderCountAtLegacyModeActivation(),
                "order count increased after legacy activation"
            );
            return;
        }

        require(!orderBook.legacyMode(), "unobserved legacy mode activation");
        require(
            orderBook.legacyModeActivationTime() == governanceHandler.expectedLegacyModeActivationTime(),
            "legacy schedule diverged from ghost model"
        );
    }

    function _liabilities() private view returns (uint256 baseLiability, uint256 quoteLiability) {
        uint256 count = orderBook.orderCount();
        for (uint256 orderId = 1; orderId <= count; ++orderId) {
            IBaseOrderBook.Order memory order = orderBook.getOrder(orderId);
            uint256 trackedRemainingQuoteAmount = orderBook.remainingQuoteAmountOf(orderId);
            bool hasEscrow = order.status == IBaseOrderBook.OrderStatus.OPEN
                || (order.status == IBaseOrderBook.OrderStatus.EXPIRED && trackedRemainingQuoteAmount != 0);
            if (!hasEscrow) continue;
            uint256 filledBaseAmount = order.totalBaseAmount - order.remainingBaseAmount;
            Math.Rounding rounding = order.side == Side.SELL ? Math.Rounding.Ceil : Math.Rounding.Floor;
            uint256 filledQuoteAmount =
                Math.mulDiv(filledBaseAmount, order.totalQuoteAmount, order.totalBaseAmount, rounding);
            uint256 remainingQuoteAmount = order.totalQuoteAmount - filledQuoteAmount;
            require(trackedRemainingQuoteAmount == remainingQuoteAmount, "tracked quote remainder mismatch");
            if (order.side == Side.SELL) {
                baseLiability += order.remainingBaseAmount;
            } else {
                quoteLiability += remainingQuoteAmount;
            }
        }
    }
}
