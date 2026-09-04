# Official Predict Testnet deployment

This directory owns the reproducible `deepbook-predict-testnet` contract deployment. Operator recovery data and the stable public integration surface are separate artifacts.

## Files

-   `deploy.ts` is the resumable deployment state machine. It publishes `fixed_math`, USDC, Account, Propbook, Predict, the DeepBook core Account wrapper, and Sessions; finalizes the USDC and PLP currency registrations; mints Testnet USDC; authorizes the fresh Account apps; wires BTC oracle state; applies cadence policy; bootstraps the pool; fills the initial market windows; hands off both operational capabilities; and audits the result from Testnet.
-   `deployment.testnet.state.json` is the mode-`0600`, gitignored operator journal. It contains in-flight intent, transaction receipts, temporary currency objects, bootstrap-account data, and privileged capabilities.
-   `deployment.testnet.json` is the public integration manifest. The script writes it only after the complete Testnet audit and external DeepBook authorization pass.
-   `deploy.test.ts` pins the non-broadcasting default, state/manifest boundary, official economics, publication plan, package recovery, every irreversible transaction boundary, SID parity, and schema-7 manifest boundary.

No deployment artifact contains signer key material. The workflow reads the selected signer from a mode-restricted snapshot of the existing Sui client configuration and removes the snapshot on exit.

## Run

Use Sui CLI `sui 1.77.1-4e476c5c8184`, a clean committed `deepbook-predict-testnet` branch, and the Testnet client environment whose active address is the funded deployer. Do not set `SUI_KEYSTORE_PATH`; the CLI and SDK both use the keystore pinned by the client configuration.

```sh
cd packages/predict
corepack npm exec -- tsx deployment/deploy.ts
corepack npm exec -- tsx deployment/deploy.ts --execute
```

The first command builds every package with warnings denied, verifies the seven-package plan and dependency identities, checks the chain, signer, external objects, capability owners, gas for the complete transaction plan, and source bindings, and submits no transaction. The second command broadcasts.

The broadcast publishes `fixed_math`, `usdc`, `account`, `propbook`, `predict`, `deepbook_core_account`, and `sessions` in dependency order. All package upgrade capabilities, the USDC TreasuryCap and MetadataCap, the PLP MetadataCap, and the Account, Propbook, Predict, and Sessions administrative capabilities remain owned by the deployer.

The fresh collateral type is `<usdc-package>::usdc::USDC`; its six-decimal display symbol is `DUSDC`. The workflow permissionlessly finalizes its Sui coin-registry registration, retains its TreasuryCap and MetadataCap, and performs one recorded mint of 100,000,000 USDC to the deployer. It also finalizes the fresh PLP registration before pool bootstrap.

The official initial pool locks 10 USDC and supplies 250,000 USDC to the deployer Account, creating the corresponding PLP position. The protocol retains the source defaults of a 500,000 USDC maximum LP-attributable pool value and a five-minute maximum valuation window.

BTC is the only registered underlying. The workflow enables only 1-minute and 5-minute cadences; each has a two-market window, 2,000 USDC initial expiry cash, 10,000 USDC maximum allocation, a 0.01 USD pricing tick, and a 1 USD admission tick. The remaining cadence records are explicitly disabled.

The workflow creates the fresh BTC Pyth feed and Block Scholes store pair, verifies the on-chain spot, forward, and SVI SIDs against the subscription-side derivation, and requires fresh provider source timestamps before moving collateral. A first execution normally stops with `awaiting_oracle_data` after publishing and wiring the new object IDs; configure the Propbook writer for those IDs, allow observations to land, and rerun the same committed source and state journal.

Each new market receives its exact previous-window Pyth reference tick before pool cash is rebalanced into it. Missing reference observations fail closed and are retried by resuming after the updater has inserted the required boundary observation.

The workflow mints both `MarketLifecycleCap` and `PoolValuationCap` to the deployer for setup. After package, currency, authorization, oracle, configuration, funding, reference-tick, live-market, and pool-accounting audits pass, it transfers both capabilities atomically with `sui::transfer::public_party_transfer` to the configured Predict writer and verifies their `ConsensusAddressOwner` custody.

The existing DeepBook registry's consensus-owned `DeepbookAdminCap` has a different owner. The workflow audits whether that owner has authorized the fresh `DeepbookCoreAccountApp` type; when authorization is absent, the journal remains `awaiting_external_authorization` and no integration manifest is written. After the external owner authorizes the type, rerun the same command to verify the mutated DeepBook registry, establish the final checkpoint fence, and complete.

No transaction targets the existing Predict v4 packages or shared objects. Reusing the v4 writer addresses only selects final custody; it does not launch a duplicate keeper or updater.

If a run is interrupted, preserve the source commit, exact Sui binary, client configuration, gas budgets, generated `Published.toml` files, and state journal, then rerun the execute command. A successful known digest is reconciled on-chain, including reconstruction of missing publication metadata from the verified receipt; a definitively failed digest is checkpointed and made retryable, and an unknown submission outcome fails closed until it is reconciled.

Commit the reviewed workflow before the first execute run; that commit is the immutable source anchor for every resume. After the final audit succeeds, commit the generated `Published.toml` files and integration manifest without changing the source anchor. Never commit the state journal or regenerated `Move.lock` files.

```sh
cd packages/predict
corepack npm run build
corepack npm exec -- tsx --test deployment/deploy.test.ts
```

## Integration manifest

The schema-7 manifest contains the seven fresh package IDs, finalized currency and shared-object IDs, coin types, oracle bindings, writer identities, lifecycle and pool-valuation capabilities, earliest publication checkpoint, completed DeepBook wrapper authorization, numeric units, and the initial protocol and cadence snapshot. Mutable `ProtocolConfig`, Predict `Registry`, Propbook `OracleRegistry`, `SessionsConfig`, and DeepBook `Registry` values are anchored to the exact object versions and digests bracketing the final audit reads.

The manifest excludes the deployer, transaction digests, receipts, bootstrap accounts, temporary markets, balances, rebalances, and publisher, upgrade, admin, treasury, or metadata capabilities. Runtime consumers must read mutable protocol and cadence policy from the shared objects on-chain.
