// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";

import {BPSOrderBookFeeController} from "../contracts/BPSOrderBookFeeController.sol";
import {FeeQuote} from "../contracts/interfaces/FeeQuote.sol";
import {FeeRole} from "../contracts/interfaces/FeeRole.sol";
import {IBPSOrderBookFeeController} from "../contracts/interfaces/IBPSOrderBookFeeController.sol";
import {Side} from "../contracts/interfaces/Side.sol";
import {TakerFeeToken} from "../contracts/interfaces/TakerFeeToken.sol";
import {BPSFeeControllerFactoryHarness} from "./helpers/BPSFeeControllerFactoryHarness.sol";

interface VmBPSFeeController {
    function expectRevert() external;
    function expectRevert(bytes4 revertData) external;
    function expectRevert(bytes calldata revertData) external;
    function prank(address msgSender) external;
    function warp(uint256 newTimestamp) external;
}

contract BPSOrderBookFeeControllerTest {
    VmBPSFeeController private constant vm =
        VmBPSFeeController(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant MAKER = address(0xA11CE);
    address private constant TAKER = address(0xB0B);
    address private constant FEE_RECIPIENT = address(0xFEE);
    address private constant SECOND_FEE_RECIPIENT = address(0xFEE2);
    address private constant SETTLEMENT_RECIPIENT = address(0xD15C0);
    address private constant NEW_GOVERNANCE = address(0x600D);
    address private constant OUTSIDER = address(0xBAD);
    address private constant BASE_TOKEN = address(0xBA5E);
    address private constant QUOTE_TOKEN = address(0xC0DE);
    uint16 private constant MAXIMUM_MAKER_FEE_BPS = 100;
    uint16 private constant MAXIMUM_TAKER_FEE_BPS = 200;
    uint256 private constant DELAY = 2 days;

    BPSOrderBookFeeController private controller;
    uint256 private nonce;

    function setUp() public {
        controller = _deploy(25, 50, MAXIMUM_MAKER_FEE_BPS, MAXIMUM_TAKER_FEE_BPS, FEE_RECIPIENT, DELAY);
    }

    function testInitializesGovernanceAndConfiguration() public view {
        IBPSOrderBookFeeController readableController = controller;
        require(readableController.bpsDenominator() == 10_000, "denominator mismatch");
        require(readableController.makerFeeBps() == 25, "maker fee mismatch");
        require(readableController.takerFeeBps() == 50, "taker fee mismatch");
        require(readableController.maximumMakerFeeBps() == MAXIMUM_MAKER_FEE_BPS, "maker cap mismatch");
        require(readableController.maximumTakerFeeBps() == MAXIMUM_TAKER_FEE_BPS, "taker cap mismatch");
        require(readableController.takerFeeToken() == TakerFeeToken.QUOTE, "taker fee token mismatch");
        require(readableController.feeRecipient() == FEE_RECIPIENT, "recipient mismatch");
        require(readableController.getMinDelay() == DELAY, "delay mismatch");
        require(
            readableController.feeBpsForOrder(MAKER, TAKER, SETTLEMENT_RECIPIENT, FeeRole.MAKER) == 25,
            "maker rate mismatch"
        );
        require(
            readableController.feeBpsForOrder(MAKER, TAKER, SETTLEMENT_RECIPIENT, FeeRole.TAKER) == 50,
            "taker rate mismatch"
        );
        require(controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), address(controller)), "self admin missing");
        require(!controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), address(this)), "deployer retained admin");
        require(controller.hasRole(controller.PROPOSER_ROLE(), address(this)), "proposer missing");
        require(controller.hasRole(controller.CANCELLER_ROLE(), address(this)), "canceller missing");
        require(controller.hasRole(controller.EXECUTOR_ROLE(), address(0)), "execution is not open");
    }

    function testRejectsZeroGovernanceOrRecipient() public {
        vm.expectRevert(BPSOrderBookFeeController.ZeroAddress.selector);
        new BPSOrderBookFeeController(
            25, 50, MAXIMUM_MAKER_FEE_BPS, MAXIMUM_TAKER_FEE_BPS, TakerFeeToken.QUOTE, FEE_RECIPIENT, DELAY, address(0)
        );

        vm.expectRevert(BPSOrderBookFeeController.ZeroAddress.selector);
        new BPSOrderBookFeeController(
            25, 50, MAXIMUM_MAKER_FEE_BPS, MAXIMUM_TAKER_FEE_BPS, TakerFeeToken.QUOTE, address(0), DELAY, address(this)
        );
    }

    function testRejectsControllerAsInitialFeeRecipient() public {
        BPSFeeControllerFactoryHarness factory = new BPSFeeControllerFactoryHarness();
        bytes32 createHash = keccak256(abi.encodePacked(hex"d694", address(factory), hex"01"));
        // CREATE addresses use the low 20 bytes of the RLP hash.
        // forge-lint: disable-next-line(unsafe-typecast)
        address predictedController = address(uint160(uint256(createHash)));

        vm.expectRevert(BPSOrderBookFeeController.ZeroAddress.selector);
        factory.deploy(predictedController);
    }

    function testRejectsMinimumDelayOutsideBounds() public {
        vm.expectRevert(BPSOrderBookFeeController.ZeroMinimumDelay.selector);
        _deploy(25, 50, MAXIMUM_MAKER_FEE_BPS, MAXIMUM_TAKER_FEE_BPS, FEE_RECIPIENT, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                BPSOrderBookFeeController.MinimumDelayOutOfBounds.selector, 1 days - 1, 1 days, 30 days
            )
        );
        _deploy(25, 50, MAXIMUM_MAKER_FEE_BPS, MAXIMUM_TAKER_FEE_BPS, FEE_RECIPIENT, 1 days - 1);

        vm.expectRevert(
            abi.encodeWithSelector(
                BPSOrderBookFeeController.MinimumDelayOutOfBounds.selector, 30 days + 1, 1 days, 30 days
            )
        );
        _deploy(25, 50, MAXIMUM_MAKER_FEE_BPS, MAXIMUM_TAKER_FEE_BPS, FEE_RECIPIENT, 30 days + 1);
    }

    function testAcceptsMinimumDelayBounds() public {
        BPSOrderBookFeeController minimumDelayController =
            _deploy(25, 50, MAXIMUM_MAKER_FEE_BPS, MAXIMUM_TAKER_FEE_BPS, FEE_RECIPIENT, 1 days);
        BPSOrderBookFeeController maximumDelayController =
            _deploy(25, 50, MAXIMUM_MAKER_FEE_BPS, MAXIMUM_TAKER_FEE_BPS, FEE_RECIPIENT, 30 days);

        require(minimumDelayController.getMinDelay() == 1 days, "minimum delay rejected");
        require(maximumDelayController.getMinDelay() == 30 days, "maximum delay rejected");
    }

    function testRejectsInvalidInitialFeeConfiguration() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                BPSOrderBookFeeController.InvalidFeeConfiguration.selector, uint16(10_000), uint16(200)
            )
        );
        _deploy(25, 50, 10_000, MAXIMUM_TAKER_FEE_BPS, FEE_RECIPIENT, DELAY);

        vm.expectRevert(
            abi.encodeWithSelector(
                BPSOrderBookFeeController.InvalidFeeConfiguration.selector, uint16(100), uint16(10_000)
            )
        );
        _deploy(25, 50, MAXIMUM_MAKER_FEE_BPS, 10_000, FEE_RECIPIENT, DELAY);

        vm.expectRevert(
            abi.encodeWithSelector(BPSOrderBookFeeController.InvalidFeeConfiguration.selector, uint16(101), uint16(50))
        );
        _deploy(101, 50, MAXIMUM_MAKER_FEE_BPS, MAXIMUM_TAKER_FEE_BPS, FEE_RECIPIENT, DELAY);

        vm.expectRevert(
            abi.encodeWithSelector(BPSOrderBookFeeController.InvalidFeeConfiguration.selector, uint16(25), uint16(201))
        );
        _deploy(25, 201, MAXIMUM_MAKER_FEE_BPS, MAXIMUM_TAKER_FEE_BPS, FEE_RECIPIENT, DELAY);

        vm.expectRevert(
            abi.encodeWithSelector(
                BPSOrderBookFeeController.InvalidFeeConfiguration.selector, uint16(6_000), uint16(6_000)
            )
        );
        _deploy(6_000, 6_000, 6_000, 6_000, FEE_RECIPIENT, DELAY);
    }

    function testTimelockedFeeUpdatesAndRejectsInvalidRates() public {
        _execute(abi.encodeCall(controller.setFeeBps, (uint16(100), uint16(175))));
        require(controller.makerFeeBps() == 100 && controller.takerFeeBps() == 175, "fee update failed");

        bytes memory payload = abi.encodeCall(controller.setFeeBps, (uint16(101), uint16(175)));
        bytes32 salt = _schedule(payload);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(
            abi.encodeWithSelector(BPSOrderBookFeeController.InvalidFeeConfiguration.selector, uint16(101), uint16(175))
        );
        controller.execute(address(controller), 0, payload, bytes32(0), salt);
    }

    function testSetsClearsAndQueriesRoleOverrides() public {
        (bool initialIsSet, uint16 initialFeeBps) = controller.feeBpsOverrideOf(MAKER, FeeRole.MAKER);
        require(!initialIsSet && initialFeeBps == 0, "unexpected initial override");

        _execute(abi.encodeCall(controller.setFeeBpsOverride, (MAKER, FeeRole.MAKER, uint16(0))));
        _execute(abi.encodeCall(controller.setFeeBpsOverride, (SETTLEMENT_RECIPIENT, FeeRole.TAKER, uint16(175))));

        (bool makerIsSet, uint16 makerFeeBps) = controller.feeBpsOverrideOf(MAKER, FeeRole.MAKER);
        (bool takerIsSet, uint16 takerFeeBps) = controller.feeBpsOverrideOf(SETTLEMENT_RECIPIENT, FeeRole.TAKER);
        require(makerIsSet && makerFeeBps == 0, "maker exemption missing");
        require(takerIsSet && takerFeeBps == 175, "taker override missing");
        require(controller.feeBpsFor(MAKER, FeeRole.MAKER) == 0, "maker override not applied");
        require(controller.feeBpsFor(SETTLEMENT_RECIPIENT, FeeRole.TAKER) == 175, "taker override not applied");
        require(
            controller.feeBpsForOrder(MAKER, TAKER, SETTLEMENT_RECIPIENT, FeeRole.MAKER) == 0,
            "maker order rate mismatch"
        );

        _execute(abi.encodeCall(controller.clearFeeBpsOverride, (MAKER, FeeRole.MAKER)));
        (bool clearedIsSet, uint16 clearedFeeBps) = controller.feeBpsOverrideOf(MAKER, FeeRole.MAKER);
        require(!clearedIsSet && clearedFeeBps == 0, "override not cleared");
        require(controller.feeBpsFor(MAKER, FeeRole.MAKER) == controller.makerFeeBps(), "default not restored");
    }

    function testRejectsInvalidOverrideConfiguration() public {
        bytes memory zeroAccountPayload =
            abi.encodeCall(controller.setFeeBpsOverride, (address(0), FeeRole.MAKER, uint16(0)));
        bytes32 zeroAccountSalt = _schedule(zeroAccountPayload);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(BPSOrderBookFeeController.ZeroAddress.selector);
        controller.execute(address(controller), 0, zeroAccountPayload, bytes32(0), zeroAccountSalt);

        bytes memory excessiveMakerPayload =
            abi.encodeCall(controller.setFeeBpsOverride, (MAKER, FeeRole.MAKER, uint16(101)));
        bytes32 excessiveMakerSalt = _schedule(excessiveMakerPayload);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(abi.encodeWithSelector(BPSOrderBookFeeController.InvalidFeeBpsOverride.selector, uint16(101)));
        controller.execute(address(controller), 0, excessiveMakerPayload, bytes32(0), excessiveMakerSalt);

        bytes memory excessiveTakerPayload =
            abi.encodeCall(controller.setFeeBpsOverride, (TAKER, FeeRole.TAKER, uint16(201)));
        bytes32 excessiveTakerSalt = _schedule(excessiveTakerPayload);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(abi.encodeWithSelector(BPSOrderBookFeeController.InvalidFeeBpsOverride.selector, uint16(201)));
        controller.execute(address(controller), 0, excessiveTakerPayload, bytes32(0), excessiveTakerSalt);

        bytes memory clearZeroAccountPayload =
            abi.encodeCall(controller.clearFeeBpsOverride, (address(0), FeeRole.TAKER));
        bytes32 clearZeroAccountSalt = _schedule(clearZeroAccountPayload);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(BPSOrderBookFeeController.ZeroAddress.selector);
        controller.execute(address(controller), 0, clearZeroAccountPayload, bytes32(0), clearZeroAccountSalt);
    }

    function testUpdatesFeeRecipientAndRejectsInvalidRecipients() public {
        _execute(abi.encodeCall(controller.setFeeRecipient, (SECOND_FEE_RECIPIENT)));
        require(controller.feeRecipient() == SECOND_FEE_RECIPIENT, "recipient update failed");

        bytes memory zeroRecipientPayload = abi.encodeCall(controller.setFeeRecipient, (address(0)));
        bytes32 zeroRecipientSalt = _schedule(zeroRecipientPayload);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(BPSOrderBookFeeController.ZeroAddress.selector);
        controller.execute(address(controller), 0, zeroRecipientPayload, bytes32(0), zeroRecipientSalt);

        bytes memory selfRecipientPayload = abi.encodeCall(controller.setFeeRecipient, (address(controller)));
        bytes32 selfRecipientSalt = _schedule(selfRecipientPayload);
        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(BPSOrderBookFeeController.ZeroAddress.selector);
        controller.execute(address(controller), 0, selfRecipientPayload, bytes32(0), selfRecipientSalt);
    }

    function testQuotesMakerProceedsForBothSides() public view {
        FeeQuote memory sellMakerFee = _quote(Side.SELL, FeeRole.MAKER)[0];
        FeeQuote memory buyMakerFee = _quote(Side.BUY, FeeRole.MAKER)[0];

        require(sellMakerFee.token == QUOTE_TOKEN, "sell maker token mismatch");
        require(sellMakerFee.amount == 2_500_000, "sell maker amount mismatch");
        require(buyMakerFee.token == BASE_TOKEN, "buy maker token mismatch");
        require(buyMakerFee.amount == 250_000, "buy maker amount mismatch");
        require(sellMakerFee.recipient == FEE_RECIPIENT, "maker recipient mismatch");
    }

    function testQuotesTakerFeeInConfiguredToken() public {
        FeeQuote memory quoteTokenFee = _quote(Side.BUY, FeeRole.TAKER)[0];
        require(quoteTokenFee.token == QUOTE_TOKEN && quoteTokenFee.amount == 5_000_000, "quote fee mismatch");

        _execute(abi.encodeCall(controller.setTakerFeeToken, (TakerFeeToken.BASE)));
        FeeQuote memory baseTokenFee = _quote(Side.SELL, FeeRole.TAKER)[0];
        require(baseTokenFee.token == BASE_TOKEN && baseTokenFee.amount == 500_000, "base fee mismatch");
    }

    function testQuotesRoundDownAndReturnEmptyForExemption() public {
        _execute(abi.encodeCall(controller.setFeeBps, (uint16(1), uint16(1))));
        FeeQuote[] memory roundedQuotes =
            controller.quoteOrderFee(MAKER, TAKER, TAKER, Side.SELL, FeeRole.TAKER, BASE_TOKEN, 1, QUOTE_TOKEN, 9_999);
        require(roundedQuotes.length == 1 && roundedQuotes[0].amount == 0, "rounding mismatch");

        _execute(abi.encodeCall(controller.setFeeBpsOverride, (TAKER, FeeRole.TAKER, uint16(0))));
        FeeQuote[] memory exemptQuotes = _quote(Side.SELL, FeeRole.TAKER);
        require(exemptQuotes.length == 0, "exemption did not suppress quote");
    }

    function testFeeRoundingIsIndependentForEachFill() public {
        _execute(abi.encodeCall(controller.setFeeBps, (uint16(100), uint16(50))));

        FeeQuote[] memory aggregateQuote =
            controller.quoteOrderFee(MAKER, TAKER, TAKER, Side.SELL, FeeRole.MAKER, BASE_TOKEN, 100, QUOTE_TOKEN, 100);
        require(aggregateQuote.length == 1 && aggregateQuote[0].amount == 1, "aggregate fee mismatch");

        uint256 splitFee;
        for (uint256 i = 0; i < 100; ++i) {
            FeeQuote[] memory splitQuote =
                controller.quoteOrderFee(MAKER, TAKER, TAKER, Side.SELL, FeeRole.MAKER, BASE_TOKEN, 1, QUOTE_TOKEN, 1);
            splitFee += splitQuote[0].amount;
        }
        require(splitFee == 0, "split fee should round independently");
    }

    function testSettlementRecipientOverridePrecedenceAndFallback() public {
        _execute(abi.encodeCall(controller.setFeeBpsOverride, (TAKER, FeeRole.TAKER, uint16(10))));
        _execute(abi.encodeCall(controller.setFeeBpsOverride, (SETTLEMENT_RECIPIENT, FeeRole.TAKER, uint16(20))));

        FeeQuote[] memory recipientQuotes = controller.quoteOrderFee(
            MAKER, TAKER, SETTLEMENT_RECIPIENT, Side.SELL, FeeRole.TAKER, BASE_TOKEN, 100e6, QUOTE_TOKEN, 1_000e6
        );
        FeeQuote[] memory payerQuotes = controller.quoteOrderFee(
            MAKER, TAKER, address(0), Side.SELL, FeeRole.TAKER, BASE_TOKEN, 100e6, QUOTE_TOKEN, 1_000e6
        );
        require(
            controller.feeBpsForOrder(MAKER, TAKER, SETTLEMENT_RECIPIENT, FeeRole.TAKER) == 20,
            "recipient effective rate mismatch"
        );
        require(
            controller.feeBpsForOrder(MAKER, TAKER, address(0), FeeRole.TAKER) == 10, "payer effective rate mismatch"
        );
        require(recipientQuotes[0].amount == 2_000_000, "recipient override did not win");
        require(payerQuotes[0].amount == 1_000_000, "payer override fallback failed");
    }

    function testRejectsZeroQuoteTokens() public {
        vm.expectRevert(BPSOrderBookFeeController.ZeroAddress.selector);
        controller.quoteOrderFee(MAKER, TAKER, TAKER, Side.SELL, FeeRole.TAKER, address(0), 100e6, QUOTE_TOKEN, 1_000e6);

        vm.expectRevert(BPSOrderBookFeeController.ZeroAddress.selector);
        controller.quoteOrderFee(MAKER, TAKER, TAKER, Side.SELL, FeeRole.TAKER, BASE_TOKEN, 100e6, address(0), 1_000e6);
    }

    function testRejectsDirectConfiguration() public {
        vm.expectRevert(abi.encodeWithSelector(BPSOrderBookFeeController.OnlyTimelock.selector, address(this)));
        controller.setFeeBps(100, 175);
    }

    function testOnlyProposerCanScheduleAndOnlyCancellerCanCancel() public {
        bytes memory payload = abi.encodeCall(controller.setFeeBps, (uint16(100), uint16(175)));
        bytes32 salt = bytes32(++nonce);

        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, OUTSIDER, controller.PROPOSER_ROLE()
            )
        );
        vm.prank(OUTSIDER);
        controller.schedule(address(controller), 0, payload, bytes32(0), salt, DELAY);

        controller.schedule(address(controller), 0, payload, bytes32(0), salt, DELAY);
        bytes32 operationId = controller.hashOperation(address(controller), 0, payload, bytes32(0), salt);
        vm.expectRevert(
            abi.encodeWithSelector(
                IAccessControl.AccessControlUnauthorizedAccount.selector, OUTSIDER, controller.CANCELLER_ROLE()
            )
        );
        vm.prank(OUTSIDER);
        controller.cancel(operationId);

        controller.cancel(operationId);
        require(!controller.isOperation(operationId), "operation not cancelled");
        require(controller.makerFeeBps() == 25 && controller.takerFeeBps() == 50, "cancelled update applied");
    }

    function testOpenExecutorCanExecuteAfterButNotBeforeDelay() public {
        bytes memory payload = abi.encodeCall(controller.setFeeBps, (uint16(100), uint16(175)));
        bytes32 salt = _schedule(payload);

        vm.expectRevert();
        vm.prank(OUTSIDER);
        controller.execute(address(controller), 0, payload, bytes32(0), salt);

        vm.warp(block.timestamp + DELAY);
        vm.prank(OUTSIDER);
        controller.execute(address(controller), 0, payload, bytes32(0), salt);
        require(controller.makerFeeBps() == 100 && controller.takerFeeBps() == 175, "open execution failed");
    }

    function testRotatesGovernanceRolesThroughTimelock() public {
        _execute(abi.encodeCall(controller.grantRole, (controller.PROPOSER_ROLE(), NEW_GOVERNANCE)));
        _execute(abi.encodeCall(controller.grantRole, (controller.CANCELLER_ROLE(), NEW_GOVERNANCE)));
        require(controller.hasRole(controller.PROPOSER_ROLE(), NEW_GOVERNANCE), "new proposer missing");
        require(controller.hasRole(controller.CANCELLER_ROLE(), NEW_GOVERNANCE), "new canceller missing");

        bytes memory revokeProposer = abi.encodeCall(controller.revokeRole, (controller.PROPOSER_ROLE(), address(this)));
        bytes32 proposerSalt = bytes32(++nonce);
        vm.prank(NEW_GOVERNANCE);
        controller.schedule(address(controller), 0, revokeProposer, bytes32(0), proposerSalt, DELAY);

        bytes memory revokeCanceller =
            abi.encodeCall(controller.revokeRole, (controller.CANCELLER_ROLE(), address(this)));
        bytes32 cancellerSalt = bytes32(++nonce);
        vm.prank(NEW_GOVERNANCE);
        controller.schedule(address(controller), 0, revokeCanceller, bytes32(0), cancellerSalt, DELAY);

        vm.warp(block.timestamp + DELAY);
        controller.execute(address(controller), 0, revokeProposer, bytes32(0), proposerSalt);
        controller.execute(address(controller), 0, revokeCanceller, bytes32(0), cancellerSalt);

        require(!controller.hasRole(controller.PROPOSER_ROLE(), address(this)), "old proposer retained");
        require(!controller.hasRole(controller.CANCELLER_ROLE(), address(this)), "old canceller retained");
        require(controller.hasRole(controller.PROPOSER_ROLE(), NEW_GOVERNANCE), "rotation lost proposer");
        require(controller.hasRole(controller.CANCELLER_ROLE(), NEW_GOVERNANCE), "rotation lost canceller");
    }

    function testRejectsTimelockDelayChanges() public {
        bytes memory payload = abi.encodeCall(controller.updateDelay, (uint256(1 days)));
        bytes32 salt = _schedule(payload);

        vm.warp(block.timestamp + DELAY);
        vm.expectRevert(BPSOrderBookFeeController.MinimumDelayImmutable.selector);
        controller.execute(address(controller), 0, payload, bytes32(0), salt);
        require(controller.getMinDelay() == DELAY, "delay changed");
    }

    function _quote(Side side, FeeRole feeRole) private view returns (FeeQuote[] memory) {
        return controller.quoteOrderFee(MAKER, TAKER, TAKER, side, feeRole, BASE_TOKEN, 100e6, QUOTE_TOKEN, 1_000e6);
    }

    function _schedule(bytes memory payload) private returns (bytes32 salt) {
        salt = bytes32(++nonce);
        controller.schedule(address(controller), 0, payload, bytes32(0), salt, DELAY);
    }

    function _execute(bytes memory payload) private {
        bytes32 salt = _schedule(payload);
        vm.warp(block.timestamp + DELAY);
        controller.execute(address(controller), 0, payload, bytes32(0), salt);
    }

    function _deploy(
        uint16 initialMakerFeeBps,
        uint16 initialTakerFeeBps,
        uint16 maximumMakerFeeBps,
        uint16 maximumTakerFeeBps,
        address initialFeeRecipient,
        uint256 minimumDelay
    ) private returns (BPSOrderBookFeeController deployed) {
        deployed = new BPSOrderBookFeeController(
            initialMakerFeeBps,
            initialTakerFeeBps,
            maximumMakerFeeBps,
            maximumTakerFeeBps,
            TakerFeeToken.QUOTE,
            initialFeeRecipient,
            minimumDelay,
            address(this)
        );
    }
}
