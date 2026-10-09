# Predict contract deployment

This workflow publishes, wires, capitalizes, and verifies a Predict contract suite on an explicit Sui network. It does not deploy keepers or indexers. It creates one operational capability pair for setup; handoff of that same pair is a separate command with an explicit recipient.

From package version 4, Predict depends on `deepbook_predict_math`, and the delayed-execution order flow lives in `deepbook_predict_orders`, which depends on Predict and which Sessions links. Moving an existing deployment to version 4 is a package upgrade, run by its own workflow, `upgrade_v4.ts`, described in its section below. [Architecture](../docs/design/architecture.md#version-gating) owns the order it follows: the publishes and upgrades, the monitoring and registry registrations, the indexer start, the allowlist and launch-fee transaction, queue creation, the Sessions upgrade, the service moves, the watermark bumps, the Testnet gas measurement, and reopening trading.

## Execution gates

Legacy Testnet Pyth source and its reconstructed publication record are [vendored with provenance](../../../vendor/pyth_lazer/README.md). [Mainnet Pyth v2](../../../vendor/pyth_lazer_mainnet/README.md) records its generated version metadata and exact Wormhole Mainnet source. Both network closures resolve without cache metadata patches.

The build and deployment compiler is `sui 1.78.1-722ac4fcf484`; CI owns the release pin. Before publication and again before each package, `verify_dependencies.py` checks the Sessions dependency closure against the selected chain. Modern dependencies use the CLI's per-package `verify-source`. DEEP on both networks and Mainnet Circle/Wormhole use isolated offline builds with `sui 1.32.2-a5eab1a75fa8` and complete serialized-module comparison; a reproducing compiler does not establish the original publication compiler. Testnet Pyth/Wormhole use the current compiler and lossless historical serialization through `bytecode/`, which pins the official Move serializer to the same CLI revision: every compiled module must reproduce the published bytes and round-trip to the original compiled bytes without losing data. Original IDs, package versions, and nonframework linkage must match publication records. The compiled Sui/stdlib module sets must match the live framework. Any mismatch blocks execution; there is no verification bypass.

Default gas caps reserve 5 SUI per package and 1 SUI per remaining transaction. They are conservative limits, not measured fees; a fresh Mainnet run funded with 10 SUI does not pass this gate. `PACKAGE_GAS_BUDGET` and `TRANSACTION_GAS_BUDGET` accept positive base-unit caps and become immutable journal bindings. Select lower caps only after measuring the complete publication and wiring plan with the reviewed source and toolchain. Every SDK transaction is simulated with checks enabled before signing.

Mainnet consumers pin DeepBook's v8 publication revision rather than the development checkout's unpublished APIs. Both networks select the [bytecode-backed DEEP reconstruction](../../../vendor/deep/README.md) through an explicit token override; shadowed publication identities must agree. The complete DEEP module reproduces both immutable publications without changing either token identity or the development source in `packages/token`. [S-7](../predeploy/open-items.md#s-7-mainnet-publication-verification-and-gas-plan) tracks the execution-time verification and gas plan.

## Operator inputs

Use the exact pinned CLI, Python 3.11 or newer, a clean committed deployment branch, and a client configuration whose active signer matches `--deployer`. The requested network must have its correct chain identifier in that configuration. `SUI_BINARY` selects the CLI; both networks require `SUI_LEGACY_BINARY` pointing to the historical compiler above. Testnet also requires Rust/Cargo to build the locked bytecode verifier; the executable is reused by subsequent checks. `SUI_CLIENT_CONFIG` optionally selects the configuration. No deployer or operational recipient is embedded in source. CLI and SDK share one mode-restricted configuration snapshot and keystore. The snapshot selects the requested network without changing the operator's active environment. Do not set `SUI_KEYSTORE_PATH`.

```sh
cd packages/predict
corepack npm exec -- tsx deployment/deploy.ts --network mainnet --deployer <address>
corepack npm exec -- tsx deployment/deploy.ts --network mainnet --deployer <address> --execute
```

Both target arguments are required even for preflight. Without `--execute`, the command checks source, chain, signer, dependencies, external objects, and funding without transactions. It prints network, signer, source, package plan, and capitalization amounts before the broadcast boundary.

## Mainnet sequence

1. Publish `fixed_math`, `account`, `propbook`, `predict_math`, `predict`, `predict_orders`, `deepbook_core_account`, and `sessions` in dependency order. The pricing-math library publishes before Predict, the order-flow companion after it, and Sessions, which wraps the companion, after both. The companion's publish creates and shares its one `OrderDesk` with the launch delayed-execution policy, and the journal records the desk from that receipt. Circle USDC, DeepBook, DEEP, Pyth, Wormhole, and Block Scholes remain existing dependencies.
2. Verify native USDC's existing shared `coin_registry::Currency`, exact type identity, six decimals, and symbol; finalize only the new PLP registration. No Circle treasury or metadata authority is acquired or used.
3. Authorize Predict, the DeepBook Account wrapper, and Sessions in the fresh Account registry. Create and bind BTC oracle objects, register BTC, and configure cadences.
4. One admin transaction (`enable_order_flow`): allowlist the companion with `protocol_config::set_order_flow<deepbook_predict_orders::order_flow::OrderFlow>(true)`, then `desk::set_order_fee` with the desk's launch order fee (20,000, read from the desk). Re-stating the fee changes nothing, but it emits `DelayedExecutionPolicyUpdated`, which records the launch policy and the desk ID for the indexer, since the desk's `init` emits none. A fresh publish starts the version watermark at `current_version!()`, which is past the delayed-execution cutover, so only queued trading is open, and Predict refuses the companion's admissions, commits, and fills until its witness is allowlisted. Both calls are idempotent, so the step is keyed on its journal entry, and its receipt must carry the enabling `OrderFlowUpdated` and one `DelayedExecutionPolicyUpdated` naming this desk with the launch policy. Mainnet's lock-only bootstrap runs no flush, so the deployer gets no flush-operator grant.
5. Lock exactly 10 USDC. Verify the `CapitalLocked` event's vault and amount. There is no bootstrap Account, LP supply request, valuation flush, or user PLP allocation. The 10,000,000 total PLP units represent locked liquidity, not user-owned PLP.
6. Create initial BTC 1-minute and 5-minute market objects, bounded to two per cadence and available slots. A higher-cadence overlap can leave one slot unavailable. Persist receipts; do not replace expired initial markets on resume. Then create each recorded market's `MarketQueue` with `queue::create_and_share`, one transaction per market (`create_queue_<cadence>_<n>`), because a market shared in one transaction cannot be borrowed later in the same transaction. A queue lives at the ID derived from the desk and the market (`queue::queue_id`), and creation is permissionless, so a queue that already exists, whoever created it, is recorded instead of created again.
7. Audit provenance, dependencies, objects, authorization, oracle bindings, retained caps, configuration, the allowlisted order-flow witness and the `enable_order_flow` receipt's launch-policy event, the desk's launch policy and its floor of 1, market coverage, each active market's queue, and capital accounting. Each queue must be shared and bound to the desk and its market. Require 10 USDC idle, zero market cash, and empty LP request queues. The expected Predict version watermark is `constants::current_version!()`, the expected Sessions watermark is `session_config::current_version!()`, and the expected desk floor and policy are the companion's `current_version!()` and launch defaults, which tests pin to the Move sources.

USDC payments use `coinWithBalance`, including address-balance withdrawals. Mainnet SDK gas uses an empty gas-object list and requires SUI address balance. CLI publications use the same signer and network. No DEEP funding is required.

Deployment neither reads nor sets reference prices, requires fresh observations, funds individual markets, nor launches writers. It checks oracle signer validity independently of observations and requires the live Pyth State's upgrade version to match the selected package. Enabled cadences have two-market windows, 2,000 USDC initial-expiry-cash policy, 10,000 USDC maximum allocation, a 0.01 USD pricing tick, and a 1 USD admission tick. Other cadences are disabled. The audit checks the 500,000 USDC pool-value cap, five-minute valuation window, and 2,000 ms no-trade window. The deployment changes no delayed-execution policy value. It only re-states the launch order fee so the policy event exists. The desk keeps its launch policy: an 800 ms delay on the `fixed_rate@200ms` channel, 100 queued mints and 100 queued sells per market, five orders per account, and a 0.02 USDC order fee. An admin changes it afterwards with `desk::set_timing`, `desk::set_limits`, and `desk::set_order_fee`.

Authorization of `DeepbookCoreAccountApp` in the existing DeepBook registry belongs to that registry's administrator. The audit records its observed status without inspecting the administrator's custody arrangement. Pending authorization does not block Predict wiring completion, but the wrapper cannot interact with DeepBook core until authorized.

## Testnet sequence

Testnet consumers pin DeepBook's v20 publication revision `ce0e5cd052d7d1eb195bb486396730c550f8f92a` through network-specific dependency replacements. The shared DEEP reconstruction resolves to the existing Testnet token identity; unpublished changes in the local DeepBook checkout are not included in Testnet publication builds. Mainnet retains its separate v8 revision.

Use `--network testnet`. Testnet preserves its external identities, additionally publishes `usdc`, finalizes USDC and PLP registrations, and mints 100,000,000 test USDC with display symbol `DUSDC`. It locks 10 USDC and supplies 250,000 USDC through a deployer Account, completing allocation through an empty-pool valuation before markets. Before the bootstrap it allowlists the order-flow companion, as on Mainnet, and adds the deployer as a flush operator (`add_flush_operator`), because `finish_flush` admits only flush operators and the deployer completes the bootstrap flush. The audit also requires the deployer to be a flush operator. Its audit checks mint accounting and LP account attribution. Explicit dependency source verification is required on both networks.

To redeploy the protocol while retaining an existing Testnet currency, provide both `--existing-usdc-package <package-id>` and `--existing-usdc-currency <currency-id>`. The package must match `packages/usdc/Published.toml` and the resolved Move collateral address; its source is verified against Testnet, and the existing shared Currency must have that exact type, six decimals, and symbol `DUSDC`. This mode publishes the eight protocol packages but neither publishes USDC, finalizes its registration, nor accesses its TreasuryCap. It requires 250,010 existing USDC before publication, locks 10, and supplies 250,000 with the same receipt/account-attribution checks. USDC mint accounting is zero for this run; global pre-existing supply and other holders' balances are not deployment-owned accounting.

Both existing-USDC IDs are journal bindings and must be repeated on preflight, execution, resume, and `issue-caps`. A missing or changed selection fails closed. Mainnet rejects these flags and retains its fixed Circle identity. For a fresh redeployment, preserve the previous journal and manifest in their original worktree and use a clean new worktree with no operator journal; do not resume or overwrite the old run. The audited new manifest replaces the prior integration manifest only at completion. Other-network publication records and the reused USDC publication record remain unchanged.

## Hand off operational capabilities

After a complete audited deployment, provide a full nonzero recipient address:

```sh
corepack npm exec -- tsx deployment/deploy.ts issue-caps --network mainnet --deployer <address> --recipient <keeper-address>
corepack npm exec -- tsx deployment/deploy.ts issue-caps --network mainnet --deployer <address> --recipient <keeper-address> --execute
```

The `issue-caps` command transfers the original setup `MarketLifecycleCap` and `PoolValuationCap` with `sui::transfer::public_party_transfer` in one transaction; it never mints another pair. The same transaction adds the recipient as a flush operator unless it already is one, because the pool-valuation cap holder is the keeper that completes flushes and `finish_flush` admits only flush operators. The command fails closed unless the role reads back afterward. It requires each registry allowlist to contain exactly its original setup cap, verifies `ConsensusAddressOwner`, updates the custody audit, and records the same two IDs and transaction in the private journal. Admin/root, upgrade, publisher, and metadata capabilities remain with the deployer. Root/upgrade handoff is a separate explicitly authorized operation after verification.

Each deployment has one recorded handoff recipient. Repeating the command verifies its original receipt, ownership and allowlists without submitting another transfer. Changing recipient after an in-flight or completed transfer fails closed, including when the transaction succeeded but the ownership read failed. Journals from the former duplicate-pair workflow are rejected rather than treated as single-pair deployments. Handoff does not regenerate the configuration snapshot.

## Upgrade an existing deployment to version 4

`upgrade_v4.ts` runs the on-chain steps of the first rollout on a deployment that is already live, with trading paused throughout:

1. Publish `deepbook_predict_math`.
2. Upgrade Predict with its UpgradeCap (Testnet package version 4 to 5, Mainnet 3 to 4), linked to the library. Its logical version is 4.
3. Publish `deepbook_predict_orders`. The journal records its OrderDesk and its publish checkpoint.
4. One admin transaction with Predict's AdminCap: `protocol_config::set_order_flow<OrderFlow>(true)`, then `desk::set_order_fee` with the launch fee read from the desk, then `protocol_config::add_flush_operator` for the market keeper's signer unless it already is one. Its receipt must carry the enabling `OrderFlowUpdated` and one `DelayedExecutionPolicyUpdated` naming the desk with the launch policy.
5. `queue::create_and_share` for every unexpired market in `plp::active_expiry_markets`, up to 50 per transaction. A market whose derived queue already exists is recorded, not created again.
6. Upgrade Sessions with its UpgradeCap, linked to Predict and the companion.
7. With `--cutover`: create the queues of markets opened since step 5, then bump Predict's watermark to 4 and Sessions' to 3 in one transaction.
8. With `--reopen`, after the cutover: unpause trading.

The run stops after step 6 until `--cutover`, so the keepers, indexer, servers, and SDK move to the printed IDs first. The indexer's first checkpoint is the Predict upgrade's, which the run also prints. The Testnet gas measurement sits between `--cutover` and `--reopen`. The steps outside the chain, the monitoring and registry registrations and the service moves, are not part of this command.

### Inputs

- `--network localnet|testnet|mainnet` and `--sender <address>`, the address that holds the four capabilities.
- `--flush-operator <address>`, the market keeper's signer. Version 4's `finish_flush` admits only flush operators, and Predict before version 4 has no such allowlist. The Testnet market keeper signs as `0xff241a369609060d3f34828b97a47a2d330644615ff57dfdd49f4f0dd299207f`.
- Testnet and Mainnet read the integration manifest (`deployment.<network>.json`) for the Predict and Sessions original IDs, `ProtocolConfig`, `PoolVault`, and `SessionsConfig`, and each package's `Published.toml` for its current package, version, and UpgradeCap. The AdminCap and SessionsAdminCap are the sender's one object of each type, or `--admin-cap` and `--sessions-admin-cap`.
- A localnet passes `--manifest` (the same fields), `--pubfile` (its ephemeral publication file), and `--workspace` (the staged packages the harness published, with the version 4 sources staged in place).
- `SUI_BINARY` selects a release 1.80.1 CLI, `SUI_CLIENT_CONFIG` the client configuration, whose environment named after the network is used without changing the active one. `PACKAGE_GAS_BUDGET` (default 5 SUI) and `TRANSACTION_GAS_BUDGET` (default 1 SUI) cap each transaction and are journal bindings. Gas comes from the sender's coins when they cover the budget, and otherwise from its address balance.

The preflight, which runs before every step and is the default, requires trading paused, Predict not frozen, Predict's watermark below 4 and Sessions' below 3, the UpgradeCaps owned by the sender and recording the expected package versions, both admin caps owned by the sender, and no existing publication record for the two new packages. Testnet and Mainnet also require a clean tree at the recorded source commit, apart from the four packages' `Published.toml` records, which the run writes after each publish or upgrade lands. Commits that only record publications may follow during a rollout.

### Testnet

Pause trading first. The preflight refuses an unpaused deployment.

```sh
cd packages/predict
corepack npm exec -- tsx deployment/upgrade_v4.ts --network testnet --sender <address> --flush-operator <keeper-signer>
corepack npm exec -- tsx deployment/upgrade_v4.ts --network testnet --sender <address> --flush-operator <keeper-signer> --execute
corepack npm exec -- tsx deployment/upgrade_v4.ts --network testnet --sender <address> --flush-operator <keeper-signer> --execute --cutover
corepack npm exec -- tsx deployment/upgrade_v4.ts --network testnet --sender <address> --flush-operator <keeper-signer> --execute --reopen
```

`--execute` signs with the active keystore address, which must be `--sender`. Each transaction is built, dry-run with checks, and journaled with its digest before it is signed. Package transactions come from `sui client publish|upgrade --serialize-unsigned-transaction` on a staged copy of the committed sources, built for the client environment the run selects, and the run checks that each one publishes to the sender or upgrades the recorded package through the recorded cap. Upgrades pass `--skip-verify-compatibility`, because release 1.80.1 cannot read Testnet's and Mainnet's protocol version 138, and the dry run on the target chain performs the authoritative compatibility check before anything is signed or emitted.

### Mainnet

Mainnet is never signed here. `--emit-unsigned` writes the next transaction for the multisig to `deployment.mainnet.upgrade-v4/<n>-<step>.json`, with its unsigned bytes, its gas-independent transaction kind, its digest, its commands, a normalized program, and the dry run, then stops:

```sh
corepack npm exec -- tsx deployment/upgrade_v4.ts --network mainnet --sender <multisig> --flush-operator <keeper-signer> --emit-unsigned
```

Execute it from the multisig and run the same command again. It records the transaction once it lands, writes the publication record, and emits the next step. If the multisig rebuilt the transaction, name what it executed with `--executed <step>=<digest>`: the run accepts it only from the sender and only when it runs the emitted program. `--cutover` and `--reopen` gate steps 7 and 8 the same way.

### Localnet

The harness stages and publishes the closure into an instance with its own publication file, so a localnet upgrade compiles in that workspace with `sui client test-publish|test-upgrade --build-env testnet --pubfile-path <pubfile>` and records each publication in the pubfile. Stage the version 4 `predict_math`, `predict`, `predict_orders`, and `sessions` sources over the workspace's packages with the harness's dependency rewrites first.

```sh
SUI_CLIENT_CONFIG=<instance>/localnet/client.yaml corepack npm exec -- tsx deployment/upgrade_v4.ts --network localnet --sender <address> --flush-operator <address> --manifest <instance>/deployment.localnet.json --pubfile <instance>/Pub.sim.toml --workspace <instance>/workspace --execute --cutover --reopen
```

### Journal and recovery

`deployment.<network>.upgrade-v4.state.json` (beside the publication file on a localnet) is the mode-`0600`, gitignored journal. It binds the network, chain, sender, flush operator, signing mode, CLI binary, RPC, client configuration, and gas budgets, and records the preflight baseline, each step's digest, the new package IDs, the desk, both checkpoints, each market's queue, and the last read-back. A transaction whose submission returned no answer stays in flight under its digest. The next run reconciles it on chain and never rebuilds it. Every run re-reads that trading is still paused and the admin caps are still the sender's, and ends by reading back what the completed steps promise: each package's version, linkage, publication record, and UpgradeCap, the desk's launch policy and floor, the allowlisted witness and its policy event, the flush operator, a queue bound to the desk for every live market, the watermarks after the cutover, and trading open after the reopen. The S-9 rehearsal ran this sequence on a localnet started from the version 3 closure with a live market and an instant-trade position.

## Recovery and artifacts

`deployment.<network>.state.json` is the mode-`0600`, gitignored schema-7 operator journal. Schema 7 adds the library and companion packages and each market's queue, so a journal from the earlier package plan is rejected rather than resumed. It contains execution/source bindings, transaction intents and receipts, package identities, bootstrap attribution, setup caps, and issuance records, but no keys. A repository-shared network lock prevents concurrent runs.

Preserve the journal, exact source commit, binary, configuration, gas caps, and publication metadata after interruption. Reconcile known digests on-chain; never replace ambiguous submissions. Every completion runs a fresh audit. After success, commit generated `Published.toml` records and the manifest without changing source. Publication records preserve other-network history. Cap issuance permits artifact-only commits; ordinary resumes require the original source commit.

An authorized script-only correction after all publications can use `--resume-script-from <full-original-source-commit>` with `--execute`. This rejects in-flight transactions and changes outside deployment script/tests/README and generated artifacts. It re-verifies packages, retains `sourceCommit`, and records correction commits in ordered `scriptCommits`. Subsequent interruptions use ordinary `--execute` at that recorded commit. A script switch cannot resume a complete deployment or publish changed contracts.

A new deployment writes integration schema 10 on Testnet and 11 on Mainnet. Both add the `predictMath` and `predictOrders` packages, the `orderDesk` object with its state anchor, and the desk's launch policy under `initialConfiguration.delayedExecution`. Per-market queues are not listed, as markets are not. The Mainnet schema still differs because `objects.usdcCurrency` names native USDC's existing shared Currency rather than a newly published test currency. The committed `deployment.testnet.json` (schema 8) and `deployment.mainnet.json` (schema 9) record earlier deployments until a new deployment replaces them. Both contain stable package/shared/oracle identities, external authorization, replay checkpoint, units, and version/digest-anchored initial configuration. They exclude operator addresses, bootstrap accounts, receipts, and admin caps. Runtime consumers read mutable policy from chain. Only a complete audited journal can generate a manifest.

## Verification

```sh
corepack npm run build
node --import tsx --test deployment/deploy.test.ts deployment/upgrade_v4.test.ts
python3 -m unittest discover -s deployment -p 'test_*.py'
cargo test --locked --manifest-path deployment/bytecode/Cargo.toml
```

Tests cover explicit targets, non-broadcasting defaults, source/package binding, identity validation, network publication history, recovery, both orchestration paths, interruption boundaries, native-USDC lock transaction and event validation, market resume, explicit recipient parsing, atomic cap handoff without minting, the package plan order, the desk record and its launch policy, the order-flow allowlist, per-market queue creation and resume, the flush-operator grants, the expected watermarks, single-pair allowlists, recipient binding across recovery, and manifest validation. The upgrade tests cover its explicit targets and signing modes, the pinned package versions, the step order and its gates, the preflight state, the journal bindings, the publication records of both kinds, the CLI's unsigned bytes and the package-program check, the admin, queue, watermark, and reopen transactions, the order-flow receipt, idempotent queue creation, resume without repetition, and the multisig program comparison. These deterministic tests do not prove live dependency verification or the funded gas budget passes.
