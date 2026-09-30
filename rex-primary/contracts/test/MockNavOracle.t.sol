// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {MockNavOracle} from "@rex-shared-mocks/MockNavOracle.sol";
import {MockPruvExecutor} from "@rex-shared-mocks/MockPruvExecutor.sol";

contract MockNavOracleTest is Test {
    function test_reports_a_non_unit_nav_and_updates() public {
        MockNavOracle oracle = new MockNavOracle(1.05e18);
        assertEq(oracle.nav(), 1.05e18, "constructor NAV");
        oracle.setNav(0.98e18);
        assertEq(oracle.nav(), 0.98e18, "settable, non-1:1");
    }

    function test_can_force_a_stale_timestamp() public {
        MockNavOracle oracle = new MockNavOracle(1e18);
        oracle.setNav(1e18, 1000);
        assertEq(oracle.lastUpdated(), 1000, "explicit timestamp for staleness tests");
    }
}

contract MockPruvExecutorTest is Test {
    function test_executeDeposit_records_the_batch() public {
        MockPruvExecutor exec = new MockPruvExecutor();
        assertFalse(exec.executed(1));
        exec.executeDeposit(1);
        assertTrue(exec.executed(1), "the stand-in records the poked batch");
    }
}
