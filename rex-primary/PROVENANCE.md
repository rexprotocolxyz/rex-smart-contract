# Provenance

This tree is an export, not a fork. It is maintained elsewhere and copied here for review; report
findings against these paths and they will be applied upstream.

| | |
|---|---|
| Source repository | `d3labs-io/rex-retail-primary` (private) |
| Source branch | `docs/at218-review-audit` — **not yet merged to `staging`** (see below) |
| Source commit | `07a277e` |
| Exported | 2026-09-30 (refreshed; first export the same day from `staging` `de43c8bc`) |
| Contract version | `REXPrimary.VERSION()` = `1.4.0` |

**This refresh changes exactly one file, and it is a test.** `contracts/src/`, `shared/src/`,
`contracts/script/`, `shared/mocks/` and `config/` are **byte-identical to the previous export** — so
if you have already read the contracts, you do not need to re-read them. The delta is
`contracts/test/PruvExecutor.invariant.t.sol`, which adds two stateful invariants over the executor's
**deposit** leg (`invariant_executorAssetSolvency`, asserting the executor holds every USDC it has
committed to a recorded-but-unresolved subscribe leg, and `invariant_depositResolvedAtMostOnce`) plus
three handler actions that drive that leg. It closes a coverage gap our own review raised: the
committed-funds counter introduced by the **H-1** remediation (`pendingDepositAssets`) was the one
with no fuzz behind it, while its redeem twin had 256 runs.

The source branch is named above rather than `staging` because merging to `staging` triggers a
deployment, so the branch is held for review. Nothing in this refresh touches a contract; the
upstream commit also carries operator-tooling and documentation fixes that are outside this export's
scope (`ops/`, `docs/`).

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
