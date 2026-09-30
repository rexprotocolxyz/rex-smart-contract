// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {OrderBookDeployer} from "../../contracts/OrderBookDeployer.sol";
import {OrderBookFactory} from "../../contracts/OrderBookFactory.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {MockOrderBookFeeController} from "../mocks/MockOrderBookFeeController.sol";

contract OrderBookFactoryHandler {
    uint256 private constant MAXIMUM_DEPLOYMENTS = 16;
    address private constant BOOK_OWNER_A = address(0xB00A);
    address private constant BOOK_OWNER_B = address(0xB00B);

    OrderBookFactory public immutable factory;
    OrderBookDeployer public immutable deployer;
    MockOrderBookFeeController public immutable controllerA;
    MockOrderBookFeeController public immutable controllerB;

    struct DeploymentRecord {
        address orderBook;
        address baseToken;
        address quoteToken;
        address owner;
        address feeController;
        uint256 feeControllerDelay;
    }

    MockERC20[] private _baseTokens;
    MockERC20[] private _quoteTokens;
    DeploymentRecord[] private _deployments;
    mapping(uint256 baseIndex => mapping(uint256 quoteIndex => address orderBook)) private _expectedOrderBookByPair;
    mapping(uint256 baseIndex => mapping(uint256 quoteIndex => uint256 count)) private _creationCountByPair;
    address[] private _expectedActiveOrderBooks;
    mapping(address orderBook => uint256 indexPlusOne) private _expectedActiveIndexPlusOne;

    address public expectedDefaultOrderBookOwner;
    address public expectedDefaultFeeController;
    uint256 public expectedActivePairCount;

    uint256 public createAttempts;
    uint256 public successfulCreations;
    uint256 public recreations;
    uint256 public removalAttempts;
    uint256 public successfulRemovals;
    uint256 public nonLastRemovals;
    uint256 public ownerUpdateAttempts;
    uint256 public effectiveOwnerChanges;
    uint256 public controllerUpdateAttempts;
    uint256 public effectiveControllerChanges;

    constructor() {
        for (uint256 i; i < 4; ++i) {
            _baseTokens.push(new MockERC20());
        }
        for (uint256 i; i < 3; ++i) {
            _quoteTokens.push(new MockERC20());
        }

        controllerA = new MockOrderBookFeeController(1 days);
        controllerB = new MockOrderBookFeeController(2 days);
        factory = new OrderBookFactory(address(this), BOOK_OWNER_A, controllerA, 100, 100);
        deployer = OrderBookDeployer(address(factory.orderBookDeployer()));
        expectedDefaultOrderBookOwner = BOOK_OWNER_A;
        expectedDefaultFeeController = address(controllerA);
    }

    function createOrderBook(uint256 baseSeed, uint256 quoteSeed) external {
        ++createAttempts;
        if (_deployments.length >= MAXIMUM_DEPLOYMENTS) return;
        uint256 baseIndex = baseSeed % _baseTokens.length;
        uint256 quoteIndex = quoteSeed % _quoteTokens.length;
        address baseToken = address(_baseTokens[baseIndex]);
        address quoteToken = address(_quoteTokens[quoteIndex]);
        if (_expectedOrderBookByPair[baseIndex][quoteIndex] != address(0)) return;

        address owner = expectedDefaultOrderBookOwner;
        address controller = expectedDefaultFeeController;
        bool isRecreation = _creationCountByPair[baseIndex][quoteIndex] != 0;
        address orderBook = factory.createOrderBook(baseToken, quoteToken);

        _expectedOrderBookByPair[baseIndex][quoteIndex] = orderBook;
        ++_creationCountByPair[baseIndex][quoteIndex];
        ++expectedActivePairCount;
        _expectedActiveOrderBooks.push(orderBook);
        _expectedActiveIndexPlusOne[orderBook] = _expectedActiveOrderBooks.length;
        ++successfulCreations;
        if (isRecreation) ++recreations;

        _deployments.push(
            DeploymentRecord({
                orderBook: orderBook,
                baseToken: baseToken,
                quoteToken: quoteToken,
                owner: owner,
                feeController: controller,
                feeControllerDelay: controller == address(controllerA) ? 1 days : 2 days
            })
        );
    }

    function removeOrderBook(uint256 baseSeed, uint256 quoteSeed) external {
        ++removalAttempts;
        uint256 baseIndex = baseSeed % _baseTokens.length;
        uint256 quoteIndex = quoteSeed % _quoteTokens.length;
        address baseToken = address(_baseTokens[baseIndex]);
        address quoteToken = address(_quoteTokens[quoteIndex]);
        address orderBook = _expectedOrderBookByPair[baseIndex][quoteIndex];
        if (orderBook == address(0)) return;

        uint256 index = _expectedActiveIndexPlusOne[orderBook] - 1;
        uint256 lastIndex = _expectedActiveOrderBooks.length - 1;
        factory.removeOrderBook(baseToken, quoteToken);

        delete _expectedOrderBookByPair[baseIndex][quoteIndex];
        --expectedActivePairCount;
        if (index != lastIndex) {
            address movedOrderBook = _expectedActiveOrderBooks[lastIndex];
            _expectedActiveOrderBooks[index] = movedOrderBook;
            _expectedActiveIndexPlusOne[movedOrderBook] = index + 1;
            ++nonLastRemovals;
        }
        _expectedActiveOrderBooks.pop();
        delete _expectedActiveIndexPlusOne[orderBook];
        ++successfulRemovals;
    }

    function updateDefaultOrderBookOwner(uint256) external {
        ++ownerUpdateAttempts;
        address newDefaultOwner = expectedDefaultOrderBookOwner == BOOK_OWNER_A ? BOOK_OWNER_B : BOOK_OWNER_A;
        factory.setDefaultOrderBookOwner(newDefaultOwner);
        ++effectiveOwnerChanges;
        expectedDefaultOrderBookOwner = newDefaultOwner;
    }

    function updateDefaultFeeController(uint256) external {
        ++controllerUpdateAttempts;
        address newDefaultController =
            expectedDefaultFeeController == address(controllerA) ? address(controllerB) : address(controllerA);
        factory.setDefaultFeeController(MockOrderBookFeeController(newDefaultController));
        ++effectiveControllerChanges;
        expectedDefaultFeeController = newDefaultController;
    }

    function deploymentCount() external view returns (uint256) {
        return _deployments.length;
    }

    function deploymentAt(uint256 index)
        external
        view
        returns (
            address orderBook,
            address baseToken,
            address quoteToken,
            address owner,
            address feeController,
            uint256 feeControllerDelay
        )
    {
        DeploymentRecord storage record = _deployments[index];
        return (
            record.orderBook,
            record.baseToken,
            record.quoteToken,
            record.owner,
            record.feeController,
            record.feeControllerDelay
        );
    }

    function baseTokenCount() external view returns (uint256) {
        return _baseTokens.length;
    }

    function quoteTokenCount() external view returns (uint256) {
        return _quoteTokens.length;
    }

    function baseTokenAt(uint256 index) external view returns (address) {
        return address(_baseTokens[index]);
    }

    function quoteTokenAt(uint256 index) external view returns (address) {
        return address(_quoteTokens[index]);
    }

    function expectedOrderBookAtPair(uint256 baseIndex, uint256 quoteIndex) external view returns (address) {
        return _expectedOrderBookByPair[baseIndex][quoteIndex];
    }

    function expectedActiveOrderBookAt(uint256 index) external view returns (address) {
        return _expectedActiveOrderBooks[index];
    }
}
