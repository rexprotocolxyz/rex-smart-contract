# Deploying the order-book system

All executable deployment scripts, together with their shared abstract base, live in this directory.

The deployment follows a Forge-first workflow: simulate, review, broadcast, verify. There is no shell deployment
wrapper. The Solidity script validates the complete configuration and asserts the simulated deployment state before
writing an explicitly non-authoritative simulation artifact.

The deployment creates:

1. `BPSOrderBookFeeController`
2. `OrderBookFactory`
3. the factory's dedicated `OrderBookDeployer`

## 1. Prepare the environment

From `order-book/`, copy the environment template:

```sh
cp .env.example .env
```

Create a dedicated encrypted Foundry keystore for the funded deployment account. Enter the private key and choose a
strong keystore password only at Cast's hidden interactive prompts; never place either value in `.env` or a command
argument:

```sh
cast wallet import order-book-deployer --interactive
cast wallet list
```

The keystore is stored under Foundry's default keystore directory, `~/.foundry/keystores/`. `cast wallet list` prints
the imported public address without exposing the key. Set that address, the exact keystore account name, and the RPC
endpoint in `.env`. The broadcaster is not assigned any protocol role. Never commit `.env`, the keystore file, or its
password.

```dotenv
DEPLOYER_ADDRESS=<deployment-address>
ETH_KEYSTORE_ACCOUNT=order-book-deployer
RPC_URL=<rpc-url>
```

Before funding or deploying, confirm that the configured address belongs to the selected account:

```sh
cast wallet address --account order-book-deployer
```

Cast prompts for the keystore password and prints the corresponding address. It must exactly match
`DEPLOYER_ADDRESS`. Fund only that address. Forge automatically reads `ETH_KEYSTORE_ACCOUNT` and prompts for the same
password whenever it must sign a broadcast or resume source verification; neither the password nor decrypted key is
placed in process arguments.

For unattended production automation, prefer a supported hardware or remote signer such as Ledger, AWS KMS, GCP KMS,
or Turnkey. If a password file is unavoidable, create it outside the repository from a secret manager, restrict its
permissions, point `ETH_PASSWORD` to its path, and securely remove it after the operation. Never put the password value
itself in `.env`.

If Forge reports `No associated wallet`, verify that `ETH_KEYSTORE_ACCOUNT` names an existing entry from
`cast wallet list` and that `DEPLOYER_ADDRESS` matches `cast wallet address --account <name>`. A decryption error means
the entered keystore password is incorrect; it is not the account's raw private key.

Hardware wallets and supported remote signers may instead be selected with their standard Forge wallet options;
`DEPLOYER_ADDRESS` must always match the selected signer.

The commands below use `RPC_URL` by default. An explicit `--rpc-url <other-rpc-url>` may be appended to any command and
takes precedence for that invocation.

Copy the configuration template and set its path in `.env`:

```sh
cp script/config/deployment.example.json script/config/<chain-id>.json
```

```dotenv
ORDER_BOOK_DEPLOYMENT_CONFIG=script/config/<chain-id>.json
```

Review and commit the chain-specific JSON configuration. The script checks its chain ID, Cancun activation floor,
nonzero governance and fee-recipient addresses, fee bounds, governance delay, and the deployed contracts' final
configuration. A fee recipient may be an EOA or contract; use a reviewed governed treasury or multisig in production.

## 2. Simulate

```sh
pnpm deploy:simulate
```

Forge performs a full simulation without sending transactions. Review the trace, sender, constructor arguments,
roles, fees, gas estimates, deployed addresses, and code hashes. It writes `simulations/latest.json`, explicitly marked
with `artifactType: "SIMULATION"`, `broadcastConfirmed: false`, and `result: "SIMULATION_ONLY"`. This file is a review
aid, not deployment evidence.

## 3. Broadcast

After the simulation has been independently reviewed, run:

```sh
pnpm deploy:broadcast
```

The same Solidity script runs again with `--broadcast --slow`. Foundry stores transaction data and any resulting
receipts under `broadcast/`. The script still produces only the non-authoritative simulation artifact because Solidity
script execution occurs before Forge broadcasts and confirms the collected transactions. Independently confirm every
expected receipt succeeded; `simulations/latest.json` is never proof that deployment occurred.

If an interrupted broadcast is safe to resume:

```sh
pnpm deploy:resume
```

## 4. Verify source code

The RPC endpoint identifies the target chain. The selected verifier determines where Forge submits source code.
Foundry defaults to Sourcify when no verifier is selected:

```sh
pnpm deploy:verify
```

Post-deployment verification resumes the recorded Forge deployment with `--verify`. Forge therefore loads the same
encrypted keystore account that originally broadcast the deployment. The signer is needed by Forge's resume mechanism,
not by the explorer. No raw private key is interpolated into process arguments.

Use the explicit commands below instead when verification must be submitted to Etherscan or Blockscout.

### Etherscan

For a chain supported by Etherscan, set its API key in `.env`:

```dotenv
ETHERSCAN_API_KEY=<etherscan-api-key>
```

Forge derives the explorer API URL from the chain ID returned by `RPC_URL`:

```sh
pnpm deploy:verify:etherscan
```

### Blockscout

For Blockscout, set the verifier URL and optional API key in `.env`. Include the API path in the URL:

```dotenv
VERIFIER_URL=https://explorer.example/api/
VERIFIER_API_KEY=<blockscout-api-key-if-required>
```

Then run:

```sh
pnpm deploy:verify:blockscout
```

An explicit `--verifier-url <url>` or `--verifier-api-key <key>` appended to the command takes precedence over the
environment value. For example:

```sh
pnpm deploy:verify:blockscout --verifier-url https://explorer.pruv.network/api/
```

Each verification command resumes the completed Forge script with `--verify`, using the recorded broadcast
transactions and constructor arguments. To verify through both providers, run both commands against the same completed
broadcast. Confirm that the fee controller, factory, and factory-created deployer are verified on every required
explorer.

For a new broadcast, deployment and source verification can run together through one selected provider:

```sh
pnpm deploy:broadcast-and-verify:etherscan
pnpm deploy:broadcast-and-verify:blockscout
```

## Release checklist

- Use the pinned Foundry, Solidity, EVM, optimizer, and dependency versions documented in the project README.
- Run the full CI-equivalent checks before deployment.
- Deploy from a clean, reviewed commit and archive that commit hash with the Foundry broadcast directory and simulation
  artifact. Do not label deployment successful until the receipts and deployed state have been independently checked.
- Use governed multisigs for every privileged production role.
- Review the simulation before broadcasting; never treat a successful command as sufficient review.
- Verify source code through an independently operated explorer.
