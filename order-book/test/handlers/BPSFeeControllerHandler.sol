// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

import {BPSOrderBookFeeController} from "../../contracts/BPSOrderBookFeeController.sol";
import {FeeRole} from "../../contracts/interfaces/FeeRole.sol";
import {TakerFeeToken} from "../../contracts/interfaces/TakerFeeToken.sol";

interface VmBPSFeeControllerHandler {
    function warp(uint256 newTimestamp) external;
}

contract BPSFeeControllerHandler {
    VmBPSFeeControllerHandler private constant vm =
        VmBPSFeeControllerHandler(address(uint160(uint256(keccak256("hevm cheat code")))));

    address internal constant MAKER = address(0xA11CE);
    address internal constant TAKER = address(0xB0B);
    address internal constant SETTLEMENT_RECIPIENT = address(0xD15C0);
    address internal constant FEE_RECIPIENT_A = address(0xFEE1);
    address internal constant FEE_RECIPIENT_B = address(0xFEE2);
    address internal constant FEE_RECIPIENT_C = address(0xFEE3);

    BPSOrderBookFeeController public immutable controller;
    uint256 private immutable _delay;
    uint256 private _nonce;

    constructor(BPSOrderBookFeeController controller_) {
        controller = controller_;
        _delay = controller_.getMinDelay();
    }

    function setFeeBps(uint256 makerSeed, uint256 takerSeed) external {
        uint16 makerFeeBps = SafeCast.toUint16(makerSeed % (uint256(controller.maximumMakerFeeBps()) + 1));
        uint16 takerFeeBps = SafeCast.toUint16(takerSeed % (uint256(controller.maximumTakerFeeBps()) + 1));
        _execute(abi.encodeCall(controller.setFeeBps, (makerFeeBps, takerFeeBps)));
    }

    function setFeeBpsOverride(uint256 accountSeed, uint256 roleSeed, uint256 feeSeed) external {
        address account = _account(accountSeed);
        FeeRole feeRole = roleSeed % 2 == 0 ? FeeRole.MAKER : FeeRole.TAKER;
        uint16 maximumFeeBps =
            feeRole == FeeRole.MAKER ? controller.maximumMakerFeeBps() : controller.maximumTakerFeeBps();
        uint16 feeBps = SafeCast.toUint16(feeSeed % (uint256(maximumFeeBps) + 1));
        _execute(abi.encodeCall(controller.setFeeBpsOverride, (account, feeRole, feeBps)));
    }

    function clearFeeBpsOverride(uint256 accountSeed, uint256 roleSeed) external {
        address account = _account(accountSeed);
        FeeRole feeRole = roleSeed % 2 == 0 ? FeeRole.MAKER : FeeRole.TAKER;
        _execute(abi.encodeCall(controller.clearFeeBpsOverride, (account, feeRole)));
    }

    function setFeeRecipient(uint256 recipientSeed) external {
        _execute(abi.encodeCall(controller.setFeeRecipient, (_feeRecipient(recipientSeed))));
    }

    function setTakerFeeToken(uint256 tokenSeed) external {
        TakerFeeToken feeToken = tokenSeed % 2 == 0 ? TakerFeeToken.BASE : TakerFeeToken.QUOTE;
        _execute(abi.encodeCall(controller.setTakerFeeToken, (feeToken)));
    }

    function cancelFeeUpdate(uint256 makerSeed, uint256 takerSeed) external {
        uint16 makerFeeBps = SafeCast.toUint16(makerSeed % (uint256(controller.maximumMakerFeeBps()) + 1));
        uint16 takerFeeBps = SafeCast.toUint16(takerSeed % (uint256(controller.maximumTakerFeeBps()) + 1));
        bytes memory payload = abi.encodeCall(controller.setFeeBps, (makerFeeBps, takerFeeBps));
        bytes32 salt = bytes32(++_nonce);
        controller.schedule(address(controller), 0, payload, bytes32(0), salt, _delay);
        bytes32 operationId = controller.hashOperation(address(controller), 0, payload, bytes32(0), salt);
        controller.cancel(operationId);
        require(!controller.isOperation(operationId), "cancel failed");
    }

    function _execute(bytes memory payload) private {
        bytes32 salt = bytes32(++_nonce);
        controller.schedule(address(controller), 0, payload, bytes32(0), salt, _delay);
        vm.warp(block.timestamp + _delay);
        controller.execute(address(controller), 0, payload, bytes32(0), salt);
    }

    function _account(uint256 seed) private pure returns (address) {
        uint256 index = seed % 3;
        if (index == 0) return MAKER;
        if (index == 1) return TAKER;
        return SETTLEMENT_RECIPIENT;
    }

    function _feeRecipient(uint256 seed) private pure returns (address) {
        uint256 index = seed % 3;
        if (index == 0) return FEE_RECIPIENT_A;
        if (index == 1) return FEE_RECIPIENT_B;
        return FEE_RECIPIENT_C;
    }
}
