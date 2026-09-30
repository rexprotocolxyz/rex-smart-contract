# Provenance

This tree is an export, not a fork. It is maintained elsewhere and copied here for review; report
findings against these paths and they will be applied upstream.

| | |
|---|---|
| Source repository | `d3labs-io/rex-retail-primary` (private) |
| Source branch | `staging` |
| Source commit | `de43c8bcae7607ea1f0da05059e0b6f08f3e0b7b` |
| Exported | 2026-09-30 |
| Contract version | `REXPrimary.VERSION()` = `1.4.0` |

## What was copied

Only files tracked by git at that commit — no build output, no caches, no local environment. Paths
are unchanged relative to each other, so no source file needed editing.

| Here | Source |
|---|---|
| `contracts/` | `contracts/` |
| `shared/` | `shared/`, minus `shared/ts/` |
| `config/` | `config/` |

Left out: `shared/ts/` (the generated TypeScript ABI package, not Solidity), `services/` and `ops/`
(off-chain indexer, API, operator CLI), and `docs/` (specification and architecture decisions —
available on request; the ones that constrain acceptable fixes are summarised in `README.md`).

## Dependencies

Vendored verbatim into `contracts/lib/`, trimmed to the directories the remappings resolve against,
with each package's `LICENSE` and `package.json` kept so the version is provable from the tree
itself:

| Dependency | Version | Upstream commit |
|---|---|---|
| `openzeppelin-contracts` | 5.0.2 | `dbb6104ce834628e473d2173bbc9d47f81a9eec3` |
| `forge-std` | 1.16.2 | `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` |

Unmodified — diff against those upstream commits to confirm.

`order-book/` pins different versions (OpenZeppelin 5.6.1, solc 0.8.36) and resolves them with
pnpm. That is deliberate: each tree is pinned to the toolchain its deployed bytecode was compiled
with, so unifying them would leave one no longer matching what is on chain.

## Verifying this export

From `contracts/`:

```
forge build --sizes    ->  REXPrimary 24,395 bytes (181 free of the 24,576 EIP-170 limit)
forge test             ->  83 suites / 548 tests / 0 failed
```

Both figures were reproduced in both repositories with the same commands: sizes byte-identical
across all five deployable contracts, suite totals matching exactly. If either differs on your
machine, trust the source repository and report it — that means the export is wrong, not the code.
