// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BPSOrderBookFeeController} from "../contracts/BPSOrderBookFeeController.sol";
import {FeeQuote} from "../contracts/interfaces/FeeQuote.sol";
import {FeeRole} from "../contracts/interfaces/FeeRole.sol";
import {Side} from "../contracts/interfaces/Side.sol";
import {TakerFeeToken} from "../contracts/interfaces/TakerFeeToken.sol";
import {BPSFeeControllerHandler} from "./handlers/BPSFeeControllerHandler.sol";

interface VmBPSFeeControllerInvariant {
    function warp(uint256 newTimestamp) external;
}

contract BPSOrderBookFeeControllerInvariantTest {
    VmBPSFeeControllerInvariant private constant vm =
        VmBPSFeeControllerInvariant(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant MAKER = address(0xA11CE);
    address private constant TAKER = address(0xB0B);
    address private constant SETTLEMENT_RECIPIENT = address(0xD15C0);
    address private constant INITIAL_FEE_RECIPIENT = address(0xFEE1);
    address private constant BASE_TOKEN = address(0xBA5E);
    address private constant QUOTE_TOKEN = address(0xC0DE);
    uint16 private constant MAXIMUM_MAKER_FEE_BPS = 100;
    uint16 private constant MAXIMUM_TAKER_FEE_BPS = 200;
    uint256 private constant DELAY = 1 days;
    uint256 private constant BASE_AMOUNT = 100e6;
    uint256 private constant QUOTE_AMOUNT = 1_000e6;

    BPSOrderBookFeeController private controller;
    BPSFeeControllerHandler private handler;
    address[] private _targetedContracts;
    uint256 private nonce;

    function setUp() public {
        controller = new BPSOrderBookFeeController(
            25,
            50,
            MAXIMUM_MAKER_FEE_BPS,
            MAXIMUM_TAKER_FEE_BPS,
            TakerFeeToken.QUOTE,
            INITIAL_FEE_RECIPIENT,
            DELAY,
            address(this)
        );
        handler = new BPSFeeControllerHandler(controller);
        _execute(abi.encodeCall(controller.grantRole, (controller.PROPOSER_ROLE(), address(handler))));
        _execute(abi.encodeCall(controller.grantRole, (controller.CANCELLER_ROLE(), address(handler))));
        _targetedContracts.push(address(handler));
    }

    function targetContracts() external view returns (address[] memory targetedContracts_) {
        return _targetedContracts;
    }

    // solhint-disable-next-line func-name-mixedcase
    function invariant_feeConfigurationRemainsWithinImmutableCaps() public view {
        require(controller.makerFeeBps() <= MAXIMUM_MAKER_FEE_BPS, "maker rate exceeds cap");
        require(controller.takerFeeBps() <= MAXIMUM_TAKER_FEE_BPS, "taker rate exceeds cap");
        require(uint256(controller.makerFeeBps()) + controller.takerFeeBps() <= 10_000, "combined rate invalid");

        _assertAccountRates(MAKER);
        _assertAccountRates(TAKER);
        _assertAccountRates(SETTLEMENT_RECIPIENT);
    }

    // solhint-disable-next-line func-name-mixedcase
    function invariant_governanceDelayAndRolesRemainHardened() public view {
        require(controller.getMinDelay() == DELAY, "governance delay changed");
        require(controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), address(controller)), "self admin lost");
        require(!controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), address(this)), "test retained admin");
        require(!controller.hasRole(controller.DEFAULT_ADMIN_ROLE(), address(handler)), "handler gained admin");
        require(controller.hasRole(controller.PROPOSER_ROLE(), address(handler)), "handler proposer lost");
        require(controller.hasRole(controller.CANCELLER_ROLE(), address(handler)), "handler canceller lost");
        require(controller.hasRole(controller.EXECUTOR_ROLE(), address(0)), "open executor lost");
    }

    // solhint-disable-next-line func-name-mixedcase
    function invariant_feeRecipientRemainsValid() public view {
        address recipient = controller.feeRecipient();
        require(recipient != address(0), "zero fee recipient");
        require(recipient != address(controller), "controller is fee recipient");
    }

    // solhint-disable-next-line func-name-mixedcase
    function invariant_quotesMatchCurrentConfiguration() public view {
        _assertQuote(Side.SELL, FeeRole.MAKER);
        _assertQuote(Side.BUY, FeeRole.MAKER);
        _assertQuote(Side.SELL, FeeRole.TAKER);
        _assertQuote(Side.BUY, FeeRole.TAKER);
    }

    function _assertAccountRates(address account) private view {
        (bool makerIsSet, uint16 makerOverride) = controller.feeBpsOverrideOf(account, FeeRole.MAKER);
        (bool takerIsSet, uint16 takerOverride) = controller.feeBpsOverrideOf(account, FeeRole.TAKER);
        require(!makerIsSet || makerOverride <= MAXIMUM_MAKER_FEE_BPS, "maker override exceeds cap");
        require(!takerIsSet || takerOverride <= MAXIMUM_TAKER_FEE_BPS, "taker override exceeds cap");
        require(controller.feeBpsFor(account, FeeRole.MAKER) <= MAXIMUM_MAKER_FEE_BPS, "maker rate invalid");
        require(controller.feeBpsFor(account, FeeRole.TAKER) <= MAXIMUM_TAKER_FEE_BPS, "taker rate invalid");
    }

    function _assertQuote(Side side, FeeRole feeRole) private view {
        uint16 feeBps = _expectedFeeBps(feeRole);
        (address expectedToken, uint256 basisAmount) = _expectedTokenAndBasis(side, feeRole);
        FeeQuote[] memory quotes = controller.quoteOrderFee(
            MAKER, TAKER, SETTLEMENT_RECIPIENT, side, feeRole, BASE_TOKEN, BASE_AMOUNT, QUOTE_TOKEN, QUOTE_AMOUNT
        );

        if (feeBps == 0) {
            require(quotes.length == 0, "zero rate returned a quote");
            return;
        }

        require(quotes.length == 1, "quote count mismatch");
        require(quotes[0].token == expectedToken, "fee token mismatch");
        require(quotes[0].recipient == controller.feeRecipient(), "fee recipient mismatch");
        require(quotes[0].amount == basisAmount * feeBps / 10_000, "fee amount mismatch");
    }

    function _expectedFeeBps(FeeRole feeRole) private view returns (uint16) {
        if (feeRole == FeeRole.MAKER) return controller.feeBpsFor(MAKER, feeRole);
        (bool recipientOverrideIsSet, uint16 recipientOverride) =
            controller.feeBpsOverrideOf(SETTLEMENT_RECIPIENT, feeRole);
        return recipientOverrideIsSet ? recipientOverride : controller.feeBpsFor(TAKER, feeRole);
    }

    function _expectedTokenAndBasis(Side side, FeeRole feeRole)
        private
        view
        returns (address token, uint256 basisAmount)
    {
        if (feeRole == FeeRole.MAKER) {
            return side == Side.SELL ? (QUOTE_TOKEN, QUOTE_AMOUNT) : (BASE_TOKEN, BASE_AMOUNT);
        }
        return
            controller.takerFeeToken() == TakerFeeToken.BASE ? (BASE_TOKEN, BASE_AMOUNT) : (QUOTE_TOKEN, QUOTE_AMOUNT);
    }

    function _execute(bytes memory payload) private {
        bytes32 salt = bytes32(++nonce);
        controller.schedule(address(controller), 0, payload, bytes32(0), salt, DELAY);
        vm.warp(block.timestamp + DELAY);
        controller.execute(address(controller), 0, payload, bytes32(0), salt);
    }
}
