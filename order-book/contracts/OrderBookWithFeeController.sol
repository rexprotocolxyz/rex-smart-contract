// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";

import {MINIMUM_FEE_CONTROLLER_DELAY, MAXIMUM_FEE_CONTROLLER_DELAY} from "./FeeControllerDelayBounds.sol";
import {IGovernedOrderBookFeeController} from "./interfaces/IGovernedOrderBookFeeController.sol";
import {IOrderBookFeeController} from "./interfaces/IOrderBookFeeController.sol";
import {IFeeControllerTimelock} from "./interfaces/IFeeControllerTimelock.sol";
import {IFeeControllerFeeCaps} from "./interfaces/IFeeControllerFeeCaps.sol";
import {IOrderBookWithFeeController} from "./interfaces/IOrderBookWithFeeController.sol";
import {IOrderBookAdministration} from "./interfaces/IOrderBookAdministration.sol";
import {FeeQuote} from "./interfaces/FeeQuote.sol";
import {FeeRole} from "./interfaces/FeeRole.sol";
import {Quote} from "./interfaces/Quote.sol";
import {SettlementQuote} from "./interfaces/SettlementQuote.sol";
import {Side} from "./interfaces/Side.sol";

/// @dev Supports controller-configured maker and taker fees in the pair's base or quote token.
contract OrderBookWithFeeController is
    IOrderBookWithFeeController,
    IOrderBookAdministration,
    Ownable2Step,
    Pausable,
    ReentrancyGuard
{
    using SafeERC20 for IERC20;

    // Used only to enforce this order book's immutable fee caps; controllers return final token amounts.
    uint256 private constant BPS_DENOMINATOR = 10_000;

    address public immutable override baseToken;
    address public immutable override quoteToken;
    uint256 public constant override maximumPageSize = 100;
    uint256 public constant override maximumSweepBatchSize = 100;
    uint256 public constant override minimumLegacyModeDelay = 7 days;

    uint16 public immutable override maximumMakerFeeBps;
    uint16 public immutable override maximumTakerFeeBps;
    uint256 public constant override maximumFeeQuotesPerRole = 8;
    uint256 public constant override minimumFeeControllerDelay = MINIMUM_FEE_CONTROLLER_DELAY;
    uint256 public constant override maximumFeeControllerDelay = MAXIMUM_FEE_CONTROLLER_DELAY;
    IGovernedOrderBookFeeController public override feeController;
    uint256 public override feeControllerDelay;
    IGovernedOrderBookFeeController public override pendingFeeController;
    uint48 public override feeControllerUpdateTime;
    address public override pauseGuardian;
    uint256 public override orderCount;
    uint48 public override legacyModeActivationTime;
    bool public override legacyMode;

    mapping(uint256 orderId => Order order) private _orders;
    mapping(uint256 orderId => uint256 amount) private _remainingQuoteAmount;
    mapping(address token => uint256 amount) private _escrowLiability;
    mapping(address account => mapping(address token => uint256 amount)) private _claimableRefund;

    struct FeeSet {
        FeeQuote[] makerFees;
        FeeQuote[] takerFees;
        address makerFeeToken;
        address takerFeeToken;
        uint256 makerFeeAmount;
        uint256 takerFeeAmount;
    }

    struct SettlementData {
        FeeSet fees;
        uint256 quoteAmount;
        uint256 takerInputFeeAmount;
        uint256 takerOutputFeeAmount;
        uint256 remainingBaseAmount;
        uint256 remainingQuoteAmount;
        bool cancelRemainder;
    }

    error OwnershipRenunciationDisabled();

    modifier whenNotInLegacyMode() {
        if (legacyMode) revert OrderBookInLegacyMode();
        _;
    }

    constructor(
        address baseToken_,
        address quoteToken_,
        address owner_,
        IGovernedOrderBookFeeController feeController_,
        uint16 maximumMakerFeeBps_,
        uint16 maximumTakerFeeBps_
    ) Ownable(owner_) {
        address feeControllerAddress = address(feeController_);
        if (baseToken_ == address(0) || quoteToken_ == address(0) || owner_ == address(0) || owner_ == address(this)) {
            revert ZeroAddress();
        }
        if (baseToken_ == quoteToken_) revert IdenticalTokens(baseToken_);
        if (maximumMakerFeeBps_ >= BPS_DENOMINATOR) {
            revert InvalidMaximumMakerFeeBps(maximumMakerFeeBps_);
        }
        if (maximumTakerFeeBps_ >= BPS_DENOMINATOR) {
            revert InvalidMaximumTakerFeeBps(maximumTakerFeeBps_);
        }
        if (baseToken_.code.length == 0) revert TokenIsNotContract(baseToken_);
        if (quoteToken_.code.length == 0) revert TokenIsNotContract(quoteToken_);
        uint256 initialFeeControllerDelay =
            _validateFeeController(feeControllerAddress, maximumMakerFeeBps_, maximumTakerFeeBps_);
        baseToken = baseToken_;
        quoteToken = quoteToken_;
        maximumMakerFeeBps = maximumMakerFeeBps_;
        maximumTakerFeeBps = maximumTakerFeeBps_;
        feeController = feeController_;
        feeControllerDelay = initialFeeControllerDelay;
        pauseGuardian = owner_;
        emit FeeControllerDelayUpdated(feeControllerAddress, 0, initialFeeControllerDelay);
        emit PauseGuardianUpdated(address(0), owner_);
    }

    function scheduleFeeControllerUpdate(IGovernedOrderBookFeeController newFeeController) external override onlyOwner {
        address newFeeControllerAddress = address(newFeeController);
        _validateFeeController(newFeeControllerAddress, maximumMakerFeeBps, maximumTakerFeeBps);
        if (address(pendingFeeController) != address(0)) {
            revert FeeControllerUpdateAlreadyScheduled(address(pendingFeeController));
        }

        uint256 delay = feeControllerDelay;
        // Timelock scheduling intentionally uses block time and tolerates normal timestamp drift.
        // slither-disable-next-line timestamp
        if (delay > type(uint48).max - block.timestamp) revert FeeControllerDelayOverflow(delay);
        // The preceding bound guarantees this conversion cannot truncate.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint48 executeAfter = uint48(block.timestamp + delay);
        pendingFeeController = newFeeController;
        feeControllerUpdateTime = executeAfter;
        emit FeeControllerUpdateScheduled(address(feeController), newFeeControllerAddress, executeAfter);
    }

    function executeFeeControllerUpdate() external override {
        IGovernedOrderBookFeeController newFeeController = pendingFeeController;
        if (address(newFeeController) == address(0)) revert NoFeeControllerUpdateScheduled();
        uint48 executeAfter = feeControllerUpdateTime;
        // Timelock maturity intentionally uses block time and tolerates normal timestamp drift.
        // slither-disable-next-line timestamp
        if (block.timestamp < executeAfter) revert FeeControllerUpdateNotReady(executeAfter, block.timestamp);

        uint256 newFeeControllerDelay =
            _validateFeeController(address(newFeeController), maximumMakerFeeBps, maximumTakerFeeBps);

        address previousFeeController = address(feeController);
        uint256 previousFeeControllerDelay = feeControllerDelay;
        feeController = newFeeController;
        feeControllerDelay = newFeeControllerDelay;
        delete pendingFeeController;
        delete feeControllerUpdateTime;
        emit FeeControllerUpdated(previousFeeController, address(newFeeController));
        emit FeeControllerDelayUpdated(address(newFeeController), previousFeeControllerDelay, newFeeControllerDelay);
    }

    function cancelFeeControllerUpdate() external override onlyOwner {
        IGovernedOrderBookFeeController scheduledController = pendingFeeController;
        if (address(scheduledController) == address(0)) revert NoFeeControllerUpdateScheduled();
        delete pendingFeeController;
        delete feeControllerUpdateTime;
        emit FeeControllerUpdateCancelled(address(scheduledController));
    }

    function paused() public view override(IOrderBookAdministration, Pausable) returns (bool) {
        return super.paused();
    }

    function setPauseGuardian(address newPauseGuardian) external override onlyOwner {
        if (newPauseGuardian == address(0) || newPauseGuardian == address(this)) revert ZeroAddress();
        address previousPauseGuardian = pauseGuardian;
        pauseGuardian = newPauseGuardian;
        emit PauseGuardianUpdated(previousPauseGuardian, newPauseGuardian);
    }

    function pause() external override {
        if (msg.sender != pauseGuardian && msg.sender != owner()) revert UnauthorizedPauseCaller(msg.sender);
        _pause();
    }

    function unpause() external override onlyOwner {
        _unpause();
    }

    function scheduleLegacyMode(uint48 activationTime) external override onlyOwner {
        if (legacyMode) revert LegacyModeAlreadyEnabled();
        uint48 scheduledActivationTime = legacyModeActivationTime;
        if (scheduledActivationTime != 0) revert LegacyModeAlreadyScheduled(scheduledActivationTime);

        uint48 earliestActivationTime = SafeCast.toUint48(block.timestamp + minimumLegacyModeDelay);
        // The owner-selected activation time is intentionally bounded by block time; normal drift cannot bypass 7 days.
        // slither-disable-next-line timestamp
        if (activationTime < earliestActivationTime) {
            revert LegacyModeActivationTooEarly(activationTime, earliestActivationTime);
        }

        legacyModeActivationTime = activationTime;
        emit LegacyModeScheduled(msg.sender, activationTime);
    }

    function cancelLegacyModeSchedule() external override {
        if (msg.sender != owner() && msg.sender != pauseGuardian) {
            revert UnauthorizedLegacyModeCancellation(msg.sender);
        }
        if (legacyMode) revert LegacyModeAlreadyEnabled();
        uint48 scheduledActivationTime = legacyModeActivationTime;
        if (scheduledActivationTime == 0) revert NoLegacyModeScheduled();

        delete legacyModeActivationTime;
        emit LegacyModeScheduleCancelled(msg.sender, scheduledActivationTime);
    }

    function executeLegacyMode() external override {
        if (legacyMode) revert LegacyModeAlreadyEnabled();
        uint48 executeAfter = legacyModeActivationTime;
        // Zero is the exact sentinel for there being no pending legacy-mode schedule; scheduled timestamps are nonzero.
        // slither-disable-next-line incorrect-equality
        if (executeAfter == 0) revert NoLegacyModeScheduled();
        // Legacy-mode activation intentionally uses block time and tolerates normal timestamp drift.
        // slither-disable-next-line timestamp
        if (block.timestamp < executeAfter) revert LegacyModeNotReady(executeAfter, block.timestamp);

        delete legacyModeActivationTime;
        legacyMode = true;
        emit LegacyModeEntered(msg.sender);
    }

    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }

    function recoverExcessToken(address token, address recipient) external override nonReentrant onlyOwner {
        if (token == address(0) || recipient == address(0) || recipient == address(this)) revert ZeroAddress();
        if (token.code.length == 0) revert TokenIsNotContract(token);

        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        uint256 liability = _escrowLiability[token];
        if (balanceBefore < liability) revert EscrowInsolvent(token, balanceBefore, liability);

        uint256 excess = balanceBefore - liability;
        // Zero is the exact sentinel for there being no recoverable excess.
        // slither-disable-next-line incorrect-equality
        if (excess == 0) revert NoExcessBalance(token);

        _pushExact(token, recipient, excess);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        if (balanceAfter < liability) revert EscrowInsolvent(token, balanceAfter, liability);

        emit ExcessTokenRecovered(token, recipient, excess);
    }

    function makeOrder(MakeOrderParams calldata params)
        external
        override
        nonReentrant
        whenNotPaused
        whenNotInLegacyMode
        returns (uint256 orderId)
    {
        _validateOrderTerms(
            params.totalBaseAmount, params.totalQuoteAmount, params.minimumFillBaseAmount, params.expiry
        );

        _quoteFeeSet(msg.sender, address(0), address(0), params.side, params.totalBaseAmount, params.totalQuoteAmount);
        (address escrowToken, uint256 escrowAmount) =
            _makerEscrow(params.side, params.totalBaseAmount, params.totalQuoteAmount);
        _pullExact(escrowToken, msg.sender, escrowAmount);
        _escrowLiability[escrowToken] += escrowAmount;

        orderId = _storeOrder(
            params.side, params.totalBaseAmount, params.totalQuoteAmount, params.minimumFillBaseAmount, params.expiry
        );

        emit OrderMade(
            orderId,
            msg.sender,
            params.side,
            params.totalBaseAmount,
            params.totalQuoteAmount,
            params.minimumFillBaseAmount,
            params.expiry
        );
    }

    function amendOrder(AmendOrderParams calldata params)
        external
        override
        nonReentrant
        whenNotPaused
        whenNotInLegacyMode
        returns (uint256 newOrderId)
    {
        (Order storage previousOrder, address escrowToken, uint256 previousEscrowAmount, uint256 newEscrowAmount,) =
            _amendmentAmounts(params);
        Side side = previousOrder.side;

        previousOrder.status = OrderStatus.CANCELLED;
        _remainingQuoteAmount[params.orderId] = 0;
        newOrderId = _storeOrder(
            side, params.newBaseAmount, params.newQuoteAmount, params.newMinimumFillBaseAmount, params.newExpiry
        );
        _adjustEscrow(params.orderId, escrowToken, previousEscrowAmount, newEscrowAmount);

        emit OrderCancelled(params.orderId, msg.sender);
        emit OrderMade(
            newOrderId,
            msg.sender,
            side,
            params.newBaseAmount,
            params.newQuoteAmount,
            params.newMinimumFillBaseAmount,
            params.newExpiry
        );
        emit OrderAmended(params.orderId, newOrderId, msg.sender);
    }

    function takeOrder(TakeOrderParams calldata params) external override nonReentrant whenNotPaused {
        _validateSettlementRecipient(params.recipient);

        Order storage order = _requireTakeableOrder(params.orderId);
        if (order.maker == msg.sender) revert MakerCannotTakeOwnOrder(params.orderId);
        SettlementData memory data = _settlementData(order, msg.sender, params.recipient, params.baseAmount);
        _validateSettlementBounds(params, order.side, params.baseAmount, data);

        order.remainingBaseAmount = data.remainingBaseAmount;
        _remainingQuoteAmount[params.orderId] = data.remainingQuoteAmount;
        address remainderEscrowToken = address(0);
        uint256 remainderRefundAmount = 0;
        if (data.remainingBaseAmount == 0) {
            order.status = OrderStatus.FILLED;
        } else if (data.cancelRemainder) {
            (remainderEscrowToken, remainderRefundAmount) = _remainingMakerEscrow(order);
            order.status = OrderStatus.CANCELLED;
            _remainingQuoteAmount[params.orderId] = 0;
        }

        _settleTrade(order, params, data);
        if (data.cancelRemainder && remainderRefundAmount != 0) {
            _creditAndAttemptRefund(params.orderId, order.maker, remainderEscrowToken, remainderRefundAmount);
        }

        emit OrderTaken(
            params.orderId, msg.sender, params.recipient, params.baseAmount, data.quoteAmount, data.remainingBaseAmount
        );
        if (data.cancelRemainder) {
            emit OrderCancelled(params.orderId, order.maker);
            emit OrderRemainderCancelled(
                params.orderId, msg.sender, order.maker, data.remainingBaseAmount, data.remainingQuoteAmount
            );
        }
        _payFees(params.orderId, order.maker, FeeRole.MAKER, data.fees.makerFees);
        _payFees(params.orderId, msg.sender, FeeRole.TAKER, data.fees.takerFees);
    }

    function cancelOrder(uint256 orderId) external override nonReentrant {
        Order storage order = _orders[orderId];
        if (order.id == 0) revert OrderNotFound(orderId);
        if (order.status != OrderStatus.OPEN) revert OrderNotOpen(orderId, statusOf(orderId));
        if (order.maker != msg.sender) revert NotOrderMaker(orderId, msg.sender);
        // Finalize an effectively expired order as EXPIRED so its lifecycle cannot move to CANCELLED and indexers
        // observe one consistent terminal state, while still refunding a maker who calls cancelOrder.
        // slither-disable-next-line timestamp
        if (block.timestamp >= order.expiry) {
            _closeAndRefund(order, OrderStatus.EXPIRED);
            emit ExpiredOrderSwept(orderId, msg.sender, order.maker);
            return;
        }

        _closeAndRefund(order, OrderStatus.CANCELLED);
        emit OrderCancelled(orderId, msg.sender);
    }

    function sweepExpiredOrder(uint256 orderId) external override nonReentrant {
        Order storage order = _orders[orderId];
        if (order.id == 0) revert OrderNotFound(orderId);
        if (order.status != OrderStatus.OPEN) revert OrderNotOpen(orderId, statusOf(orderId));
        // Order expiry intentionally uses block time and tolerates normal timestamp drift.
        // slither-disable-next-line timestamp
        if (block.timestamp < order.expiry) revert OrderNotExpired(orderId);

        _closeAndRefund(order, OrderStatus.EXPIRED);
        emit ExpiredOrderSwept(orderId, msg.sender, order.maker);
    }

    function sweepExpiredOrders(uint256[] calldata orderIds) external override nonReentrant {
        if (orderIds.length > maximumSweepBatchSize) {
            revert SweepBatchTooLarge(orderIds.length, maximumSweepBatchSize);
        }
        for (uint256 i; i < orderIds.length; ++i) {
            Order storage order = _orders[orderIds[i]];
            // Order expiry intentionally uses block time and tolerates normal timestamp drift.
            // slither-disable-next-line timestamp
            if (order.id != 0 && order.status == OrderStatus.OPEN && block.timestamp >= order.expiry) {
                _closeAndRefund(order, OrderStatus.EXPIRED);
                emit ExpiredOrderSwept(order.id, msg.sender, order.maker);
            }
        }
    }

    function withdrawRefund(address token, address recipient) external override nonReentrant returns (uint256 amount) {
        return _withdrawRefund(msg.sender, token, recipient);
    }

    /// @dev External self-call isolates a failed token transfer so closing the order can retain a pull credit.
    function executeRefund(address account, address token, address recipient) external returns (uint256 amount) {
        if (msg.sender != address(this)) revert UnauthorizedRefundExecutor(msg.sender);
        return _withdrawRefund(account, token, recipient);
    }

    function quoteMakeOrder(MakeOrderParams calldata params)
        external
        view
        override
        returns (Quote[] memory approvals, SettlementQuote memory settlement)
    {
        _validateOrderTerms(
            params.totalBaseAmount, params.totalQuoteAmount, params.minimumFillBaseAmount, params.expiry
        );
        FeeSet memory fees = _quoteFeeSet(
            msg.sender, address(0), address(0), params.side, params.totalBaseAmount, params.totalQuoteAmount
        );
        (address token, uint256 amount) = _makerEscrow(params.side, params.totalBaseAmount, params.totalQuoteAmount);
        approvals = _singleQuote(token, amount);
        settlement = _buildSettlementQuote(params.side, params.totalBaseAmount, params.totalQuoteAmount, fees);
    }

    function quoteAmendOrder(AmendOrderParams calldata params)
        external
        view
        override
        returns (Quote[] memory approvals, Quote[] memory refunds, SettlementQuote memory settlement)
    {
        (
            ,
            address escrowToken,
            uint256 previousEscrowAmount,
            uint256 newEscrowAmount,
            SettlementQuote memory amendmentSettlement
        ) = _amendmentAmounts(params);
        (approvals, refunds) = _escrowAdjustmentQuotes(escrowToken, previousEscrowAmount, newEscrowAmount);
        settlement = amendmentSettlement;
    }

    function quoteTakeOrder(uint256 orderId, uint256 baseAmount)
        external
        view
        override
        returns (Quote[] memory approvals, SettlementQuote memory settlement)
    {
        return _quoteTakeOrder(orderId, baseAmount, msg.sender);
    }

    function quoteTakeOrder(uint256 orderId, uint256 baseAmount, address settlementRecipient)
        external
        view
        override
        returns (Quote[] memory approvals, SettlementQuote memory settlement)
    {
        return _quoteTakeOrder(orderId, baseAmount, settlementRecipient);
    }

    function _quoteTakeOrder(uint256 orderId, uint256 baseAmount, address settlementRecipient)
        private
        view
        returns (Quote[] memory approvals, SettlementQuote memory settlement)
    {
        _validateSettlementRecipient(settlementRecipient);
        Order storage order = _requireTakeableOrder(orderId);
        if (order.maker == msg.sender) revert MakerCannotTakeOwnOrder(orderId);
        SettlementData memory data = _settlementData(order, msg.sender, settlementRecipient, baseAmount);
        settlement = _buildSettlementQuote(order.side, baseAmount, data.quoteAmount, data.fees);
        approvals = _singleQuote(settlement.inputToken, settlement.totalInputAmount);
    }

    function getOrder(uint256 orderId) external view override returns (Order memory order) {
        Order storage stored = _orders[orderId];
        if (stored.id == 0) revert OrderNotFound(orderId);
        return _effectiveOrder(stored);
    }

    function remainingQuoteAmountOf(uint256 orderId) external view override returns (uint256) {
        if (_orders[orderId].id == 0) revert OrderNotFound(orderId);
        return _remainingQuoteAmount[orderId];
    }

    function escrowLiability(address token) external view override returns (uint256) {
        return _escrowLiability[token];
    }

    function claimableRefund(address account, address token) external view override returns (uint256) {
        return _claimableRefund[account][token];
    }

    function getOrders(uint256 cursor, uint256 limit)
        external
        view
        override
        returns (Order[] memory orders, uint256 nextCursor)
    {
        if (limit == 0 || limit > maximumPageSize) revert InvalidPageSize(limit, maximumPageSize);
        if (cursor == 0) cursor = 1;
        if (cursor > orderCount) return (new Order[](0), 0);

        uint256 available = orderCount - cursor + 1;
        uint256 size = limit < available ? limit : available;
        orders = new Order[](size);
        for (uint256 i; i < size; ++i) {
            orders[i] = _effectiveOrder(_orders[cursor + i]);
        }
        nextCursor = size < available ? cursor + size : 0;
    }

    function statusOf(uint256 orderId) public view override returns (OrderStatus status) {
        Order storage order = _orders[orderId];
        if (order.id == 0) return OrderStatus.NONE;
        // Order expiry intentionally uses block time and tolerates normal timestamp drift.
        // slither-disable-next-line timestamp
        if (order.status == OrderStatus.OPEN && block.timestamp >= order.expiry) return OrderStatus.EXPIRED;
        return order.status;
    }

    function _validateOrderTerms(uint256 baseAmount, uint256 quoteAmount, uint256 minimumFillBaseAmount, uint48 expiry)
        private
        view
    {
        if (baseAmount == 0 || quoteAmount == 0) revert InvalidOrderAmount();
        if (minimumFillBaseAmount > baseAmount) {
            revert InvalidMinimumFillAmount(minimumFillBaseAmount, baseAmount);
        }
        if (minimumFillBaseAmount != 0 && Math.mulDiv(minimumFillBaseAmount, quoteAmount, baseAmount) == 0) {
            revert MinimumFillCannotProduceQuoteAmount(minimumFillBaseAmount, baseAmount, quoteAmount);
        }
        // Order expiry intentionally uses block time and tolerates normal timestamp drift.
        // slither-disable-next-line timestamp
        if (expiry <= block.timestamp) revert InvalidExpiry(expiry);
    }

    function _validateSettlementRecipient(address settlementRecipient) private view {
        if (settlementRecipient == address(0) || settlementRecipient == address(this)) revert ZeroAddress();
    }

    function _makerEscrow(Side side, uint256 baseAmount, uint256 quoteAmount)
        private
        view
        returns (address token, uint256 amount)
    {
        if (side == Side.SELL) return (baseToken, baseAmount);
        return (quoteToken, quoteAmount);
    }

    function _requireAmendableOrder(AmendOrderParams calldata params) private view returns (Order storage order) {
        order = _orders[params.orderId];
        if (order.id == 0) revert OrderNotFound(params.orderId);
        if (order.status != OrderStatus.OPEN) revert OrderNotOpen(params.orderId, order.status);
        if (order.maker != msg.sender) revert NotOrderMaker(params.orderId, msg.sender);
        // Order expiry intentionally uses block time and tolerates normal timestamp drift.
        // slither-disable-next-line timestamp
        if (block.timestamp >= order.expiry) revert OrderExpired(params.orderId);
        if (order.remainingBaseAmount != params.expectedRemainingBaseAmount) {
            revert RemainingBaseAmountChanged(
                params.orderId, params.expectedRemainingBaseAmount, order.remainingBaseAmount
            );
        }
        _validateOrderTerms(
            params.newBaseAmount, params.newQuoteAmount, params.newMinimumFillBaseAmount, params.newExpiry
        );
    }

    function _amendmentAmounts(AmendOrderParams calldata params)
        private
        view
        returns (
            Order storage previousOrder,
            address escrowToken,
            uint256 previousEscrowAmount,
            uint256 newEscrowAmount,
            SettlementQuote memory settlement
        )
    {
        previousOrder = _requireAmendableOrder(params);
        FeeSet memory fees = _quoteFeeSet(
            msg.sender, address(0), address(0), previousOrder.side, params.newBaseAmount, params.newQuoteAmount
        );
        settlement = _buildSettlementQuote(previousOrder.side, params.newBaseAmount, params.newQuoteAmount, fees);
        (escrowToken, previousEscrowAmount) = _remainingMakerEscrow(previousOrder);
        (, newEscrowAmount) = _makerEscrow(previousOrder.side, params.newBaseAmount, params.newQuoteAmount);
    }

    function _requireTakeableOrder(uint256 orderId) private view returns (Order storage order) {
        order = _orders[orderId];
        if (order.id == 0) revert OrderNotFound(orderId);
        if (order.status != OrderStatus.OPEN) revert OrderNotOpen(orderId, order.status);
        // Order expiry intentionally uses block time and tolerates normal timestamp drift.
        // slither-disable-next-line timestamp
        if (block.timestamp >= order.expiry) revert OrderExpired(orderId);
    }

    function _validateTakeAmount(Order storage order, uint256 baseAmount) private view {
        if (baseAmount == 0 || baseAmount > order.remainingBaseAmount) {
            revert InvalidTakeAmount(baseAmount, order.remainingBaseAmount);
        }
        if (
            order.minimumFillBaseAmount != 0 && baseAmount != order.remainingBaseAmount
                && baseAmount < order.minimumFillBaseAmount
        ) {
            revert TakeAmountBelowMinimum(baseAmount, order.minimumFillBaseAmount);
        }
    }

    function _quoteDelta(Order storage order, uint256 baseAmount) private view returns (uint256 quoteAmount) {
        uint256 filledBefore = order.totalBaseAmount - order.remainingBaseAmount;
        uint256 filledAfter = filledBefore + baseAmount;
        Math.Rounding rounding = order.side == Side.SELL ? Math.Rounding.Ceil : Math.Rounding.Floor;
        uint256 quoteBefore = Math.mulDiv(filledBefore, order.totalQuoteAmount, order.totalBaseAmount, rounding);
        uint256 quoteAfter = Math.mulDiv(filledAfter, order.totalQuoteAmount, order.totalBaseAmount, rounding);
        quoteAmount = quoteAfter - quoteBefore;
        if (quoteAmount == 0) revert ZeroQuoteAmount();
    }

    function _validateRemainder(uint256 remainingBaseAmount, uint256 remainingQuoteAmount) private pure {
        if ((remainingBaseAmount == 0) != (remainingQuoteAmount == 0)) {
            revert UnfillableRemainder(remainingBaseAmount, remainingQuoteAmount);
        }
    }

    function _settlementData(Order storage order, address taker, address settlementRecipient, uint256 baseAmount)
        private
        view
        returns (SettlementData memory data)
    {
        _validateTakeAmount(order, baseAmount);
        data.quoteAmount = _quoteDelta(order, baseAmount);
        data.fees = _quoteFeeSet(order.maker, taker, settlementRecipient, order.side, baseAmount, data.quoteAmount);

        address takerInputToken = _takerInputToken(order.side);
        if (data.fees.takerFeeToken == takerInputToken) {
            data.takerInputFeeAmount = data.fees.takerFeeAmount;
        } else {
            data.takerOutputFeeAmount = data.fees.takerFeeAmount;
        }

        data.remainingBaseAmount = order.remainingBaseAmount - baseAmount;
        data.remainingQuoteAmount = _remainingQuoteAmount[order.id] - data.quoteAmount;
        data.cancelRemainder = order.minimumFillBaseAmount != 0 && data.remainingBaseAmount != 0
            && data.remainingBaseAmount < order.minimumFillBaseAmount;
        if (!data.cancelRemainder) _validateRemainder(data.remainingBaseAmount, data.remainingQuoteAmount);
    }

    function _quoteFeeSet(
        address maker,
        address taker,
        address settlementRecipient,
        Side side,
        uint256 baseAmount,
        uint256 quoteAmount
    ) private view returns (FeeSet memory fees) {
        IOrderBookFeeController currentController = feeController;
        (fees.makerFees, fees.makerFeeToken, fees.makerFeeAmount) = _quoteOrderFees(
            currentController, maker, taker, settlementRecipient, side, FeeRole.MAKER, baseAmount, quoteAmount
        );
        (fees.takerFees, fees.takerFeeToken, fees.takerFeeAmount) = _quoteOrderFees(
            currentController, maker, taker, settlementRecipient, side, FeeRole.TAKER, baseAmount, quoteAmount
        );
    }

    function _quoteOrderFees(
        IOrderBookFeeController orderFeeController,
        address maker,
        address taker,
        address settlementRecipient,
        Side side,
        FeeRole feeRole,
        uint256 baseAmount,
        uint256 quoteAmount
    ) private view returns (FeeQuote[] memory feeQuotes, address feeToken, uint256 totalFeeAmount) {
        feeQuotes = orderFeeController.quoteOrderFee(
            maker, taker, settlementRecipient, side, feeRole, baseToken, baseAmount, quoteToken, quoteAmount
        );
        if (feeQuotes.length > maximumFeeQuotesPerRole) {
            revert TooManyFeeQuotes(feeRole, feeQuotes.length, maximumFeeQuotesPerRole);
        }
        for (uint256 i; i < feeQuotes.length; ++i) {
            address quotedToken = feeQuotes[i].token;
            if (quotedToken != baseToken && quotedToken != quoteToken) revert UnsupportedFeeToken(quotedToken);
            if (feeQuotes[i].recipient == address(0) || feeQuotes[i].recipient == address(this)) {
                revert InvalidFeeRecipient(feeQuotes[i].recipient);
            }
            if (feeToken == address(0)) feeToken = quotedToken;
            if (quotedToken != feeToken) revert MixedFeeTokens(feeRole, feeToken, quotedToken);
            totalFeeAmount += feeQuotes[i].amount;
        }

        if (feeToken == address(0)) return (feeQuotes, feeToken, totalFeeAmount);
        if (feeRole == FeeRole.MAKER) {
            address expectedToken = _takerInputToken(side);
            if (feeToken != expectedToken) revert InvalidMakerFeeToken(expectedToken, feeToken);
        }
        uint256 feeBasisAmount = feeToken == baseToken ? baseAmount : quoteAmount;
        _validateFee(feeRole, feeToken, totalFeeAmount, feeBasisAmount);
    }

    function _validateFee(FeeRole feeRole, address token, uint256 feeAmount, uint256 basisAmount) private view {
        uint256 maximumFeeBps = feeRole == FeeRole.MAKER ? maximumMakerFeeBps : maximumTakerFeeBps;
        uint256 maximumFeeAmount = Math.mulDiv(basisAmount, maximumFeeBps, BPS_DENOMINATOR);
        if (feeAmount > maximumFeeAmount) {
            revert FeeExceedsMaximum(feeRole, token, feeAmount, maximumFeeAmount);
        }
    }

    function _validateSettlementBounds(
        TakeOrderParams calldata params,
        Side side,
        uint256 baseAmount,
        SettlementData memory data
    ) private pure {
        if (side == Side.SELL) {
            uint256 quoteIn = data.quoteAmount + data.takerInputFeeAmount;
            uint256 baseOut = baseAmount - data.takerOutputFeeAmount;
            if (quoteIn > params.maxQuoteIn) revert QuoteInExceedsMaximum(quoteIn, params.maxQuoteIn);
            if (baseOut < params.minBaseOut) revert BaseOutBelowMinimum(baseOut, params.minBaseOut);
        } else {
            uint256 baseIn = baseAmount + data.takerInputFeeAmount;
            uint256 quoteOut = data.quoteAmount - data.takerOutputFeeAmount;
            if (baseIn > params.maxBaseIn) revert BaseInExceedsMaximum(baseIn, params.maxBaseIn);
            if (quoteOut < params.minQuoteOut) revert QuoteOutBelowMinimum(quoteOut, params.minQuoteOut);
        }
    }

    function _settleTrade(Order storage order, TakeOrderParams calldata params, SettlementData memory data) private {
        if (order.side == Side.SELL) {
            _escrowLiability[baseToken] -= params.baseAmount;
            _pullExact(quoteToken, msg.sender, data.quoteAmount + data.takerInputFeeAmount);
            _pushExact(baseToken, params.recipient, params.baseAmount - data.takerOutputFeeAmount);
            _pushExact(quoteToken, order.maker, data.quoteAmount - data.fees.makerFeeAmount);
        } else {
            _escrowLiability[quoteToken] -= data.quoteAmount;
            _pullExact(baseToken, msg.sender, params.baseAmount + data.takerInputFeeAmount);
            _pushExact(baseToken, order.maker, params.baseAmount - data.fees.makerFeeAmount);
            _pushExact(quoteToken, params.recipient, data.quoteAmount - data.takerOutputFeeAmount);
        }
    }

    function _payFees(uint256 orderId, address payer, FeeRole feeRole, FeeQuote[] memory feeQuotes) private {
        for (uint256 i; i < feeQuotes.length; ++i) {
            FeeQuote memory feeQuote = feeQuotes[i];
            if (feeQuote.amount != 0) _pushExact(feeQuote.token, feeQuote.recipient, feeQuote.amount);
            emit OrderFeePaid(orderId, payer, feeQuote.recipient, feeRole, feeQuote.token, feeQuote.amount);
        }
    }

    function _takerInputToken(Side side) private view returns (address token) {
        return side == Side.SELL ? quoteToken : baseToken;
    }

    function _singleQuote(address token, uint256 amount) private pure returns (Quote[] memory quotes) {
        quotes = new Quote[](1);
        quotes[0] = Quote({token: token, amount: amount});
    }

    function _escrowAdjustmentQuotes(address token, uint256 previousAmount, uint256 newAmount)
        private
        pure
        returns (Quote[] memory approvals, Quote[] memory refunds)
    {
        approvals = new Quote[](0);
        refunds = new Quote[](0);
        if (newAmount > previousAmount) approvals = _singleQuote(token, newAmount - previousAmount);
        if (previousAmount > newAmount) refunds = _singleQuote(token, previousAmount - newAmount);
    }

    function _buildSettlementQuote(Side side, uint256 baseAmount, uint256 quoteAmount, FeeSet memory fees)
        private
        view
        returns (SettlementQuote memory settlement)
    {
        address inputToken = _takerInputToken(side);
        address outputToken = inputToken == baseToken ? quoteToken : baseToken;
        uint256 grossInputAmount = side == Side.SELL ? quoteAmount : baseAmount;
        uint256 grossOutputAmount = side == Side.SELL ? baseAmount : quoteAmount;
        uint256 inputFeeAmount = fees.takerFeeToken == inputToken ? fees.takerFeeAmount : 0;
        uint256 outputFeeAmount = fees.takerFeeToken == outputToken ? fees.takerFeeAmount : 0;
        return SettlementQuote({
            inputToken: inputToken,
            grossInputAmount: grossInputAmount,
            inputFeeAmount: inputFeeAmount,
            totalInputAmount: grossInputAmount + inputFeeAmount,
            outputToken: outputToken,
            grossOutputAmount: grossOutputAmount,
            outputFeeAmount: outputFeeAmount,
            netOutputAmount: grossOutputAmount - outputFeeAmount,
            makerFeeAmount: fees.makerFeeAmount
        });
    }

    function _closeAndRefund(Order storage order, OrderStatus closingStatus) private {
        (address escrowToken, uint256 refundAmount) = _remainingMakerEscrow(order);

        order.status = closingStatus;
        _remainingQuoteAmount[order.id] = 0;
        _creditAndAttemptRefund(order.id, order.maker, escrowToken, refundAmount);
    }

    function _remainingMakerEscrow(Order storage order) private view returns (address token, uint256 amount) {
        if (order.side == Side.SELL) return (baseToken, order.remainingBaseAmount);
        return (quoteToken, _remainingQuoteAmount[order.id]);
    }

    function _storeOrder(
        Side side,
        uint256 baseAmount,
        uint256 quoteAmount,
        uint256 minimumFillBaseAmount,
        uint48 expiry
    ) private returns (uint256 orderId) {
        orderId = ++orderCount;
        _orders[orderId] = Order({
            id: orderId,
            maker: msg.sender,
            side: side,
            status: OrderStatus.OPEN,
            expiry: expiry,
            totalBaseAmount: baseAmount,
            remainingBaseAmount: baseAmount,
            totalQuoteAmount: quoteAmount,
            minimumFillBaseAmount: minimumFillBaseAmount
        });
        _remainingQuoteAmount[orderId] = quoteAmount;
    }

    function _adjustEscrow(uint256 orderId, address token, uint256 previousAmount, uint256 newAmount) private {
        if (newAmount > previousAmount) {
            uint256 additionalAmount = newAmount - previousAmount;
            _escrowLiability[token] += additionalAmount;
            _pullExact(token, msg.sender, additionalAmount);
        } else if (previousAmount > newAmount) {
            uint256 refundAmount = previousAmount - newAmount;
            _creditAndAttemptRefund(orderId, msg.sender, token, refundAmount);
        }
    }

    function _creditAndAttemptRefund(uint256 orderId, address account, address token, uint256 amount) private {
        _claimableRefund[account][token] += amount;
        emit RefundCredited(orderId, account, token, amount);

        // Batch sweeps are capped at 100; each isolated self-call either delivers one refund or leaves its credit.
        // slither-disable-next-line calls-loop
        try this.executeRefund(account, token, account) returns (uint256 deliveredAmount) {
            assert(deliveredAmount >= amount);
            return;
        } catch {
            // Retain the credit and liability so the maker can choose another recipient later.
            return;
        }
    }

    function _withdrawRefund(address account, address token, address recipient) private returns (uint256 amount) {
        if (recipient == address(0) || recipient == address(this)) revert ZeroAddress();
        amount = _claimableRefund[account][token];
        if (amount == 0) revert NoRefundAvailable(account, token);

        delete _claimableRefund[account][token];
        _escrowLiability[token] -= amount;
        _pushExact(token, recipient, amount);
        emit RefundWithdrawn(account, token, recipient, amount);
    }

    function _effectiveOrder(Order storage stored) private view returns (Order memory order) {
        order = stored;
        // Order expiry intentionally uses block time and tolerates normal timestamp drift.
        // slither-disable-next-line timestamp
        if (order.status == OrderStatus.OPEN && block.timestamp >= order.expiry) order.status = OrderStatus.EXPIRED;
    }

    // All state-changing callers are protected by nonReentrant; the balance delta rejects fee-on-transfer tokens.
    // slither-disable-next-line reentrancy-balance
    function _pullExact(address token, address from, uint256 amount) private {
        uint256 balanceBefore = IERC20(token).balanceOf(address(this));
        IERC20(token).safeTransferFrom(from, address(this), amount);
        uint256 balanceAfter = IERC20(token).balanceOf(address(this));
        uint256 receivedAmount = balanceAfter >= balanceBefore ? balanceAfter - balanceBefore : 0;
        if (receivedAmount != amount) revert UnsupportedTokenBehavior(token, amount, receivedAmount);
    }

    // Checking both sides rejects transfer taxes, sender surcharges, and supply changes during outgoing settlement.
    // _creditAndAttemptRefund isolates ordinary refund reverts and retains the maker's claim. A token that exhausts
    // the self-call's forwarded gas can still leave too little gas for the outer sweepExpiredOrders frame and revert
    // that batch; sweepExpiredOrder remains the independent fallback. All state-changing callers are nonReentrant.
    // slither-disable-start calls-loop
    // slither-disable-next-line reentrancy-balance
    function _pushExact(address token, address recipient, uint256 amount) private {
        uint256 senderBalanceBefore = IERC20(token).balanceOf(address(this));
        uint256 recipientBalanceBefore = IERC20(token).balanceOf(recipient);
        IERC20(token).safeTransfer(recipient, amount);
        uint256 senderBalanceAfter = IERC20(token).balanceOf(address(this));
        uint256 recipientBalanceAfter = IERC20(token).balanceOf(recipient);

        uint256 debitedAmount = senderBalanceBefore >= senderBalanceAfter ? senderBalanceBefore - senderBalanceAfter : 0;
        uint256 receivedAmount =
            recipientBalanceAfter >= recipientBalanceBefore ? recipientBalanceAfter - recipientBalanceBefore : 0;
        if (debitedAmount != amount || receivedAmount != amount) {
            revert UnsupportedOutgoingTokenBehavior(token, recipient, amount, debitedAmount, receivedAmount);
        }
    }
    // slither-disable-end calls-loop

    function _validateFeeController(
        address feeControllerAddress,
        uint16 orderBookMaximumMakerFeeBps,
        uint16 orderBookMaximumTakerFeeBps
    ) private view returns (uint256 delay) {
        if (feeControllerAddress == address(0) || feeControllerAddress == address(this)) revert ZeroAddress();
        if (feeControllerAddress.code.length == 0) revert FeeControllerIsNotContract(feeControllerAddress);
        delay = _feeControllerDelay(feeControllerAddress);
        // Delay bounds intentionally use block time so the cached execution timestamp fits in uint48.
        // slither-disable-next-line timestamp
        if (delay > type(uint48).max - block.timestamp) revert FeeControllerDelayOverflow(delay);
        _validateFeeControllerFeeCaps(feeControllerAddress, orderBookMaximumMakerFeeBps, orderBookMaximumTakerFeeBps);
    }

    function _validateFeeControllerFeeCaps(
        address feeControllerAddress,
        uint16 orderBookMaximumMakerFeeBps,
        uint16 orderBookMaximumTakerFeeBps
    ) private view {
        uint16 controllerMaximumMakerFeeBps = 0;
        uint16 controllerMaximumTakerFeeBps = 0;
        try IFeeControllerFeeCaps(feeControllerAddress).maximumMakerFeeBps() returns (
            uint16 reportedMaximumMakerFeeBps
        ) {
            controllerMaximumMakerFeeBps = reportedMaximumMakerFeeBps;
        } catch {
            revert FeeControllerHasNoFeeCaps(feeControllerAddress);
        }
        try IFeeControllerFeeCaps(feeControllerAddress).maximumTakerFeeBps() returns (
            uint16 reportedMaximumTakerFeeBps
        ) {
            controllerMaximumTakerFeeBps = reportedMaximumTakerFeeBps;
        } catch {
            revert FeeControllerHasNoFeeCaps(feeControllerAddress);
        }
        if (
            controllerMaximumMakerFeeBps > orderBookMaximumMakerFeeBps
                || controllerMaximumTakerFeeBps > orderBookMaximumTakerFeeBps
        ) {
            revert FeeControllerFeeCapsExceedOrderBookMaximum(
                feeControllerAddress,
                controllerMaximumMakerFeeBps,
                controllerMaximumTakerFeeBps,
                orderBookMaximumMakerFeeBps,
                orderBookMaximumTakerFeeBps
            );
        }
    }

    function _feeControllerDelay(address feeControllerAddress) private view returns (uint256 delay) {
        try IFeeControllerTimelock(feeControllerAddress).getMinDelay() returns (uint256 reportedDelay) {
            delay = reportedDelay;
        } catch {
            revert FeeControllerHasNoTimelock(feeControllerAddress);
        }
        if (delay == 0) revert FeeControllerHasNoTimelock(feeControllerAddress);
        if (delay < minimumFeeControllerDelay || delay > maximumFeeControllerDelay) {
            revert FeeControllerDelayOutOfBounds(
                feeControllerAddress, delay, minimumFeeControllerDelay, maximumFeeControllerDelay
            );
        }
    }
}
