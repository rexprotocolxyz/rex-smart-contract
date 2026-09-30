# Deployment configuration

Copy `deployment.example.json` to `<chain-id>.json`, replace every placeholder, review it, and commit it before any
production simulation. Set `ORDER_BOOK_DEPLOYMENT_CONFIG=script/config/<chain-id>.json` in the untracked `.env` file.

`configurationVersion` must be `1`. `chainId` must match the RPC. `minimumDeploymentBlock` is a reviewed chain-specific
floor at or after Cancun activation and at or before deployment. It prevents the script from running against a chain
state earlier than the reviewed network upgrade floor. Record the authoritative network source used to select it. A
block floor is not itself proof of RPC authenticity, so use independently operated or quorum-backed RPC endpoints.

`factoryOwner`, `defaultOrderBookOwner`, and `feeControllerProposer` must be nonzero addresses. The deployment script
does not require a particular wallet or governance implementation. Production operators should still use reviewed
multisigs or governance contracts and independently validate their implementation, owners, threshold, modules,
guards, fallback handler, and transaction policy. These roles may share one authority only if the reduced separation
of duties is explicitly accepted.

`feeRecipient` must be nonzero and may be an EOA or contract. Production operators should use a reviewed governed
treasury or multisig rather than an individual EOA. `initialTakerFeeToken` is `0` for the base token and `1` for the
quote token. Initial fees must fit the controller caps, controller caps must fit the immutable order-book caps, every
cap must be below 10,000 bps, and `feeControllerDelay` must be between 1 and 30 days.

The simulation artifact records the exact Keccak-256 hash of the configuration bytes but is explicitly not deployment
evidence. Archive the clean deployment commit and reviewed configuration alongside the Foundry broadcast transactions
and receipts; the Solidity script cannot inspect Git or confirm its own later broadcast.
