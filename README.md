# REX Smart Contracts

Solidity for two REX systems, collected here for review.

**They are independent** — no shared source, no shared interfaces, no shared dependencies, and no
calls between them on chain. Two separate scopes that happen to share a repository.

| | `rex-primary/` | `order-book/` |
|---|---|---|
| What it is | Cross-chain subscribe/redeem over a tokenized private-credit fund, home chain ↔ Pruv fund chain | Order book and fee controllers for REX expedited exit |
| Solidity | 2,644 lines + 556 (frozen interfaces) | 2,571 lines |
| solc | `0.8.30`, optimizer 1 run | `0.8.36`, optimizer 200 runs |
| OpenZeppelin | `5.0.2`, vendored | `5.6.1`, via pnpm |

Each tree is pinned to the toolchain its deployed bytecode was compiled with, so the versions
differ on purpose — unifying them would leave one no longer matching what is on chain.

## Build

```bash
cd rex-primary/contracts && forge build --sizes && forge test
cd order-book && pnpm install --frozen-lockfile && pnpm build:sizes && pnpm test
```

`order-book/` reports sizes through `pnpm build:sizes`, not `forge build --sizes`. The latter also
measures the deployment script and the test harness — neither is deployed, both are far over
EIP-170, and it exits non-zero on them. The gate script measures the four deployable contracts.

## Start here

- `rex-primary/README.md` — scope, toolchain, and the **constraints that make some otherwise
  reasonable fixes unimplementable** (EIP-170 headroom, no proxies, frozen wire format).
- `rex-primary/PROVENANCE.md` — where this tree came from and how to verify the export.
- `order-book/README.md` — scope, toolchain, prerequisites.

## License

MIT — see `LICENSE`. Every Solidity file in both trees carries the matching
`SPDX-License-Identifier: MIT` header.
