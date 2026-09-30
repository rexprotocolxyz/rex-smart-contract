# Provenance

This tree is an export, not a fork. It is maintained in another repository and copied here for
review; findings should be reported against the paths below and will be applied upstream.

| | |
|---|---|
| Source repository | `d3labs-io/rex-retail-primary` (private) |
| Source branch | `staging` |
| Source commit | `de43c8bcae7607ea1f0da05059e0b6f08f3e0b7b` |
| Exported | 2026-09-30 |
| Contract version | `REXPrimary.VERSION()` = `1.4.0` |

## What was copied

Only files tracked by git at that commit — so no build output, no caches, no local environment.
Paths are unchanged relative to each other, which is why no file needed editing.

| Here | Source |
|---|---|
| `rex-primary/contracts/` | `contracts/` |
| `rex-primary/shared/` | `shared/` minus `shared/ts/` |
| `rex-primary/config/` | `config/` |

## What was left out, and why

- **`shared/ts/`** — the TypeScript ABI package (`@rex/wire`). Generated from the Solidity in
  `shared/src`, consumed by the backend and the dApp. Not Solidity, not in scope.
- **`services/`, `ops/`** — the off-chain indexer, API and operator CLI. Out of scope.
- **`docs/`** — specification, 32 ADRs, and internal review records. Available on request; the
  decisions that constrain acceptable fixes are summarised in `README.md`.

## Dependencies

Pinned as git submodules, at the exact commits the source repository builds against:

| Dependency | Commit | Version |
|---|---|---|
| `openzeppelin-contracts` | `dbb6104ce834628e473d2173bbc9d47f81a9eec3` | 5.0.2 |
| `forge-std` | `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` | v1.16.2 |

These differ from `order-book/`'s (OpenZeppelin 5.6.1, solc 0.8.36, resolved via pnpm). That is
deliberate: each tree is pinned to the toolchain its deployed bytecode was compiled with, and
unifying them would mean one tree no longer matching what is on chain.

## Verifying this export

From `rex-primary/contracts`, after `git submodule update --init --recursive`:

```
forge build --sizes    ->  REXPrimary 24,395 bytes (181 free of the 24,576 EIP-170 limit)
forge test             ->  83 suites / 548 tests / 0 failed
```

Both figures were reproduced in BOTH repositories, with the same commands, after the export:
the sizes are byte-identical across all five deployable contracts, and the suite totals match
exactly. If either differs on your machine, trust the source repository and report the
discrepancy — it means the export is wrong, not the code.
