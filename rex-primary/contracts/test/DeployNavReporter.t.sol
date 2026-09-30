// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import "forge-std/Test.sol";
import {DeployNavReporter} from "../script/DeployNavReporter.s.sol";
import {NavReporter} from "../src/NavReporter.sol";
import "@rex-shared-mocks/MockMailbox.sol";
import {MockRWAConversion} from "./mocks/MockRWAConversion.sol";

contract DeployNavReporterTest is Test {
    uint32 constant HOME_DOMAIN = 11155111;
    uint32 constant PRUV_DOMAIN = 7336;
    bytes32 constant CONSUMER = bytes32(uint256(uint160(0xCaaCB584ba961b8363BC7B59D3C44cE6d892D105)));

    DeployNavReporter internal script;
    MockMailbox internal mailbox;
    MockRWAConversion internal source;

    function setUp() public {
        script = new DeployNavReporter();
        mailbox = new MockMailbox(PRUV_DOMAIN);
        source = new MockRWAConversion(1e18);
    }

    function _networksJson() internal view returns (string memory) {
        return string.concat(
            '{"home":{"hyperlaneDomain":',
            vm.toString(uint256(HOME_DOMAIN)),
            '},"defaultFund":"evergreen","fund":{"contracts":{"mailbox":"',
            vm.toString(address(mailbox)),
            '","rwaConversion":"',
            vm.toString(address(source)),
            '"}}}'
        );
    }

    /// @dev The NAV source is per FUND (each fund token has its own `RWAConversion`), so the
    /// reporter reads it from the fund file, not from `networks.json`.
    function _paramsJson(string memory fundKey, address source_) internal pure returns (string memory) {
        return string.concat(
            '{"key":"',
            fundKey,
            '","contracts":{"rwaConversion":"',
            vm.toString(source_),
            '"},"navReporter":{"heartbeatSeconds":1800}}'
        );
    }

    function test_deploy_wiresFromConfig() public {
        NavReporter reporter = script.deploy(_networksJson(), _paramsJson("evergreen", address(source)), CONSUMER);
        assertEq(address(reporter.mailbox()), address(mailbox));
        assertEq(uint256(reporter.homeDomain()), HOME_DOMAIN);
        assertEq(reporter.consumer(), CONSUMER);
        assertEq(address(reporter.source()), address(source));
        assertEq(reporter.heartbeat(), 1800);
    }

    /// @dev A second fund reports ITS OWN NAV source, from its own fund file.
    function test_deploy_secondFundUsesItsOwnSource() public {
        MockRWAConversion sourceTwo = new MockRWAConversion(2e18);

        NavReporter reporter = script.deploy(_networksJson(), _paramsJson("fund-two", address(sourceTwo)), CONSUMER);

        assertEq(address(reporter.source()), address(sourceTwo));
        assertEq(address(reporter.mailbox()), address(mailbox), "mailbox is a chain fact");
    }
}
