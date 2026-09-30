# REX Primary Smart Contracts

Foundry project for the REX Primary protocol — a cross-chain retail subscription/redemption
protocol over a tokenized private-credit fund, running between a home chain (BSC testnet) and the
Pruv fund chain.

This tree is **independent of `order-book/`**: it shares no source, no interfaces and no
dependencies with it. The two are separate audit scopes that happen to live in one repository.

## Current scope

| | LOC |
|---|---|
| `contracts/src` — 10 deployable contracts | ~2,400 |
| `shared/src` — the frozen cross-chain interface surface | ~800 |

Deployable contracts: `REXPrimary`, `PruvExecutor`, `EpochSchedule`, `REXLens`, `REXRegistry`,
`REXRegistryV2`, `NavOracleConsumer`, `NavReporter`, `BridgeAdapter`, `State`.

## Toolchain

| Component | Configuration |
|---|---|
| Framework | Foundry (`forge`, `anvil`, `cast`) |
| Solidity | Exactly `0.8.30` (`auto_detect_solc` off) |
| EVM target | Cancun |
| Optimizer | Enabled, **1 run** — see below |
| Solidity dependencies | git submodules, pinned by commit |
| OpenZeppelin Contracts | Exactly `5.0.2` (`dbb6104c`) |
| forge-std | `v1.16.2` (`bf647bd6`) |

**`optimizer_runs = 1` is deliberate, not an oversight.** It trades runtime gas for deployment
size because `REXPrimary` sits against the EIP-170 24,576-byte limit — see *Constraints* below.
The reasoning is recorded in `contracts/foundry.toml`'s own header comment.

## Prerequisites

- Foundry
- Nothing else. Dependencies are git submodules; there is no Node.js or package manager in this
  tree. (`order-book/` uses pnpm — the two trees are set up differently on purpose.)

## Build and test

```bash
git submodule update --init --recursive
cd rex-primary/contracts
forge build --sizes
forge test
```

Expected, and worth checking before anything else — these are the numbers this tree was exported
at, and a mismatch means the export is wrong rather than the code:

```
REXPrimary runtime size   24,395 bytes   (EIP-170 limit 24,576 — 181 bytes free)
forge test                83 suites / 548 tests / 0 failed  (~6 min; includes fuzz + invariant)
```

## Layout, and why it is shaped this way

```
rex-primary/
├── contracts/   Foundry root — src, test, script, lib (submodules), foundry.toml
├── shared/      src/ + mocks/ — the FROZEN interface surface, consumed by other repositories
└── config/      networks*.json and deploy/*.params.json
```

`shared/` and `config/` sit beside `contracts/` rather than inside it because the Foundry root
reaches out to both, exactly as it does in the source repository:

- `contracts/remappings.txt` — `@rex-shared/=../shared/src/`, `@rex-shared-mocks/=../shared/mocks/`
- `contracts/foundry.toml` — `fs_permissions` grants read on `../config`
- three tests call `vm.readFile("../config/networks.json")` and
  `vm.readFile("../config/deploy/testnet-dev.params.json")`

Keeping those relative paths intact is what let this tree be exported **without editing a single
file**. See `PROVENANCE.md`.

## Constraints a reviewer should know before proposing fixes

These are architectural decisions, not accidents. Each one makes a whole class of otherwise
reasonable recommendation unimplementable here.

1. **`REXPrimary` has 181 bytes of EIP-170 headroom.** Any fix that adds bytecode to that contract
   has to fit in 181 bytes or it does not ship. This is a measured limit: a candidate fix for the
   `applySchedule` stranding guard was implemented and **failed to build, breaching EIP-170**.
2. **No proxies (ADR-011).** Contracts are immutable and versioned by redeployment. "Make it
   upgradeable" is not available; a fix that requires an upgrade path requires a new ADR first.
3. **The cross-chain wire format is frozen (ADR-016).** `Instruction.navAtInitiate` ships as a `0`
   sentinel on the subscribe leg and is read by nothing — that is deliberate, to avoid a version
   bump. It is not dead code left by accident.
4. **`shared/src` is a frozen interface surface** consumed by repositories outside this one and
   versioned by tag. Changing a signature there is a breaking change for consumers, not a local
   edit.
5. **Two chains, one trust boundary.** `PruvExecutor` runs on the Pruv fund chain and holds a
   soulbound KYC credential; `REXPrimary` runs on the home chain. Neither can read the other's
   state, so invariants that span them are enforced at deploy time, off chain.
