// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {BPSOrderBookFeeController} from "../../contracts/BPSOrderBookFeeController.sol";
import {TakerFeeToken} from "../../contracts/interfaces/TakerFeeToken.sol";

contract BPSFeeControllerFactoryHarness {
    function deploy(address initialFeeRecipient) external returns (BPSOrderBookFeeController deployed) {
        deployed = new BPSOrderBookFeeController(
            25, 50, 100, 200, TakerFeeToken.QUOTE, initialFeeRecipient, 2 days, msg.sender
        );
    }
}
