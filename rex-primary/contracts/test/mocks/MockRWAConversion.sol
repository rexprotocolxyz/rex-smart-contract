// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IRWAConversion} from "../../src/NavReporter.sol";

/// @notice Test double for the PRUV NAV source (RWAFixedConversion): a settable value().
contract MockRWAConversion is IRWAConversion {
    uint256 private _value;

    constructor(uint256 initial) {
        _value = initial;
    }

    function setValue(uint256 v) external {
        _value = v;
    }

    function value() external view returns (uint256) {
        return _value;
    }
}
