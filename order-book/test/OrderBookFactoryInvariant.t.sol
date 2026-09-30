// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {OrderBookFactory} from "../contracts/OrderBookFactory.sol";
import {OrderBookDeployer} from "../contracts/OrderBookDeployer.sol";
import {OrderBookWithFeeController} from "../contracts/OrderBookWithFeeController.sol";
import {OrderBookFactoryHandler} from "./handlers/OrderBookFactoryHandler.sol";

contract OrderBookFactoryInvariantTest {
    uint256 private constant PAGINATION_TEST_SIZE = 3;

    OrderBookFactory private factory;
    OrderBookFactoryHandler private handler;
    bytes32 private expectedDeployerCodeHash;
    address[] private _targetedContracts;

    function setUp() public {
        expectedDeployerCodeHash = keccak256(type(OrderBookDeployer).runtimeCode);
        handler = new OrderBookFactoryHandler();
        factory = handler.factory();
        _targetedContracts.push(address(handler));
    }

    function targetContracts() external view returns (address[] memory targetedContracts_) {
        return _targetedContracts;
    }

    // Group related assertions to reduce duplicated campaigns while retaining parallel execution across two groups.
    // solhint-disable-next-line func-name-mixedcase
    function invariant_registryAndFactoryConfigurationAreConsistent() public view {
        address[] memory enumeratedOrderBooks = _readPaginatedEnumeration(factory.orderBookCount());
        _assertRegistryMatchesGhostModel(enumeratedOrderBooks);
        _assertFactoryConfiguration();
    }

    // solhint-disable-next-line func-name-mixedcase
    function invariant_createdBooksRemainConsistent() public view {
        _assertCreatedBooks();
    }

    function _assertRegistryMatchesGhostModel(address[] memory enumeratedOrderBooks) private view {
        uint256 orderBookCount = factory.orderBookCount();
        require(orderBookCount == handler.expectedActivePairCount(), "active pair count divergence");
        require(enumeratedOrderBooks.length == orderBookCount, "enumeration count divergence");

        for (uint256 i; i < orderBookCount; ++i) {
            address orderBookAddress = factory.orderBookAt(i);
            require(orderBookAddress == enumeratedOrderBooks[i], "indexed and paginated enumeration diverge");
            require(orderBookAddress == handler.expectedActiveOrderBookAt(i), "enumeration model divergence");
            require(factory.isOrderBook(orderBookAddress), "enumerated book not active");
        }

        uint256 mappedPairCount;
        uint256 baseCount = handler.baseTokenCount();
        uint256 quoteCount = handler.quoteTokenCount();
        for (uint256 baseIndex; baseIndex < baseCount; ++baseIndex) {
            for (uint256 quoteIndex; quoteIndex < quoteCount; ++quoteIndex) {
                address baseToken = handler.baseTokenAt(baseIndex);
                address quoteToken = handler.quoteTokenAt(quoteIndex);
                address expectedOrderBook = handler.expectedOrderBookAtPair(baseIndex, quoteIndex);
                address orderBookAddress = factory.orderBookFor(baseToken, quoteToken);
                require(orderBookAddress == expectedOrderBook, "pair mapping model divergence");
                require(
                    factory.orderBookFor(quoteToken, baseToken) == expectedOrderBook, "reverse pair mapping divergence"
                );
                if (orderBookAddress == address(0)) continue;
                ++mappedPairCount;
                require(factory.isOrderBook(orderBookAddress), "mapped book not active");
                require(_contains(enumeratedOrderBooks, orderBookAddress), "mapped book not enumerated");
                OrderBookWithFeeController orderBook = OrderBookWithFeeController(orderBookAddress);
                require(orderBook.baseToken() == baseToken, "mapped book base mismatch");
                require(orderBook.quoteToken() == quoteToken, "mapped book quote mismatch");
            }
        }
        require(mappedPairCount == orderBookCount, "nonzero mapping count divergence");

        uint256 activeDeploymentCount;
        uint256 deploymentCount = handler.deploymentCount();
        for (uint256 i; i < deploymentCount; ++i) {
            (address orderBookAddress, address baseToken, address quoteToken,,,) = handler.deploymentAt(i);
            bool active = factory.isOrderBook(orderBookAddress);
            if (active) {
                ++activeDeploymentCount;
                require(factory.orderBookFor(baseToken, quoteToken) == orderBookAddress, "active history not mapped");
                require(_contains(enumeratedOrderBooks, orderBookAddress), "active history not enumerated");
            } else {
                require(factory.orderBookFor(baseToken, quoteToken) != orderBookAddress, "removed history still mapped");
                require(!_contains(enumeratedOrderBooks, orderBookAddress), "removed history still enumerated");
            }
        }
        require(activeDeploymentCount == orderBookCount, "active history count divergence");
    }

    function _assertFactoryConfiguration() private view {
        require(factory.owner() == address(handler), "factory owner changed");
        require(factory.pendingOwner() == address(0), "unexpected pending factory owner");
        require(address(factory.orderBookDeployer()) == address(handler.deployer()), "deployer changed");
        require(
            address(factory.orderBookDeployer()).codehash == expectedDeployerCodeHash, "unexpected deployer bytecode"
        );
        require(
            factory.defaultOrderBookOwner() == handler.expectedDefaultOrderBookOwner(), "default owner model divergence"
        );
        require(
            address(factory.defaultFeeController()) == handler.expectedDefaultFeeController(),
            "default controller model divergence"
        );
        require(factory.maximumMakerFeeBps() == 100, "maker cap changed");
        require(factory.maximumTakerFeeBps() == 100, "taker cap changed");
        require(factory.maximumPageSize() == 100, "page size changed");
    }

    // Only factory actions are targeted, so mutable book governance must remain unchanged during these runs.
    function _assertCreatedBooks() private view {
        uint256 deploymentCount = handler.deploymentCount();
        for (uint256 i; i < deploymentCount; ++i) {
            (
                address orderBookAddress,
                address baseToken,
                address quoteToken,
                address owner,
                address feeController,
                uint256 feeControllerDelay
            ) = handler.deploymentAt(i);
            OrderBookWithFeeController orderBook = OrderBookWithFeeController(orderBookAddress);
            require(orderBookAddress.code.length != 0, "deployed book has no code");
            require(orderBook.baseToken() == baseToken, "deployed base changed");
            require(orderBook.quoteToken() == quoteToken, "deployed quote changed");
            require(orderBook.maximumMakerFeeBps() == 100, "deployed maker cap changed");
            require(orderBook.maximumTakerFeeBps() == 100, "deployed taker cap changed");
            require(orderBook.owner() == owner, "factory operation changed book owner");
            require(orderBook.pauseGuardian() == owner, "factory operation changed book guardian");
            require(address(orderBook.feeController()) == feeController, "factory operation changed controller");
            require(orderBook.feeControllerDelay() == feeControllerDelay, "factory operation changed controller delay");
        }
    }

    // Deterministically proves that the guarded handler reaches the important transitions hidden by no-op call counts.
    // solhint-disable-next-line func-name-mixedcase
    function test_transitionCoverageIncludesRecreationAndNonLastRemoval() public {
        handler.createOrderBook(0, 0);
        handler.createOrderBook(1, 0);
        handler.createOrderBook(2, 0);
        handler.removeOrderBook(1, 0);
        handler.updateDefaultOrderBookOwner(1);
        handler.updateDefaultFeeController(1);
        handler.createOrderBook(1, 0);

        require(handler.createAttempts() == 4, "unexpected create attempts");
        require(handler.successfulCreations() == 4, "creation path not covered");
        require(handler.recreations() == 1, "recreation path not covered");
        require(handler.removalAttempts() == 1, "unexpected removal attempts");
        require(handler.successfulRemovals() == 1, "removal path not covered");
        require(handler.nonLastRemovals() == 1, "non-last removal path not covered");
        require(handler.ownerUpdateAttempts() == 1, "unexpected owner update attempts");
        require(handler.effectiveOwnerChanges() == 1, "owner change path not covered");
        require(handler.controllerUpdateAttempts() == 1, "unexpected controller update attempts");
        require(handler.effectiveControllerChanges() == 1, "controller change path not covered");

        (,,, address owner, address feeController,) = handler.deploymentAt(3);
        require(owner == handler.expectedDefaultOrderBookOwner(), "new book owner did not use changed default");
        require(
            feeController == handler.expectedDefaultFeeController(), "new book controller did not use changed default"
        );
    }

    function _readPaginatedEnumeration(uint256 orderBookCount) private view returns (address[] memory orderBooks) {
        orderBooks = new address[](orderBookCount);
        uint256 cursor;
        uint256 enumeratedCount;
        uint256 iterations;
        while (true) {
            require(iterations++ <= orderBookCount + 1, "pagination did not terminate");
            (address[] memory page, uint256 nextCursor) = factory.getOrderBooks(cursor, PAGINATION_TEST_SIZE);
            require(page.length <= PAGINATION_TEST_SIZE, "pagination limit exceeded");
            require(enumeratedCount + page.length <= orderBookCount, "pagination exceeded expected count");
            for (uint256 i; i < page.length; ++i) {
                orderBooks[enumeratedCount + i] = page[i];
            }
            enumeratedCount += page.length;
            if (nextCursor == 0) break;
            require(nextCursor == enumeratedCount, "pagination cursor divergence");
            require(nextCursor > cursor, "pagination cursor did not advance");
            cursor = nextCursor;
        }
        require(enumeratedCount == orderBookCount, "paginated count divergence");
    }

    function _contains(address[] memory values, address candidate) private pure returns (bool) {
        for (uint256 i; i < values.length; ++i) {
            if (values[i] == candidate) return true;
        }
        return false;
    }
}
