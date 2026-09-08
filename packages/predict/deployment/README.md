# Official Predict Testnet deployment

This directory publishes, wires, capitalizes, and verifies the `deepbook-predict-testnet` contract suite. Operational capability issuance is a separate command with an explicit recipient.

## Deployment

Use `sui 1.77.1-4e476c5c8184`, a clean committed deployment branch, and the Testnet client configuration whose active address is the funded deployer. The CLI and SDK use the same mode-restricted client-configuration snapshot; do not set `SUI_KEYSTORE_PATH`.

```sh
cd packages/predict
corepack npm exec -- tsx deployment/deploy.ts
corepack npm exec -- tsx deployment/deploy.ts --execute
```

The default command builds and checks the package graph, chain, signer, source, dependencies, and funding without submitting transactions. `--execute` submits the following resumable sequence:

1. Publish `fixed_math`, `usdc`, `account`, `propbook`, `predict`, `deepbook_core_account`, and `sessions` in dependency order.
2. Finalize USDC and PLP currency registration, mint 100,000,000 Testnet USDC to the deployer, and authorize Predict, the DeepBook Account wrapper, and Sessions in the fresh Account registry.
3. Create and bind the BTC Pyth feed and Block Scholes stores, register BTC in Predict, and configure the protocol and cadences.
4. Lock 10 USDC and supply 250,000 USDC through the deployer's Account, completing the initial PLP allocation with an empty-pool valuation before any market exists.
5. Create the initial BTC 1-minute and 5-minute market objects, bounded to two per cadence and the contract's available cadence slots. A higher-cadence overlap may leave one slot unavailable. Creation receipts persist across resumes; elapsed expiries do not trigger replacement markets.
6. Audit package provenance, dependency identities, shared objects, application authorization, oracle bindings, currencies, retained caps, configuration, initial market objects, and capital accounting; generate the integration manifest only after this audit succeeds.

The fresh collateral type is `<usdc-package>::usdc::USDC`, with six decimals and display symbol `DUSDC`. Each enabled cadence has a two-market window, 2,000 USDC initial expiry cash policy, 10,000 USDC maximum expiry allocation, a 0.01 USD pricing tick, and a 1 USD admission tick. Other cadences are disabled. The protocol audit verifies the 500,000 USDC pool-value cap, five-minute valuation window, and 2,000 ms no-trade window.

Deployment creates oracle objects and bindings without requiring live observations. It neither reads nor sets reference prices, funds individual markets, nor launches writers. Initial capital remains in the pool. Market creation requires a lifecycle cap, while processing the initial supply requires a valuation cap; both setup caps remain with the deployer alongside all package upgrade, root/admin, treasury, and metadata capabilities.

Authorization of the fresh `DeepbookCoreAccountApp` in the existing DeepBook registry belongs to that registry's administrator. The audit records its observed boolean status in the manifest; pending authorization does not block Predict deployment completion. The wrapper cannot interact with DeepBook core until that authorization is granted.

## Issue operational capabilities

After contract deployment completes, provide the recipient's full nonzero Sui address:

```sh
corepack npm exec -- tsx deployment/deploy.ts issue-caps --recipient <address>
corepack npm exec -- tsx deployment/deploy.ts issue-caps --recipient <address> --execute
```

The first invocation checks the target without broadcasting. The execution command mints a new `MarketLifecycleCap` and `PoolValuationCap` and transfers both using `sui::transfer::public_party_transfer` in one transaction. It verifies each object's `ConsensusAddressOwner`, records both IDs and the transaction in the private journal, and prints the result. Setup caps and root capabilities are retained; no existing capability is handed off.

Each recipient has one recorded issuance. Repeating the same command verifies the original receipt and ownership without minting again. A different recipient is a new explicit issuance. An in-flight issuance must be reconciled using its original recipient before another command or recipient can proceed. Issuance does not regenerate the deployment configuration snapshot.

## Recovery and artifacts

`deployment.testnet.state.json` is the mode-`0600`, gitignored schema-5 operator journal. It holds source and execution bindings, package identities, transaction intents and receipts, bootstrap attribution, setup capabilities, and recipient-specific issuance records. It contains no signing keys. A schema-4 journal cannot be resumed with this workflow.

Preserve the journal, exact source commit, Sui binary, client configuration, gas budgets, and generated publication metadata across an interrupted deployment. Known digests are reconciled on-chain; ambiguous submissions never trigger a replacement broadcast. Every deployment completion runs a fresh audit. After success, commit the generated `Published.toml` records and `deployment.testnet.json` without changing deployment source. Cap issuance permits these artifact-only commits; ordinary deployment resumes require the original source commit.

For an explicitly authorized deployment-script correction after all seven publications, use `--resume-script-from <full-original-source-commit>` alongside `--execute`. Recovery refuses any in-flight submission and any source difference outside this script, its tests, this README, and generated deployment artifacts. It re-verifies published packages, retains `sourceCommit` as the contract-source authority, and records the executing correction commit in the private journal's `scriptCommits`. It cannot resume a completed deployment or publish a changed contract family.

`deployment.testnet.json` is the public schema-8 integration manifest: packages, currencies, shared objects, oracle dependencies and bindings, external authorization status, replay checkpoint, units, and version/digest-anchored initial configuration. It contains no preselected writer addresses, operational caps, bootstrap accounts, transaction receipts, or administrative capabilities. Runtime consumers read mutable policy from the chain. Later cap issuance is reported through its separate command and private journal.

## Verification

```sh
corepack npm run build
corepack npm test
```

Tests cover publication identity and recovery, non-broadcasting defaults, deployment orchestration and interruption/resume boundaries, capitalization before market creation, expired-market resume, pending external authorization, explicit recipient parsing, atomic cap-issuance transaction construction, ownership verification, receipt recovery, and manifest validation.
