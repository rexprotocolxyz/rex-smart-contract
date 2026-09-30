// SPDX-License-Identifier: MIT
pragma solidity 0.8.36;

import {IGovernedOrderBookFeeController} from "../../contracts/interfaces/IGovernedOrderBookFeeController.sol";
import {IOrderBookAdministration} from "../../contracts/interfaces/IOrderBookAdministration.sol";
import {OrderBookWithFeeController} from "../../contracts/OrderBookWithFeeController.sol";

interface VmGovernanceHandler {
    function prank(address msgSender) external;
    function warp(uint256 newTimestamp) external;
}

/// @notice Stateful invariant actions and ghost state for controller and lifecycle governance.
contract OrderBookGovernanceHandler {
    VmGovernanceHandler private constant vm =
        VmGovernanceHandler(address(uint160(uint256(keccak256("hevm cheat code")))));

    address private constant OWNER = address(0x0A11CE);
    uint48 private constant MINIMUM_LEGACY_MODE_DELAY = 7 days;
    uint48 private constant MAXIMUM_ADDITIONAL_LEGACY_MODE_DELAY = 30 days;

    OrderBookWithFeeController public immutable orderBook;
    IGovernedOrderBookFeeController private immutable _controllerA;
    IGovernedOrderBookFeeController private immutable _controllerB;

    uint48 public expectedLegacyModeActivationTime;
    uint48 public legacyModeDeadlineAtExecution;
    uint256 public orderCountAtLegacyModeActivation;
    uint256 public matureLegacyModeCancellationCount;
    bool public legacyModeEverEntered;
    bool public legacyModeActivatedBeforeDeadline;
    bool public legacyModeActivatedWithoutSchedule;

    constructor(
        OrderBookWithFeeController orderBook_,
        IGovernedOrderBookFeeController controllerA,
        IGovernedOrderBookFeeController controllerB
    ) {
        orderBook = orderBook_;
        _controllerA = controllerA;
        _controllerB = controllerB;
    }

    function transitionFeeController(uint256 controllerSeed) external {
        IGovernedOrderBookFeeController pendingController = orderBook.pendingFeeController();
        if (address(pendingController) != address(0)) {
            uint256 executeAfter = orderBook.feeControllerUpdateTime();
            if (block.timestamp < executeAfter) vm.warp(executeAfter);
            orderBook.executeFeeControllerUpdate();
            return;
        }

        IGovernedOrderBookFeeController nextController = controllerSeed % 2 == 0 ? _controllerA : _controllerB;
        if (address(nextController) == address(orderBook.feeController())) return;

        vm.prank(OWNER);
        orderBook.scheduleFeeControllerUpdate(nextController);
    }

    function scheduleLegacyMode(uint256 delaySeed) external {
        if (orderBook.legacyMode() || expectedLegacyModeActivationTime != 0) return;
        uint48 additionalDelay = uint48(delaySeed % (MAXIMUM_ADDITIONAL_LEGACY_MODE_DELAY + 1));
        uint48 requestedDelay = MINIMUM_LEGACY_MODE_DELAY + additionalDelay;
        if (block.timestamp > type(uint48).max - requestedDelay) return;

        uint48 expectedExecuteAfter = uint48(block.timestamp + requestedDelay);
        vm.prank(OWNER);
        orderBook.scheduleLegacyMode(expectedExecuteAfter);
        expectedLegacyModeActivationTime = expectedExecuteAfter;

        require(orderBook.legacyModeActivationTime() == expectedExecuteAfter, "unexpected legacy activation deadline");
        _observeLegacyMode();
    }

    function cancelLegacyModeSchedule(uint256 maturitySeed) external {
        uint48 executeAfter = expectedLegacyModeActivationTime;
        if (orderBook.legacyMode() || executeAfter == 0) return;
        if (maturitySeed % 2 != 0 && block.timestamp < executeAfter) vm.warp(executeAfter);

        bool cancelledAfterMaturity = block.timestamp >= executeAfter;
        vm.prank(OWNER);
        orderBook.cancelLegacyModeSchedule();
        expectedLegacyModeActivationTime = 0;
        if (cancelledAfterMaturity) ++matureLegacyModeCancellationCount;

        require(orderBook.legacyModeActivationTime() == 0, "cancelled legacy schedule retained deadline");
        require(!orderBook.legacyMode(), "legacy mode entered during cancellation");
    }

    function executeLegacyMode(uint256 timingSeed) external {
        uint48 executeAfter = expectedLegacyModeActivationTime;
        if (orderBook.legacyMode() || executeAfter == 0) return;

        if (block.timestamp < executeAfter && timingSeed % 2 == 0) {
            try orderBook.executeLegacyMode() {
                _observeLegacyMode();
                require(orderBook.legacyMode(), "legacy execution succeeded without activation");
            } catch (bytes memory reason) {
                bytes memory expectedReason = abi.encodeWithSelector(
                    IOrderBookAdministration.LegacyModeNotReady.selector, executeAfter, block.timestamp
                );
                require(keccak256(reason) == keccak256(expectedReason), "unexpected premature legacy execution revert");
            }
            return;
        }

        if (block.timestamp < executeAfter) vm.warp(executeAfter);
        orderBook.executeLegacyMode();
        _observeLegacyMode();
        expectedLegacyModeActivationTime = 0;

        require(orderBook.legacyMode(), "mature legacy schedule did not activate");
        require(orderBook.legacyModeActivationTime() == 0, "executed legacy schedule retained deadline");
    }

    function warpToLegacyModeMaturity() external {
        uint48 executeAfter = expectedLegacyModeActivationTime;
        if (orderBook.legacyMode() || executeAfter == 0 || block.timestamp >= executeAfter) return;
        vm.warp(executeAfter);
    }

    function _observeLegacyMode() private {
        if (!orderBook.legacyMode() || legacyModeEverEntered) return;

        legacyModeEverEntered = true;
        uint48 executeAfter = expectedLegacyModeActivationTime;
        legacyModeDeadlineAtExecution = executeAfter;
        orderCountAtLegacyModeActivation = orderBook.orderCount();
        if (executeAfter == 0) {
            legacyModeActivatedWithoutSchedule = true;
        } else if (block.timestamp < executeAfter) {
            legacyModeActivatedBeforeDeadline = true;
        }
    }
}
