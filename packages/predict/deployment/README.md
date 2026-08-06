# Predict Testnet deployment

This directory records and reproduces the independent `predict-testnet-7-29` contract deployment. It intentionally separates operator recovery data from the stable integration surface.

## Files

-   `deploy.ts` publishes the four local packages, wires their shared objects and external oracle dependencies, writes the cadence policy on-chain, bootstraps the pool, creates the initial market windows, party-transfers the lifecycle capability to its keeper owner, and audits the result from Testnet.
-   `deployment.testnet.state.json` is the resumable operator journal. It contains in-flight state, transaction receipts, temporary objects, bootstrap accounts, and administrative capabilities. The script creates it with mode `0600`; it is gitignored and must not be committed or used as an integration API.
-   `deployment.testnet.json` is the committed integration manifest. The script writes it only after the deployment reaches `complete` and its final Testnet audit succeeds.
-   `deployment.sessions.testnet.state.json` is the separate mode-`0600`, gitignored Sessions publication, authorization, verification, and smoke journal. It contains public transaction/object data only; the temporary session key never leaves memory.
-   `deploy.test.ts` pins the state/manifest boundary and validates the committed manifest schema.

Neither deployment file contains signer key material. The script reads the selected signer from an isolated snapshot of the existing Sui client configuration and never copies the keystore into the repository.

## Run

Use the exact Sui CLI selected by the script, a clean committed deployment branch, and a Testnet client environment whose active address is the funded deployer.

```sh
SUI_BINARY=/path/to/sui node --import tsx packages/predict/deployment/deploy.ts
SUI_BINARY=/path/to/sui node --import tsx packages/predict/deployment/deploy.ts --execute
SUI_BINARY=/path/to/sui node --import tsx packages/predict/deployment/deploy.ts --sessions
SUI_BINARY=/path/to/sui node --import tsx packages/predict/deployment/deploy.ts --sessions --execute
SUI_BINARY=/path/to/sui node --import tsx packages/predict/deployment/deploy.ts --sessions --smoke --execute
```

The first command performs the build, dependency-identity, chain, signer, external-object, and funding preflight without submitting transactions. The second command broadcasts.

`--sessions` performs the Sessions-only Testnet preflight. `--sessions --execute` resumably publishes the upgradeable Sessions v1 package, keeps its `UpgradeCap` with the deployer, idempotently authorizes `SessionsApp`, audits both steps, then extends the committed manifest from schema 3 to schema 4 with only `sourceCommit` and `packages.sessions` added or changed. `--sessions --smoke --execute` additionally finds the deployer's existing AccountWrapper and a fresh live BTC market, creates a five-minute in-memory session, derives a small production-valid 1x quantity from a live quote, mints and checkpoints that exact quantity, waits for the Testnet clock to advance, and fully redeems it through the ephemeral signer. It verifies the complete event payloads, revokes and verifies removal of the session grant, then returns the temporary gas when practical. If execution stops after mint, the next run revokes the old session and closes the checkpointed order with owner authority before starting another smoke. `--smoke` is rejected without both other flags.

The broadcast publishes `fixed_math`, `account`, `propbook`, and `predict` in dependency order; authorizes the Predict app; creates the BTC Pyth and Block Scholes objects; registers cadence policy; bootstraps and funds the initial market windows; then transfers `MarketLifecycleCap` with `sui::transfer::public_party_transfer` to a `sui::party::single_owner` party. The final audit requires the cap to have `ConsensusAddressOwner` custody for the configured keeper address.

If a run is interrupted, keep the same source commit, signer, client environment, `Published.toml` files, and state file, then rerun the execute command. The script reconciles a known transaction digest and otherwise fails closed rather than constructing a replacement transaction.

Commit the reviewed deployment workflow before the first execute run; that commit is the immutable source anchor for every resume. After success, commit the generated `Published.toml` files and integration manifest without changing the source anchor. Never add the state file.

After this workflow merges, run the Sessions preflight from that exact commit, run the Sessions execute mode with the pinned Testnet client and deployer, inspect the schema-4 manifest and operator journal, then run the smoke mode while a future BTC market and its oracle feeds are fresh. Commit `packages/sessions/Published.toml` and the schema-4 `deployment.testnet.json`; never commit either state journal. If any submission is ambiguous, preserve the source commit, client environment, Published metadata, and journal and reconcile the recorded digest before resuming.

```sh
./node_modules/.bin/tsc -p packages/predict/deployment/tsconfig.json
node --import tsx --test packages/predict/deployment/deploy.test.ts
```

## Integration manifest

The manifest contains stable package and object IDs, coin types, oracle bindings, writer-owned capability IDs, the indexer replay checkpoint, numeric units, and initial protocol and cadence configuration pinned to the exact `ProtocolConfig` and `Registry` object versions read by the audit. `verifiedAfterCheckpoint` is the final deployment-transaction checkpoint, so it is a verification fence rather than an assertion that the object values were read at that checkpoint.

It deliberately excludes the deployer, transaction digests, receipts, bootstrap accounts, temporary markets, rebalances, balances, upgrade/admin/metadata capabilities, and verification evidence. Those values are deployment history rather than a consumer contract.

The configuration is an initial verified snapshot. Runtime consumers that need mutable cadence or protocol policy must read the corresponding shared objects on-chain instead of treating this file as a live configuration authority.
