# REX Smart Contracts

Solidity for two REX systems, collected here for review.

**They are independent.** No shared source, no shared interfaces, no shared dependencies — and
they do not call each other on chain. Treat them as two separate scopes that happen to live in one
repository, and expect each to be set up its own way.

| | `rex-primary/` | `order-book/` |
|---|---|---|
| What it is | Cross-chain subscribe/redeem over a tokenized private-credit fund, home chain ↔ Pruv fund chain | Order book and fee controllers for REX expedited exit |
| Solidity | 2,644 lines (contracts) + 556 (frozen interfaces) | 2,571 lines |
| solc | `0.8.30`, optimizer 1 run | `0.8.36`, optimizer 200 runs |
| OpenZeppelin | `5.0.2` | `5.6.1` |
| Dependencies | git submodules | pnpm |

The toolchains differ on purpose: each tree is pinned to what its deployed bytecode was compiled
with, so unifying them would mean one of them no longer matching what is on chain.

## Build

```bash
# rex-primary
git submodule update --init --recursive
cd rex-primary/contracts && forge build --sizes && forge test

# order-book
cd order-book && pnpm install --frozen-lockfile && forge build --sizes && forge test
```

## Where to start

- `rex-primary/README.md` — scope, toolchain, and the **constraints that make some otherwise
  reasonable fixes unimplementable** (EIP-170 headroom, no proxies, frozen wire format). Worth
  reading before writing recommendations.
- `rex-primary/PROVENANCE.md` — source repository and commit this tree was exported from, and how
  to verify the export.
- `order-book/README.md` — scope, toolchain and prerequisites.
