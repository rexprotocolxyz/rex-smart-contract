// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

/// @notice Stands in for a deployed REXPrimary in REXRegistryV2 tests: the three getters `register`
/// reads PLUS the seven the unregister predicate reads, each individually settable so a test can
/// make exactly one of them non-empty.
contract MockREXPrimaryEmptiness {
    address public wrwaRoute;
    uint32 public pruvDomain;
    mapping(uint32 => bytes32) public remoteRouter;

    uint8 public state;
    uint256 public heldEscrowUSDC;
    uint256 public settledRedeemUSDC;
    uint256 public liveRedeemEscrow;
    uint256 public settledUnclaimed;
    uint64 public outstandingSubBatches;
    uint64 public outstandingRedeemBatches;

    constructor(address wrwaRoute_, uint32 pruvDomain_) {
        wrwaRoute = wrwaRoute_;
        pruvDomain = pruvDomain_;
    }

    function setRemoteRouter(uint32 domain, bytes32 router) external {
        remoteRouter[domain] = router;
    }

    /// @dev The all-empty, ShutDown state the predicate accepts.
    function makeEmpty() external {
        state = 4; // LifecycleState.ShutDown
        heldEscrowUSDC = 0;
        settledRedeemUSDC = 0;
        liveRedeemEscrow = 0;
        settledUnclaimed = 0;
        outstandingSubBatches = 0;
        outstandingRedeemBatches = 0;
    }

    function setState(uint8 v) external {
        state = v;
    }

    function setHeldEscrowUSDC(uint256 v) external {
        heldEscrowUSDC = v;
    }

    function setSettledRedeemUSDC(uint256 v) external {
        settledRedeemUSDC = v;
    }

    function setLiveRedeemEscrow(uint256 v) external {
        liveRedeemEscrow = v;
    }

    function setSettledUnclaimed(uint256 v) external {
        settledUnclaimed = v;
    }

    function setOutstandingSubBatches(uint64 v) external {
        outstandingSubBatches = v;
    }

    function setOutstandingRedeemBatches(uint64 v) external {
        outstandingRedeemBatches = v;
    }
}
