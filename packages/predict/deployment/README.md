# Predict Testnet deployment

This directory records and reproduces the `predict-testnet-8-21` contract deployment. Operator recovery data and the stable integration surface are separate artifacts.

## Files

- `deploy.ts` is the resumable deployment state machine. It publishes `fixed_math`, Account, Propbook, Predict, the DeepBook core Account wrapper, and Sessions; authorizes the fresh Account apps; wires BTC oracle state; applies cadence policy; bootstraps the pool; fills the initial market windows; transfers the lifecycle capability; and audits the result from Testnet.
- `deployment.testnet.state.json` is the mode-`0600`, gitignored operator journal. It contains in-flight intent, transaction receipts, temporary objects, bootstrap-account data, and administrative capabilities.
- `deployment.testnet.json` is the public integration manifest. The script writes it only after a complete Testnet audit.
- `deploy.test.ts` pins the non-broadcasting default, state/manifest boundary, deployment policy, publication metadata decoding, and schema-6 manifest boundary.

No deployment artifact contains signer key material. The workflow reads the selected signer from a mode-restricted snapshot of the existing Sui client configuration and removes the snapshot on exit.

## Run

Use Sui CLI 1.77.1, a clean committed deployment branch, and the Testnet client environment whose active address is the funded deployer.

```sh
cd packages/predict
corepack npm exec -- tsx deployment/deploy.ts
corepack npm exec -- tsx deployment/deploy.ts --execute
```

The first command builds every package, verifies the package plan and dependency identities, checks the chain, signer, external objects, capability owners, gas for the six publications and complete 32-transaction wiring plan, and DUSDC funding, and submits no transaction. The second command broadcasts.

The broadcast publishes `fixed_math`, `account`, `propbook`, `predict`, `deepbook_core_account`, and `sessions` in dependency order. All new publisher, upgrade, admin, and metadata capabilities remain owned by the deployer. The workflow authorizes Predict, the core wrapper, and Sessions on the fresh Account registry.

The existing DeepBook registry's consensus-owned `DeepbookAdminCap` has a different owner. The workflow audits whether that owner has authorized the fresh `DeepbookCoreAccountApp` type, records the result in the integration manifest, and completes the deployment with that external authorization pending when it is not present. The admin-cap owner performs that one authorization separately; rerunning the deployment afterward updates the audited status without duplicating any completed work.

The workflow creates and binds the BTC Pyth and Block Scholes objects, registers BTC, writes all six cadence records, bootstraps the pool with the configured DUSDC, and creates markets from longest to shortest enabled cadence. It transfers `MarketLifecycleCap` last with `sui::transfer::public_party_transfer` to a `sui::party::single_owner` party and verifies its `ConsensusAddressOwner` custody.

If a run is interrupted, preserve the source commit, signer, client environment, generated `Published.toml` files, and state journal, then rerun the execute command. A known digest is reconciled on-chain. An unknown CLI submission outcome fails closed and must be reconciled before resuming.

Commit the reviewed workflow before the first execute run; that commit is the immutable source anchor for every resume. After the final audit succeeds, commit the generated `Published.toml` files and integration manifest without changing the source anchor. Never commit the state journal or regenerated `Move.lock` files.

```sh
cd packages/predict
corepack npm run build
corepack npm exec -- tsx --test deployment/deploy.test.ts
```

## Integration manifest

The schema-6 manifest contains the six fresh package IDs, shared objects, coin types, oracle bindings, lifecycle capability, earliest publication checkpoint, DeepBook wrapper-authorization status, numeric units, and the initial protocol and cadence snapshot. Mutable `ProtocolConfig`, Predict `Registry`, Propbook `OracleRegistry`, `SessionsConfig`, and DeepBook `Registry` values are anchored to the exact object versions and digests bracketing the final audit reads.

The manifest excludes the deployer, transaction digests, receipts, bootstrap accounts, temporary markets, balances, and publisher, upgrade, admin, or metadata capabilities. Runtime consumers must read mutable protocol and cadence policy from the shared objects on-chain.
