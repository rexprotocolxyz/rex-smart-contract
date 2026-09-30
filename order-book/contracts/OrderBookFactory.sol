// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {MAXIMUM_FEE_CONTROLLER_DELAY, MINIMUM_FEE_CONTROLLER_DELAY} from "./FeeControllerDelayBounds.sol";
import {OrderBookDeployer} from "./OrderBookDeployer.sol";
import {IFeeControllerFeeCaps} from "./interfaces/IFeeControllerFeeCaps.sol";
import {IFeeControllerTimelock} from "./interfaces/IFeeControllerTimelock.sol";
import {IGovernedOrderBookFeeController} from "./interfaces/IGovernedOrderBookFeeController.sol";
import {IOrderBookDeployer} from "./interfaces/IOrderBookDeployer.sol";
import {IOrderBookWithFeeController} from "./interfaces/IOrderBookWithFeeController.sol";
import {IOrderBookWithFeeControllerFactory} from "./interfaces/IOrderBookWithFeeControllerFactory.sol";

/// @notice Deploys and registers governed fee-controller order books for owner-selected token pairs.
/// @dev Each factory creates its own immutable OrderBookDeployer, binding canonical markets to the reviewed
///      deployer and order-book creation code. The factory owner remains trusted to select each market's
///      base/quote orientation and token suitability.
contract OrderBookFactory is IOrderBookWithFeeControllerFactory, Ownable2Step, ReentrancyGuard {
    uint256 private constant BPS_DENOMINATOR = 10_000;

    uint256 public constant override maximumPageSize = 100;
    uint16 public immutable override maximumMakerFeeBps;
    uint16 public immutable override maximumTakerFeeBps;
    IOrderBookDeployer public immutable override orderBookDeployer;

    address public override defaultOrderBookOwner;
    IGovernedOrderBookFeeController public override defaultFeeController;

    struct RegistryEntry {
        address orderBook;
        address baseToken;
        address quoteToken;
    }

    mapping(bytes32 key => RegistryEntry entry) private _registry;
    mapping(address orderBook => bool registered) private _isOrderBook;
    mapping(address orderBook => uint256 indexPlusOne) private _orderBookIndexPlusOne;
    address[] private _orderBooks;

    constructor(
        address initialOwner,
        address defaultOrderBookOwner_,
        IGovernedOrderBookFeeController defaultFeeController_,
        uint16 maximumMakerFeeBps_,
        uint16 maximumTakerFeeBps_
    ) Ownable(initialOwner) {
        if (initialOwner == address(this)) revert ZeroAddress();
        if (maximumMakerFeeBps_ >= BPS_DENOMINATOR) {
            revert InvalidMaximumMakerFeeBps(maximumMakerFeeBps_);
        }
        if (maximumTakerFeeBps_ >= BPS_DENOMINATOR) {
            revert InvalidMaximumTakerFeeBps(maximumTakerFeeBps_);
        }

        maximumMakerFeeBps = maximumMakerFeeBps_;
        maximumTakerFeeBps = maximumTakerFeeBps_;
        orderBookDeployer = new OrderBookDeployer();
        _setDefaultOrderBookOwner(defaultOrderBookOwner_);
        _setDefaultFeeController(defaultFeeController_);
    }

    function setDefaultOrderBookOwner(address newDefaultOrderBookOwner) external override nonReentrant onlyOwner {
        _setDefaultOrderBookOwner(newDefaultOrderBookOwner);
    }

    function setDefaultFeeController(IGovernedOrderBookFeeController newDefaultFeeController)
        external
        override
        nonReentrant
        onlyOwner
    {
        _setDefaultFeeController(newDefaultFeeController);
    }

    // Registration must follow deployment because the immutable deployer chooses the new address. Every factory
    // mutation is nonReentrant, so the external deployment and validation calls cannot observe or corrupt a partial
    // registry update; a deployment failure rolls back the transaction before any book is registered.
    // slither-disable-next-line reentrancy-no-eth,reentrancy-benign
    function createOrderBook(address baseToken, address quoteToken)
        external
        override
        nonReentrant
        onlyOwner
        returns (address orderBook)
    {
        _validateToken(baseToken);
        _validateToken(quoteToken);
        bytes32 key = _pairKey(baseToken, quoteToken);

        address existingOrderBook = _registry[key].orderBook;
        if (existingOrderBook != address(0)) {
            revert OrderBookAlreadyExists(baseToken, quoteToken, existingOrderBook);
        }

        address orderBookOwner = defaultOrderBookOwner;
        IGovernedOrderBookFeeController feeController = defaultFeeController;
        orderBook = orderBookDeployer.deployOrderBook(
            baseToken, quoteToken, orderBookOwner, feeController, maximumMakerFeeBps, maximumTakerFeeBps
        );
        if (_isOrderBook[orderBook]) revert OrderBookAlreadyRegistered(orderBook);
        _validateOrderBookDeployment(orderBook, baseToken, quoteToken, feeController);

        _registry[key] = RegistryEntry({orderBook: orderBook, baseToken: baseToken, quoteToken: quoteToken});
        _isOrderBook[orderBook] = true;
        _orderBooks.push(orderBook);
        _orderBookIndexPlusOne[orderBook] = _orderBooks.length;

        emit OrderBookDeploymentConfigured(
            orderBook, orderBookOwner, address(feeController), maximumMakerFeeBps, maximumTakerFeeBps
        );
        emit OrderBookCreated(baseToken, quoteToken, orderBook);
    }

    function removeOrderBook(address tokenA, address tokenB)
        external
        override
        nonReentrant
        onlyOwner
        returns (address orderBook)
    {
        bytes32 key = _pairKey(tokenA, tokenB);
        RegistryEntry memory entry = _registry[key];
        orderBook = entry.orderBook;
        if (orderBook == address(0)) revert OrderBookNotRegistered(tokenA, tokenB);

        delete _registry[key];
        delete _isOrderBook[orderBook];
        _removeOrderBookFromEnumeration(orderBook);

        emit OrderBookRemoved(entry.baseToken, entry.quoteToken, orderBook);
    }

    function orderBookFor(address tokenA, address tokenB) external view override returns (address orderBook) {
        return _registry[_pairKey(tokenA, tokenB)].orderBook;
    }

    function pairKey(address tokenA, address tokenB) external pure override returns (bytes32 key) {
        return _pairKey(tokenA, tokenB);
    }

    function isOrderBook(address candidate) external view override returns (bool) {
        return _isOrderBook[candidate];
    }

    function orderBookCount() external view override returns (uint256) {
        return _orderBooks.length;
    }

    function orderBookAt(uint256 index) external view override returns (address orderBook) {
        return _orderBooks[index];
    }

    function getOrderBooks(uint256 cursor, uint256 limit)
        external
        view
        override
        returns (address[] memory orderBooks, uint256 nextCursor)
    {
        return _page(_orderBooks, cursor, limit);
    }

    function renounceOwnership() public pure override {
        revert OwnershipRenunciationDisabled();
    }

    function _setDefaultOrderBookOwner(address newDefaultOrderBookOwner) private {
        if (newDefaultOrderBookOwner == address(0) || newDefaultOrderBookOwner == address(this)) {
            revert ZeroAddress();
        }
        address previousOwner = defaultOrderBookOwner;
        defaultOrderBookOwner = newDefaultOrderBookOwner;
        emit DefaultOrderBookOwnerUpdated(previousOwner, newDefaultOrderBookOwner);
    }

    function _setDefaultFeeController(IGovernedOrderBookFeeController newDefaultFeeController) private {
        address newController = address(newDefaultFeeController);
        _validateFeeController(newController);
        address previousController = address(defaultFeeController);
        defaultFeeController = newDefaultFeeController;
        emit DefaultFeeControllerUpdated(previousController, newController);
    }

    function _removeOrderBookFromEnumeration(address orderBook) private {
        uint256 index = _orderBookIndexPlusOne[orderBook] - 1;
        uint256 lastIndex = _orderBooks.length - 1;
        if (index != lastIndex) {
            address movedOrderBook = _orderBooks[lastIndex];
            _orderBooks[index] = movedOrderBook;
            _orderBookIndexPlusOne[movedOrderBook] = index + 1;
        }
        _orderBooks.pop();
        delete _orderBookIndexPlusOne[orderBook];
    }

    function _page(address[] storage values, uint256 cursor, uint256 limit)
        private
        view
        returns (address[] memory page, uint256 nextCursor)
    {
        if (limit == 0 || limit > maximumPageSize) revert InvalidPageSize(limit, maximumPageSize);
        uint256 length = values.length;
        if (cursor >= length) return (new address[](0), 0);

        uint256 available = length - cursor;
        uint256 size = limit < available ? limit : available;
        page = new address[](size);
        for (uint256 i; i < size; ++i) {
            page[i] = values[cursor + i];
        }
        nextCursor = size < available ? cursor + size : 0;
    }

    function _pairKey(address tokenA, address tokenB) private pure returns (bytes32 key) {
        if (tokenA == address(0) || tokenB == address(0)) revert ZeroAddress();
        if (tokenA == tokenB) revert IdenticalTokens(tokenA);
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return keccak256(abi.encodePacked(token0, token1));
    }

    function _validateToken(address token) private view {
        if (token == address(0)) revert ZeroAddress();
        if (token.code.length == 0) revert TokenIsNotContract(token);
    }

    function _validateFeeController(address feeController) private view {
        if (feeController == address(0) || feeController == address(this)) revert ZeroAddress();
        if (feeController.code.length == 0) revert TokenIsNotContract(feeController);

        _validateFeeControllerDelay(feeController);
        _validateFeeControllerFeeCaps(feeController);
    }

    function _validateFeeControllerDelay(address feeController) private view {
        uint256 delay = 0;
        try IFeeControllerTimelock(feeController).getMinDelay() returns (uint256 reportedDelay) {
            delay = reportedDelay;
        } catch {
            revert FeeControllerHasNoTimelock(feeController);
        }
        if (delay == 0) revert FeeControllerHasNoTimelock(feeController);
        if (delay < MINIMUM_FEE_CONTROLLER_DELAY || delay > MAXIMUM_FEE_CONTROLLER_DELAY) {
            revert FeeControllerDelayOutOfBounds(
                feeController, delay, MINIMUM_FEE_CONTROLLER_DELAY, MAXIMUM_FEE_CONTROLLER_DELAY
            );
        }
    }

    function _validateFeeControllerFeeCaps(address feeController) private view {
        uint16 controllerMaximumMakerFeeBps = 0;
        uint16 controllerMaximumTakerFeeBps = 0;
        try IFeeControllerFeeCaps(feeController).maximumMakerFeeBps() returns (uint16 reportedMakerFeeBps) {
            controllerMaximumMakerFeeBps = reportedMakerFeeBps;
        } catch {
            revert FeeControllerHasNoFeeCaps(feeController);
        }
        try IFeeControllerFeeCaps(feeController).maximumTakerFeeBps() returns (uint16 reportedTakerFeeBps) {
            controllerMaximumTakerFeeBps = reportedTakerFeeBps;
        } catch {
            revert FeeControllerHasNoFeeCaps(feeController);
        }
        if (controllerMaximumMakerFeeBps > maximumMakerFeeBps || controllerMaximumTakerFeeBps > maximumTakerFeeBps) {
            revert FeeControllerFeeCapsExceedOrderBookMaximum(
                feeController,
                controllerMaximumMakerFeeBps,
                controllerMaximumTakerFeeBps,
                maximumMakerFeeBps,
                maximumTakerFeeBps
            );
        }
    }

    function _validateOrderBookDeployment(
        address orderBook,
        address baseToken,
        address quoteToken,
        IGovernedOrderBookFeeController feeController
    ) private view {
        if (orderBook == address(0) || orderBook.code.length == 0) {
            revert InvalidOrderBookDeployment(orderBook);
        }

        IOrderBookWithFeeController deployedOrderBook = IOrderBookWithFeeController(orderBook);
        if (
            deployedOrderBook.baseToken() != baseToken || deployedOrderBook.quoteToken() != quoteToken
                || address(deployedOrderBook.feeController()) != address(feeController)
                || deployedOrderBook.maximumMakerFeeBps() != maximumMakerFeeBps
                || deployedOrderBook.maximumTakerFeeBps() != maximumTakerFeeBps
        ) {
            revert InvalidOrderBookDeployment(orderBook);
        }
    }
}
