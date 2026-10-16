# Order Book Smart Contracts

Foundry project for the REX expedited-exit order-book smart contracts.

## Current scope

This project contains the public order-book interfaces, deployable implementations, Foundry test suites, and a
reviewed production deployment package.

## Toolchain

| Component | Configuration |
|---|---|
| Framework | Foundry `1.7.1` in CI (`forge`, `anvil`, `cast`, `chisel`) |
| Solidity | Exactly `0.8.36` |
| EVM target | Cancun |
| Optimizer | Enabled, 200 runs |
| Solidity dependencies | Exact versions locked with pnpm `11.21.0` |
| OpenZeppelin Contracts | Exactly `5.6.1` |

The Foundry release is pinned in the order-book smart-contract CI workflow. The compiler version is pinned in `foundry.toml`, and all current Solidity source files use the exact `0.8.36` pragma. Foundry, compiler, and EVM-target changes require review because they can change deployed bytecode or analysis results.

## Prerequisites

- [Foundry](https://getfoundry.sh/introduction/installation) `1.7.1` for CI parity
- A current Node.js LTS release with pnpm `11.21.0`
- Python 3.10 or newer for Slither

pnpm installs pinned Solidity dependencies. Foundry handles compilation, tests, formatting, coverage, deployment scripts, local chains, and chain interaction.

## Setup

From `order-book/`:

```sh
pnpm install --frozen-lockfile
pnpm lint
pnpm build
pnpm test
```

Install the pinned Slither analyzer in a local virtual environment:

```sh
python3 -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements-dev.txt
pnpm analyze:slither
```

`pnpm install --frozen-lockfile` installs the exact dependency graph in `pnpm-lock.yaml` without modifying it. Foundry resolves package imports through `remappings.txt`.

## Commands

| Command | Purpose |
|---|---|
| `pnpm build` | Compile the Solidity project |
| `pnpm build:sizes` | Compile and report contract size margins |
| `pnpm test` | Run the default Forge test profile |
| `pnpm test:ci` | Run the higher-intensity CI fuzz/invariant profile |
| `pnpm test:gas` | Run tests with a gas report |
| `pnpm coverage` | Produce a coverage summary |
| `pnpm snapshot` | Write a Forge gas snapshot |
| `pnpm format` | Format Solidity files |
| `pnpm format:check` | Check formatting without modifying files |
| `pnpm lint` | Strictly lint deployable Solidity sources with Solhint and Foundry |
| `pnpm lint:solhint` | Run Solhint's security and style rules on deployable contracts and scripts |
| `pnpm lint:forge` | Run Foundry's native checks on deployable contracts and scripts |
| `pnpm analyze:slither` | Run Slither's deeper vulnerability analysis |
| `pnpm clean` | Remove generated Foundry artifacts |
| `pnpm deploy:simulate` | Simulate the production deployment with Forge |
| `pnpm deploy:broadcast` | Simulate and broadcast the deployment with Forge |
| `pnpm deploy:verify` | Verify deployed source code through Sourcify (Foundry default) |
| `pnpm deploy:verify:etherscan` | Verify deployed source code through Etherscan |
| `pnpm deploy:verify:blockscout` | Verify deployed source code through Blockscout |

Native Foundry tools remain available directly:

```sh
forge test -vvv
anvil
cast chain-id --rpc-url <rpc-url>
chisel
```

## Project layout

```text
contracts/                  Deployable order-book and fee-controller implementations
└── interfaces/             Public interfaces and shared ABI types
script/
├── deploy/                 Forge deployment scripts
├── config/                 Reviewed deployment inputs
├── checks/                 Contract-size build and validation utilities
└── tests/                  Regression tests for script utilities
test/                       Active Forge unit and invariant test suites
├── handlers/               Stateful invariant-test action handlers
├── helpers/                Test-only deployment and configuration helpers
└── mocks/                  Token and controller test doubles
foundry.toml                Compiler and test-profile configuration
remappings.txt              Solidity dependency mappings
```

Generated `out`, `cache`, `broadcast`, `simulations`, coverage, and dependency directories are ignored by Git.

## Deployment

The production workflow is deliberately linear: prepare the reviewed inputs, simulate, review the simulated
transactions, broadcast, and verify source code. Run every command below from `order-book/`.

1. Create a dedicated encrypted Foundry keystore for the funded deployment account. Enter the private key and choose a
   strong keystore password only at Cast's hidden interactive prompts; the deployer receives no protocol role.

   ```sh
   cast wallet import order-book-deployer --interactive
   cast wallet list
   ```

   `cast wallet list` prints the imported account's address. Copy that public address into `DEPLOYER_ADDRESS`; its
   keystore name must match `ETH_KEYSTORE_ACCOUNT`. Copy the environment template and add those values, the RPC
   endpoint, and credentials required by the selected source verifier. Never commit the populated `.env` file or store
   a raw private key or keystore password in it.

   ```sh
   cp .env.example .env
   ```

   ```dotenv
   DEPLOYER_ADDRESS=<deployment-address>
   ETH_KEYSTORE_ACCOUNT=order-book-deployer
   RPC_URL=<rpc-url>
   ```

   Fund only `DEPLOYER_ADDRESS`, then confirm the configured address and account refer to the same signer:

   ```sh
   cast wallet address --account order-book-deployer
   ```

   Cast prompts for the keystore password and prints the address. Forge uses the account named by
   `ETH_KEYSTORE_ACCOUNT` and prompts for the same password when a deployment or resumed verification needs a
   signature. The password and decrypted key are never placed in the command arguments.

   All deployment commands use `RPC_URL` by default. To use a different endpoint for one invocation, append
   `--rpc-url <other-rpc-url>`; the inline value takes precedence over `RPC_URL`.

2. Copy the deployment configuration template for the target chain, replace every placeholder, and point `.env` to
   the resulting file.

   ```sh
   cp script/config/deployment.example.json script/config/<chain-id>.json
   ```

   ```dotenv
   ORDER_BOOK_DEPLOYMENT_CONFIG=script/config/<chain-id>.json
   ```

   Review and commit the chain-specific JSON before deployment. Confirm the chain ID and a `minimumDeploymentBlock`
   that is at or after Cancun activation and at or before deployment, governance addresses and policies, treasury, fee
   rates and caps, fee token, and governance delay.

3. Simulate the complete deployment without sending transactions.

   ```sh
   pnpm deploy:simulate
   ```

   The generated `simulations/latest.json` is labeled `SIMULATION_ONLY` with `broadcastConfirmed: false`. It is a review
   aid and must never be treated as confirmed deployment evidence.

4. Review every simulated transaction. Confirm the broadcaster, constructor arguments, deployed addresses, runtime
   code hashes, ownership, roles, fee settings, delay, and gas estimates. Do not broadcast merely because simulation
   completed successfully.

5. Broadcast the reviewed deployment.

   ```sh
   pnpm deploy:broadcast
   ```

   Foundry records transaction data and any resulting receipts under `broadcast/`. The Solidity script cannot observe
   the later broadcast outcome, so it writes only the non-authoritative simulation artifact. Independently confirm that
   every expected receipt succeeded before treating deployment as complete.

6. Verify all deployed source code. The RPC endpoint identifies the chain, while the verifier selection determines
   where Forge submits the source code.

   With no explicit verifier, Foundry uses Sourcify:

   ```sh
   pnpm deploy:verify
   ```

   Post-deployment verification resumes the recorded Forge deployment with `--verify`. Forge therefore loads the same
   encrypted keystore account that originally broadcast the deployment. The signer is needed by Forge's resume
   mechanism, not by the explorer. No raw private key is placed in process arguments.

   For Etherscan, place its API key in `.env`:

   ```dotenv
   ETHERSCAN_API_KEY=<etherscan-api-key>
   ```

   Forge derives the Etherscan API URL from the chain ID returned by `RPC_URL`:

   ```sh
   pnpm deploy:verify:etherscan
   ```

   For Blockscout, place its API endpoint and optional API key in `.env`. The URL must include the API path:

   ```dotenv
   VERIFIER_URL=https://explorer.example/api/
   VERIFIER_API_KEY=<blockscout-api-key-if-required>
   ```

   Then run:

   ```sh
   pnpm deploy:verify:blockscout
   ```

   An inline `--verifier-url <url>` or `--verifier-api-key <key>` takes precedence over the corresponding environment
   value. Run any required verification commands against the same completed broadcast. A fresh deployment may
   broadcast and verify through one selected provider with
   `pnpm deploy:broadcast-and-verify:etherscan` or `pnpm deploy:broadcast-and-verify:blockscout`. Use
   `pnpm deploy:resume` only after confirming that resuming an interrupted broadcast is safe.

Archive the reviewed commit, chain-specific configuration, Foundry broadcast directory, simulation artifact, explorer
verification results, and governance transactions together. Treat only independently checked receipts and deployed
state as deployment evidence. The detailed trust model, configuration rules, and release checklist are in
[`script/deploy/README.md`](script/deploy/README.md).

## Factory deployment and registry policy

Deploy `OrderBookFactory` with the factory owner, default order-book owner, default fee controller, and immutable fee
caps. Its constructor creates a dedicated immutable `OrderBookDeployer`, binding canonical market creation to the
reviewed deployer and order-book bytecode. Production ownership should use governed multisig addresses rather than
individual EOAs.

The deployer is intentionally stateless and permissionless. Anyone can deploy an order book directly, but only books
created and registered by the factory are canonical markets. The factory owner controls market creation, registry
removal, and deployment defaults for future books. The owner is trusted to select each market's base/quote orientation
and ensure both tokens satisfy the protocol's business requirements.

Order-book enumeration uses swap-and-pop removal. Its ordering can change after mutations, so clients should restart
pagination when the registry changes and use events as the authoritative history.

## Required checks

Every Solidity change should pass:

```sh
pnpm install --frozen-lockfile
pnpm format:check
pnpm lint
pnpm test
pnpm coverage
pnpm build:sizes
pnpm analyze:slither
```

The Foundry `block-timestamp` lint is disabled because order expiry intentionally relies on timestamp comparisons. Slither excludes dependencies and test scaffolding from reported findings while still compiling the complete Foundry project.

Strict linting is scoped to production contracts and deployment scripts. Test contracts intentionally use Foundry-specific naming and patterns; their correctness is enforced by compilation, unit tests, fuzzing, invariants, coverage, and test discovery in CI.

The repository CI runs these checks with Foundry `1.7.1`, including the higher-intensity fuzz/invariant profile. Before a production release, also run deployment simulation and the project-specific audit workflow.

The complete production procedure, trust model, release checklist, and configuration policy are in
[`script/deploy/README.md`](script/deploy/README.md).

## Fee override policy

Maker fee overrides apply to the maker. Taker fee overrides normally apply to the wallet paying for the fill, but an explicit override for the settlement recipient takes priority. This is intentional: a destination wallet may receive its configured discount even when another wallet pays, provided the discounted wallet receives the trade output.

Fee quotes are therefore specific to the settlement recipient. Clients must pass the intended output wallet when quoting a fill and refresh the quote if that wallet changes. A recipient-based discount is not proof that the paying taker owns or controls the recipient.

Fees are quoted and charged independently for each fill. Integer division rounds every quote down to the fee token's
smallest unit, and fractional remainders are not accumulated across partial fills. Consequently, splitting an amount
across fills can produce a lower total fee than filling the same amount at once. This is an intentional tradeoff that
keeps fee quotes stateless; the quote for each individual fill is authoritative.

## Security

- Never commit private keys, mnemonics, API keys, or private RPC URLs.
- Review changes to the compiler, EVM target, dependency lockfile, pinned Foundry release, and pinned CI action commits.
- Review dependency-lockfile and compiler-output changes like Solidity source changes.
- Simulate and verify deployment scripts before broadcasting.
