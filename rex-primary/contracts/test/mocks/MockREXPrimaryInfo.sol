// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Stands in for a deployed REXPrimary in REXRegistry tests: exposes exactly the five
/// getters the registry reads (`IREXPrimaryInfo`), and lets a test MUTATE `remoteRouter` after
/// registration so the live-derivation behaviour can be asserted.
contract MockREXPrimaryInfo {
    address public wrwaRoute;
    uint32 public pruvDomain;
    address public navOracle;
    string public VERSION;

    mapping(uint32 => bytes32) public remoteRouter;

    constructor(address wrwaRoute_, uint32 pruvDomain_, address navOracle_, string memory version_) {
        wrwaRoute = wrwaRoute_;
        pruvDomain = pruvDomain_;
        navOracle = navOracle_;
        VERSION = version_;
    }

    function setRemoteRouter(uint32 domain, bytes32 router) external {
        remoteRouter[domain] = router;
    }
}
