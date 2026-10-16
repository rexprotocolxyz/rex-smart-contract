# REX Primary Smart Contracts

Cross-chain subscribe/redeem over a tokenized private-credit fund, running between a home chain
(BSC) and the Pruv fund chain. Independent of `order-book/` — no shared source or dependencies.

## Scope

10 deployable contracts (`contracts/src`, 2,644 lines) plus the frozen cross-chain interface
surface (`shared/src`, 556 lines): `REXPrimary`, `PruvExecutor`, `EpochSchedule`, `REXLens`,
`REXRegistry`, `REXRegistryV2`, `NavOracleConsumer`, `NavReporter`, `BridgeAdapter`, `State`.

## Toolchain

| Component | Configuration |
|---|---|
| Solidity | Exactly `0.8.30`, `auto_detect_solc` off |
| EVM target | Cancun |
| Optimizer | Enabled, **1 run** — trades runtime gas for deployment size, because `REXPrimary` sits against the EIP-170 limit |
| OpenZeppelin Contracts | `5.0.2`, vendored in `contracts/lib/` |
| forge-std | `1.16.2`, vendored in `contracts/lib/` |

Dependencies are committed, not fetched — no submodules, no package manager.

## Build

```bash
cd contracts
forge build --sizes
forge test
```

Expected:

```
REXPrimary   24,395 bytes   (EIP-170 limit 24,576 — 181 free)
forge test   83 suites / 556 tests / 0 failed   (~6 min, includes fuzz + invariant)
```

## Layout

```
contracts/   Foundry root — src, test, script, lib
shared/      src/ + mocks/ — the frozen interface surface, consumed by other repositories
config/      networks*.json and deploy/*.params.json
```

`shared/` and `config/` sit beside `contracts/` because the Foundry root reaches out to both:
`remappings.txt` maps `@rex-shared/` to `../shared/src/`, `fs_permissions` grants read on
`../config`, and three tests read `../config/networks.json` directly. See `PROVENANCE.md`.

## Constraints to know before proposing fixes

Architectural decisions, not accidents. Each makes a class of otherwise reasonable recommendation
unimplementable here.

1. **`REXPrimary` has 181 bytes of EIP-170 headroom.** A fix that adds bytecode to it must fit in
   181 bytes. Measured, not assumed: a candidate fix for the `applySchedule` stranding guard was
   implemented and failed to build, breaching EIP-170.
2. **No proxies.** Contracts are immutable, versioned by redeployment. "Make it upgradeable" needs
   a new architecture decision first.
3. **The cross-chain wire format is frozen.** `Instruction.navAtInitiate` ships as a `0` sentinel on
   the subscribe leg and is read by nothing — deliberate, to avoid a version bump. Not dead code.
4. **`shared/src` is consumed by repositories outside this one** and versioned by tag. Changing a
   signature there is a breaking change, not a local edit.
5. **Two chains, one trust boundary.** `PruvExecutor` runs on Pruv and holds a soulbound KYC
   credential; `REXPrimary` runs on the home chain. Neither can read the other's state, so
   invariants spanning them are enforced at deploy time, off chain.
