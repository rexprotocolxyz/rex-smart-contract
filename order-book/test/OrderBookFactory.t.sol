// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";

import {OrderBookDeployer} from "../contracts/OrderBookDeployer.sol";
import {OrderBookFactory} from "../contracts/OrderBookFactory.sol";
import {OrderBookWithFeeController} from "../contracts/OrderBookWithFeeController.sol";
import {IBaseOrderBook} from "../contracts/interfaces/IBaseOrderBook.sol";
import {IOrderBookFactory} from "../contracts/interfaces/IOrderBookFactory.sol";
import {IOrderBookWithFeeControllerFactory} from "../contracts/interfaces/IOrderBookWithFeeControllerFactory.sol";
import {IGovernedOrderBookFeeController} from "../contracts/interfaces/IGovernedOrderBookFeeController.sol";
import {Side} from "../contracts/interfaces/Side.sol";
import {MockCounterfeitOrderBook} from "./mocks/MockCounterfeitOrderBook.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockOrderBookFeeController} from "./mocks/MockOrderBookFeeController.sol";

interface VmFactory {
    function assume(bool condition) external pure;
    function expectEmit(bool checkTopic1, bool checkTopic2, bool checkTopic3, bool checkData, address emitter) external;
    function expectRevert() external;
    function expectRevert(bytes calldata revertData) external;
    function prank(address msgSender) external;
}

contract OrderBookFactoryTest {
    VmFactory private constant vm = VmFactory(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant BOOK_OWNER = address(0xB00C);
    address private constant NEW_BOOK_OWNER = address(0xB00D);
    address private constant NEW_FACTORY_OWNER = address(0xA11CE);
    address private constant UNAUTHORIZED = address(0xBAD);
    address private constant MAKER = address(0xCAFE);
    uint16 private constant MAXIMUM_MAKER_FEE_BPS = 100;
    uint16 private constant MAXIMUM_TAKER_FEE_BPS = 100;

    event OrderBookCreated(address indexed baseToken, address indexed quoteToken, address indexed orderBook);
    event OrderBookDeploymentConfigured(
        address indexed orderBook,
        address indexed owner,
        address indexed feeController,
        uint16 maximumMakerFeeBps,
        uint16 maximumTakerFeeBps
    );

    MockERC20 private baseOne;
    MockERC20 private baseTwo;
    MockERC20 private baseThree;
    MockERC20 private quoteOne;
    MockOrderBookFeeController private feeController;
    OrderBookDeployer private deployer;
    OrderBookFactory private factory;

    function setUp() public {
        baseOne = new MockERC20();
        baseTwo = new MockERC20();
        baseThree = new MockERC20();
        quoteOne = new MockERC20();
        feeController = new MockOrderBookFeeController(1 days);
        factory = _deployFactory(BOOK_OWNER, feeController);
        deployer = OrderBookDeployer(address(factory.orderBookDeployer()));
    }

    function testInitializesOwnershipAndConfiguration() public view {
        require(factory.owner() == address(this), "factory owner mismatch");
        require(address(factory.orderBookDeployer()) == address(deployer), "deployer mismatch");
        require(factory.defaultOrderBookOwner() == BOOK_OWNER, "book owner mismatch");
        require(address(factory.defaultFeeController()) == address(feeController), "controller mismatch");
        require(factory.maximumMakerFeeBps() == MAXIMUM_MAKER_FEE_BPS, "maker cap mismatch");
        require(factory.maximumTakerFeeBps() == MAXIMUM_TAKER_FEE_BPS, "taker cap mismatch");
    }

    function testFactoryCreatesReviewedDeployer() public {
        OrderBookDeployer referenceDeployer = new OrderBookDeployer();

        require(address(deployer) != address(referenceDeployer), "deployer not dedicated");
        require(address(deployer).codehash == address(referenceDeployer).codehash, "unexpected deployer bytecode");
    }

    function testCreatesConfiguredOrderBookAndRegistersBothPairOrientations() public {
        vm.expectEmit(false, true, true, true, address(factory));
        emit OrderBookDeploymentConfigured(
            address(0), BOOK_OWNER, address(feeController), MAXIMUM_MAKER_FEE_BPS, MAXIMUM_TAKER_FEE_BPS
        );
        vm.expectEmit(true, true, false, false, address(factory));
        emit OrderBookCreated(address(baseOne), address(quoteOne), address(0));
        address orderBookAddress = factory.createOrderBook(address(baseOne), address(quoteOne));
        OrderBookWithFeeController orderBook = OrderBookWithFeeController(orderBookAddress);

        require(orderBook.baseToken() == address(baseOne), "base mismatch");
        require(orderBook.quoteToken() == address(quoteOne), "quote mismatch");
        require(orderBook.owner() == BOOK_OWNER, "deployed owner mismatch");
        require(address(orderBook.feeController()) == address(feeController), "deployed controller mismatch");
        require(orderBook.maximumMakerFeeBps() == MAXIMUM_MAKER_FEE_BPS, "deployed maker cap mismatch");
        require(orderBook.maximumTakerFeeBps() == MAXIMUM_TAKER_FEE_BPS, "deployed taker cap mismatch");
        require(factory.orderBookFor(address(baseOne), address(quoteOne)) == orderBookAddress, "forward lookup");
        require(factory.orderBookFor(address(quoteOne), address(baseOne)) == orderBookAddress, "reverse lookup");
        require(factory.isOrderBook(orderBookAddress), "book not registered");
        require(factory.orderBookCount() == 1, "book count mismatch");
        require(factory.orderBookAt(0) == orderBookAddress, "book enumeration mismatch");
    }

    function testOwnerSelectsQuoteTokenAtMarketCreation() public {
        address orderBookAddress = factory.createOrderBook(address(baseOne), address(baseTwo));
        OrderBookWithFeeController orderBook = OrderBookWithFeeController(orderBookAddress);

        require(orderBook.baseToken() == address(baseOne), "base mismatch");
        require(orderBook.quoteToken() == address(baseTwo), "owner-selected quote mismatch");
    }

    function testRestrictsAllFactoryMutationsToOwner() public {
        bytes memory unauthorized = abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, UNAUTHORIZED);

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(unauthorized);
        factory.createOrderBook(address(baseOne), address(quoteOne));

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(unauthorized);
        factory.removeOrderBook(address(baseOne), address(quoteOne));

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(unauthorized);
        factory.setDefaultOrderBookOwner(NEW_BOOK_OWNER);

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(unauthorized);
        factory.setDefaultFeeController(feeController);
    }

    function testTransfersFactoryOwnershipInTwoStepsAndDisablesRenunciation() public {
        factory.transferOwnership(NEW_FACTORY_OWNER);
        require(factory.owner() == address(this), "ownership changed early");
        require(factory.pendingOwner() == NEW_FACTORY_OWNER, "pending owner mismatch");

        vm.prank(UNAUTHORIZED);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, UNAUTHORIZED));
        factory.acceptOwnership();

        vm.prank(NEW_FACTORY_OWNER);
        factory.acceptOwnership();
        require(factory.owner() == NEW_FACTORY_OWNER, "ownership not accepted");

        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(this)));
        factory.setDefaultOrderBookOwner(NEW_BOOK_OWNER);

        vm.prank(NEW_FACTORY_OWNER);
        factory.setDefaultOrderBookOwner(NEW_BOOK_OWNER);

        vm.prank(NEW_FACTORY_OWNER);
        vm.expectRevert(
            abi.encodeWithSelector(IOrderBookWithFeeControllerFactory.OwnershipRenunciationDisabled.selector)
        );
        factory.renounceOwnership();
    }

    function testUpdatesDefaultsForFutureOrderBooksOnly() public {
        address firstBookAddress = factory.createOrderBook(address(baseOne), address(quoteOne));
        MockOrderBookFeeController newFeeController = new MockOrderBookFeeController(2 days);

        factory.setDefaultOrderBookOwner(NEW_BOOK_OWNER);
        factory.setDefaultFeeController(newFeeController);
        address secondBookAddress = factory.createOrderBook(address(baseTwo), address(quoteOne));

        OrderBookWithFeeController firstBook = OrderBookWithFeeController(firstBookAddress);
        OrderBookWithFeeController secondBook = OrderBookWithFeeController(secondBookAddress);
        require(firstBook.owner() == BOOK_OWNER, "existing owner changed");
        require(address(firstBook.feeController()) == address(feeController), "existing controller changed");
        require(secondBook.owner() == NEW_BOOK_OWNER, "future owner not applied");
        require(address(secondBook.feeController()) == address(newFeeController), "future controller not applied");
    }

    function testRejectsInvalidPairs() public {
        vm.expectRevert(abi.encodeWithSelector(IOrderBookFactory.ZeroAddress.selector));
        factory.createOrderBook(address(0), address(quoteOne));

        vm.expectRevert(abi.encodeWithSelector(IOrderBookFactory.IdenticalTokens.selector, address(quoteOne)));
        factory.createOrderBook(address(quoteOne), address(quoteOne));

        vm.expectRevert(abi.encodeWithSelector(IOrderBookFactory.TokenIsNotContract.selector, UNAUTHORIZED));
        factory.createOrderBook(UNAUTHORIZED, address(quoteOne));
    }

    function testRejectsDuplicatePairInEitherOrientation() public {
        address orderBook = factory.createOrderBook(address(baseOne), address(quoteOne));

        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderBookFactory.OrderBookAlreadyExists.selector, address(quoteOne), address(baseOne), orderBook
            )
        );
        factory.createOrderBook(address(quoteOne), address(baseOne));
    }

    function testRemovesBookWithoutCallingItAndAllowsPairRecreation() public {
        address firstBookAddress = factory.createOrderBook(address(baseOne), address(quoteOne));
        address removed = factory.removeOrderBook(address(quoteOne), address(baseOne));

        require(removed == firstBookAddress, "removed address mismatch");
        require(factory.orderBookFor(address(baseOne), address(quoteOne)) == address(0), "forward not cleared");
        require(factory.orderBookFor(address(quoteOne), address(baseOne)) == address(0), "reverse not cleared");
        require(!factory.isOrderBook(firstBookAddress), "removed book remains registered");
        require(factory.orderBookCount() == 0, "removed book remains enumerated");

        _makeOrderOnRemovedBook(OrderBookWithFeeController(firstBookAddress));

        address replacement = factory.createOrderBook(address(baseOne), address(quoteOne));
        require(replacement != firstBookAddress, "pair recreation reused address");
        require(factory.orderBookFor(address(baseOne), address(quoteOne)) == replacement, "replacement missing");
    }

    function testSwapAndPopRemovalPreservesRegistryConsistency() public {
        address first = factory.createOrderBook(address(baseOne), address(quoteOne));
        address second = factory.createOrderBook(address(baseTwo), address(quoteOne));
        address third = factory.createOrderBook(address(baseThree), address(quoteOne));

        factory.removeOrderBook(address(baseTwo), address(quoteOne));

        require(factory.orderBookCount() == 2, "book count after removal");
        require(factory.orderBookAt(0) == first, "first book moved unexpectedly");
        require(factory.orderBookAt(1) == third, "last book not swapped");
        require(factory.orderBookFor(address(baseOne), address(quoteOne)) == first, "first lookup corrupted");
        require(factory.orderBookFor(address(baseThree), address(quoteOne)) == third, "third lookup corrupted");
        require(!factory.isOrderBook(second), "removed book remains active");
    }

    function testPaginatesOrderBooks() public {
        address firstBook = factory.createOrderBook(address(baseOne), address(quoteOne));
        address secondBook = factory.createOrderBook(address(baseTwo), address(quoteOne));
        address thirdBook = factory.createOrderBook(address(baseThree), address(quoteOne));
        (address[] memory firstBooks, uint256 nextBookCursor) = factory.getOrderBooks(0, 2);
        require(firstBooks.length == 2, "first book page size");
        require(firstBooks[0] == firstBook && firstBooks[1] == secondBook, "first book page");
        require(nextBookCursor == 2, "next book cursor");

        (address[] memory finalBooks, uint256 finalBookCursor) = factory.getOrderBooks(nextBookCursor, 2);
        require(finalBooks.length == 1 && finalBooks[0] == thirdBook, "final book page");
        require(finalBookCursor == 0, "final book cursor");

        (address[] memory emptyBooks, uint256 emptyCursor) = factory.getOrderBooks(99, 1);
        require(emptyBooks.length == 0 && emptyCursor == 0, "out-of-range page");
    }

    function testRejectsInvalidPagination() public {
        vm.expectRevert(abi.encodeWithSelector(IOrderBookFactory.InvalidPageSize.selector, 0, 100));
        factory.getOrderBooks(0, 0);

        vm.expectRevert(abi.encodeWithSelector(IOrderBookFactory.InvalidPageSize.selector, 101, 100));
        factory.getOrderBooks(0, 101);
    }

    function testRejectsInvalidConstructorAddressesAndFeeCaps() public {
        vm.expectRevert(abi.encodeWithSelector(IOrderBookFactory.ZeroAddress.selector));
        new OrderBookFactory(address(this), address(0), feeController, 100, 100);

        vm.expectRevert(
            abi.encodeWithSelector(IOrderBookWithFeeControllerFactory.InvalidMaximumMakerFeeBps.selector, 10_000)
        );
        new OrderBookFactory(address(this), BOOK_OWNER, feeController, 10_000, 100);

        vm.expectRevert(
            abi.encodeWithSelector(IOrderBookWithFeeControllerFactory.InvalidMaximumTakerFeeBps.selector, 10_000)
        );
        new OrderBookFactory(address(this), BOOK_OWNER, feeController, 100, 10_000);
    }

    function testRejectsPredictedFactoryAddressAsInitialOwner() public {
        vm.expectRevert(abi.encodeWithSelector(IOrderBookFactory.ZeroAddress.selector));
        new SelfOwnedOrderBookFactoryDeployment(BOOK_OWNER, feeController);
    }

    function testRejectsInvalidConstructorControllerCaps() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderBookWithFeeControllerFactory.FeeControllerFeeCapsExceedOrderBookMaximum.selector,
                address(feeController),
                100,
                100,
                99,
                100
            )
        );
        new OrderBookFactory(address(this), BOOK_OWNER, feeController, 99, 100);
    }

    function testRejectsInvalidDefaultUpdates() public {
        vm.expectRevert(abi.encodeWithSelector(IOrderBookFactory.ZeroAddress.selector));
        factory.setDefaultOrderBookOwner(address(0));

        vm.expectRevert(abi.encodeWithSelector(IOrderBookFactory.ZeroAddress.selector));
        factory.setDefaultOrderBookOwner(address(factory));

        vm.expectRevert(abi.encodeWithSelector(IOrderBookFactory.TokenIsNotContract.selector, UNAUTHORIZED));
        factory.setDefaultFeeController(IGovernedOrderBookFeeController(UNAUTHORIZED));

        MockOrderBookFeeController zeroDelayController = new MockOrderBookFeeController(0);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderBookWithFeeControllerFactory.FeeControllerHasNoTimelock.selector, address(zeroDelayController)
            )
        );
        factory.setDefaultFeeController(zeroDelayController);

        MockOrderBookFeeController shortDelayController = new MockOrderBookFeeController(1 days - 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderBookWithFeeControllerFactory.FeeControllerDelayOutOfBounds.selector,
                address(shortDelayController),
                1 days - 1,
                1 days,
                30 days
            )
        );
        factory.setDefaultFeeController(shortDelayController);

        MockOrderBookFeeController longDelayController = new MockOrderBookFeeController(30 days + 1);
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderBookWithFeeControllerFactory.FeeControllerDelayOutOfBounds.selector,
                address(longDelayController),
                30 days + 1,
                1 days,
                30 days
            )
        );
        factory.setDefaultFeeController(longDelayController);

        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderBookWithFeeControllerFactory.FeeControllerHasNoTimelock.selector, address(baseOne)
            )
        );
        factory.setDefaultFeeController(IGovernedOrderBookFeeController(address(baseOne)));
    }

    function testRejectsRemovalOfUnregisteredPair() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IOrderBookFactory.OrderBookNotRegistered.selector, address(baseOne), address(quoteOne)
            )
        );
        factory.removeOrderBook(address(baseOne), address(quoteOne));
    }

    function testDirectDeployerBooksAreNotCanonical() public {
        address independentlyDeployed = deployer.deployOrderBook(
            address(baseOne), address(quoteOne), BOOK_OWNER, feeController, MAXIMUM_MAKER_FEE_BPS, MAXIMUM_TAKER_FEE_BPS
        );

        require(independentlyDeployed.code.length != 0, "direct deployment failed");
        require(!factory.isOrderBook(independentlyDeployed), "direct book became canonical");
        require(factory.orderBookFor(address(baseOne), address(quoteOne)) == address(0), "registry mutated");
    }

    function testGetterCompatibleCounterfeitCannotBecomeCanonical() public {
        MockCounterfeitOrderBook counterfeit = new MockCounterfeitOrderBook(
            address(baseOne), address(quoteOne), BOOK_OWNER, feeController, MAXIMUM_MAKER_FEE_BPS, MAXIMUM_TAKER_FEE_BPS
        );
        require(counterfeit.baseToken() == address(baseOne), "counterfeit base mismatch");
        require(counterfeit.quoteToken() == address(quoteOne), "counterfeit quote mismatch");
        require(counterfeit.owner() == BOOK_OWNER, "counterfeit owner mismatch");
        require(address(counterfeit.feeController()) == address(feeController), "counterfeit controller mismatch");
        require(counterfeit.maximumMakerFeeBps() == MAXIMUM_MAKER_FEE_BPS, "counterfeit maker cap mismatch");
        require(counterfeit.maximumTakerFeeBps() == MAXIMUM_TAKER_FEE_BPS, "counterfeit taker cap mismatch");

        address canonical = factory.createOrderBook(address(baseOne), address(quoteOne));
        require(canonical != address(counterfeit), "counterfeit registered");
        require(factory.orderBookFor(address(baseOne), address(quoteOne)) == canonical, "canonical book missing");
        require(!factory.isOrderBook(address(counterfeit)), "counterfeit marked canonical");
    }

    function testFuzzPairKeyIsSymmetric(address tokenA, address tokenB) public view {
        vm.assume(tokenA != address(0) && tokenB != address(0) && tokenA != tokenB);
        require(factory.pairKey(tokenA, tokenB) == factory.pairKey(tokenB, tokenA), "asymmetric pair key");
    }

    function _makeOrderOnRemovedBook(OrderBookWithFeeController orderBook) private {
        uint256 baseAmount = 1e18;
        uint256 quoteAmount = 2e18;
        baseOne.mint(MAKER, baseAmount);
        vm.prank(MAKER);
        baseOne.approve(address(orderBook), baseAmount);
        vm.prank(MAKER);
        uint256 orderId = orderBook.makeOrder(
            IBaseOrderBook.MakeOrderParams({
                side: Side.SELL,
                totalBaseAmount: baseAmount,
                totalQuoteAmount: quoteAmount,
                minimumFillBaseAmount: 0,
                expiry: uint48(block.timestamp + 1 days)
            })
        );
        require(orderId == 1, "removed book is not operational");
    }

    function _deployFactory(address orderBookOwner, IGovernedOrderBookFeeController controller)
        private
        returns (OrderBookFactory deployedFactory)
    {
        deployedFactory = new OrderBookFactory(
            address(this), orderBookOwner, controller, MAXIMUM_MAKER_FEE_BPS, MAXIMUM_TAKER_FEE_BPS
        );
    }
}

contract SelfOwnedOrderBookFactoryDeployment {
    constructor(address orderBookOwner, IGovernedOrderBookFeeController controller) {
        // A newly created contract has nonce 1 before its first CREATE. Predicting that child address lets this
        // regression exercise initialOwner == address(factory), which cannot be expressed with a normal new call.
        address predictedFactory =
            address(uint160(uint256(keccak256(abi.encodePacked(hex"d694", address(this), hex"01")))));
        new OrderBookFactory(predictedFactory, orderBookOwner, controller, 100, 100);
    }
}
