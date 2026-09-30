// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IPruvExecutor} from "@rex-shared/IPruvExecutor.sol";

/// @notice Test stand-in for PruvExecutor's external surface. Records executed/aborted
/// batchIds and emits the interface events; no bridging. INIT-2.
contract MockPruvExecutor is IPruvExecutor {
    mapping(uint64 => bool) public executed;
    mapping(uint64 => bool) public aborted;
    mapping(uint64 => bool) public redeemExecuted;
    mapping(uint64 => bool) public redeemAborted;

    function executeDeposit(uint64 batchId) external {
        executed[batchId] = true;
        emit SubDepositExecuted(batchId, 0, 0);
    }

    function abortDeposit(uint64 batchId) external {
        aborted[batchId] = true;
        emit SubDepositAborted(batchId);
    }

    function executeRedeem(uint64 batchId) external {
        redeemExecuted[batchId] = true;
        emit RedeemBatchFulfilled(batchId, 0);
    }

    function abortRedeem(uint64 batchId) external {
        redeemAborted[batchId] = true;
        emit RedeemBatchAborted(batchId);
    }

    uint64 public redeemDelay;

    function setRedeemDelay(uint64 d) external {
        redeemDelay = d;
        emit RedeemDelaySet(d);
    }

    function oldestOpenRedeem() external pure returns (uint64) {
        return 0;
    }

    function redeemTarget(uint64) external pure returns (uint256) {
        return 0;
    }
}
