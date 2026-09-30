// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {IMessageRecipient} from "@rex-shared/IHyperlane.sol";

/// @notice No-op Hyperlane inbound handler for the SC8a local devnet's relayer smoke check
/// ONLY (DeployDevnet.s.sol / ops/test/devnet.e2e.spec.ts) -- accepts any origin/sender/body
/// and never reverts. A real recipient (REXPrimary/PruvExecutor via BridgeAdapter.handle, or
/// NavOracleConsumer.handle) enforces an origin+sender rendezvous check that MockMailbox's
/// single-instance dispatch-then-process model cannot satisfy for an arbitrary synthetic test
/// message without also faking a full, correctly-enrolled cross-chain round trip (SC8b's job,
/// not this harness's -- see DeployDevnet.s.sol's doc comment). This mock exists so the devnet
/// harness can prove the relayer's DELIVERY mechanism (watch Dispatch -> call process)
/// independently of that business-logic correctness.
contract MockMessageRecipient is IMessageRecipient {
    uint32 public lastOrigin;
    bytes32 public lastSender;
    bytes public lastBody;

    function handle(uint32 origin, bytes32 sender, bytes calldata body) external payable {
        lastOrigin = origin;
        lastSender = sender;
        lastBody = body;
    }
}
