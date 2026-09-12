# Predict contract deployment

This workflow publishes, wires, capitalizes, and verifies a Predict contract suite on an explicit Sui network. It does not deploy keepers or indexers. Operational capability issuance is a separate command with an explicit recipient.

## Execution gates

Legacy Testnet Pyth source and its reconstructed publication record are [vendored with provenance](../../../vendor/pyth_lazer/README.md). [Mainnet Pyth v2](../../../vendor/pyth_lazer_mainnet/README.md) records its generated version metadata and exact Wormhole Mainnet source. Both network closures resolve without cache metadata patches.

The build and deployment compiler is `sui 1.78.1-722ac4fcf484`; CI owns the release pin. Before publication and again before each package, `verify_dependencies.py` checks the Sessions dependency closure against the selected chain. Modern dependencies use the CLI's per-package `verify-source`. Mainnet Circle, Wormhole, and DEEP use isolated offline builds with `sui 1.32.2-a5eab1a75fa8` and complete serialized-module comparison; a reproducing compiler does not establish the original publication compiler. Original IDs, package versions, and nonframework linkage must match publication records. The compiled Sui/stdlib module sets must match the live framework. Any mismatch blocks execution; there is no verification bypass.

Default gas caps reserve 5 SUI per package and 1 SUI per remaining transaction. They are conservative limits, not measured fees; a fresh Mainnet run funded with 10 SUI does not pass this gate. `PACKAGE_GAS_BUDGET` and `TRANSACTION_GAS_BUDGET` accept positive base-unit caps and become immutable journal bindings. Select lower caps only after measuring the complete publication and wiring plan with the reviewed source and toolchain. Every SDK transaction is simulated with checks enabled before signing.

Mainnet consumers pin DeepBook's v8 publication revision rather than the development checkout's unpublished APIs and select the [bytecode-backed DEEP reconstruction](../../../vendor/deep_mainnet/README.md). The explicit token override replaces the upstream floating source; shadowed publication identities must agree. The complete DEEP module reproduces its immutable Mainnet bytes without changing the local Testnet token source or DEEP's identity. [S-7](../predeploy/open-items.md#s-7-mainnet-publication-verification-and-gas-plan) tracks the execution-time verification and gas plan.

## Operator inputs

Use the exact pinned CLI, Python 3.11 or newer, a clean committed deployment branch, and a client configuration whose active signer matches `--deployer`. The requested network must have its correct chain identifier in that configuration. `SUI_BINARY` selects the CLI; Mainnet additionally requires `SUI_LEGACY_BINARY` pointing to the historical compiler above. `SUI_CLIENT_CONFIG` optionally selects the configuration. No deployer or operational recipient is embedded in source. CLI and SDK share one mode-restricted configuration snapshot and keystore. The snapshot selects the requested network without changing the operator's active environment. Do not set `SUI_KEYSTORE_PATH`.

```sh
cd packages/predict
corepack npm exec -- tsx deployment/deploy.ts --network mainnet --deployer <address>
corepack npm exec -- tsx deployment/deploy.ts --network mainnet --deployer <address> --execute
```

Both target arguments are required even for preflight. Without `--execute`, the command checks source, chain, signer, dependencies, external objects, and funding without transactions. It prints network, signer, source, package plan, and capitalization amounts before the broadcast boundary.

## Mainnet sequence

1. Publish `fixed_math`, `account`, `propbook`, `predict`, `deepbook_core_account`, and `sessions` in dependency order. Circle USDC, DeepBook, DEEP, Pyth, Wormhole, and Block Scholes remain existing dependencies.
2. Verify native USDC's existing shared `coin_registry::Currency`, exact type identity, six decimals, and symbol; finalize only the new PLP registration. No Circle treasury or metadata authority is acquired or used.
3. Authorize Predict, the DeepBook Account wrapper, and Sessions in the fresh Account registry. Create and bind BTC oracle objects, register BTC, and configure cadences.
4. Lock exactly 10 USDC. Verify the `CapitalLocked` event's vault and amount. There is no bootstrap Account, LP supply request, valuation flush, or user PLP allocation. The 10,000,000 total PLP units represent locked liquidity, not user-owned PLP.
5. Create initial BTC 1-minute and 5-minute market objects, bounded to two per cadence and available slots. A higher-cadence overlap can leave one slot unavailable. Persist receipts; do not replace expired initial markets on resume.
6. Audit provenance, dependencies, objects, authorization, oracle bindings, retained caps, configuration, market coverage, and capital accounting. Require 10 USDC idle, zero market cash, and empty LP request queues.

USDC payments use `coinWithBalance`, including address-balance withdrawals. Mainnet SDK gas uses an empty gas-object list and requires SUI address balance. CLI publications use the same signer and network. No DEEP funding is required.

Deployment neither reads nor sets reference prices, requires fresh observations, funds individual markets, nor launches writers. It checks oracle signer validity independently of observations. Enabled cadences have two-market windows, 2,000 USDC initial-expiry-cash policy, 10,000 USDC maximum allocation, a 0.01 USD pricing tick, and a 1 USD admission tick. Other cadences are disabled. The audit checks the 500,000 USDC pool-value cap, five-minute valuation window, and 2,000 ms no-trade window.

Authorization of `DeepbookCoreAccountApp` in the existing DeepBook registry belongs to that registry's administrator. The audit records its observed status without inspecting the administrator's custody arrangement. Pending authorization does not block Predict wiring completion, but the wrapper cannot interact with DeepBook core until authorized.

## Testnet sequence

Testnet consumers pin DeepBook's v20 publication revision `ce0e5cd052d7d1eb195bb486396730c550f8f92a` through network-specific dependency replacements. The existing Testnet token remains the explicit shared dependency; unpublished changes in the local DeepBook checkout are not included in Testnet publication builds. Mainnet retains its separate v8 revision.

Use `--network testnet`. Testnet preserves its external identities, additionally publishes `usdc`, finalizes USDC and PLP registrations, and mints 100,000,000 test USDC with display symbol `DUSDC`. It locks 10 USDC and supplies 250,000 USDC through a deployer Account, completing allocation through an empty-pool valuation before markets. Its audit checks mint accounting and LP account attribution. Explicit dependency source verification is required on both networks.

To redeploy the protocol while retaining an existing Testnet currency, provide both `--existing-usdc-package <package-id>` and `--existing-usdc-currency <currency-id>`. The package must match `packages/usdc/Published.toml` and the resolved Move collateral address; its source is verified against Testnet, and the existing shared Currency must have that exact type, six decimals, and symbol `DUSDC`. This mode publishes the six protocol packages but neither publishes USDC, finalizes its registration, nor accesses its TreasuryCap. It requires 250,010 existing USDC before publication, locks 10, and supplies 250,000 with the same receipt/account-attribution checks. USDC mint accounting is zero for this run; global pre-existing supply and other holders' balances are not deployment-owned accounting.

Both existing-USDC IDs are journal bindings and must be repeated on preflight, execution, resume, and `issue-caps`. A missing or changed selection fails closed. Mainnet rejects these flags and retains its fixed Circle identity. For a fresh redeployment, preserve the previous journal and manifest in their original worktree and use a clean new worktree with no operator journal; do not resume or overwrite the old run. The audited new manifest replaces the prior integration manifest only at completion. Other-network publication records and the reused USDC publication record remain unchanged.

## Issue operational capabilities

After a complete audited deployment, provide a full nonzero recipient address:

```sh
corepack npm exec -- tsx deployment/deploy.ts issue-caps --network mainnet --deployer <address> --recipient <keeper-address>
corepack npm exec -- tsx deployment/deploy.ts issue-caps --network mainnet --deployer <address> --recipient <keeper-address> --execute
```

Execution mints a `MarketLifecycleCap` and `PoolValuationCap` and transfers both with `sui::transfer::public_party_transfer` in one transaction. It verifies `ConsensusAddressOwner` and records IDs and transaction in the private journal. Existing setup, admin/root, upgrade, publisher, and metadata capabilities remain with the deployer. Root/upgrade handoff is a separate explicitly authorized operation after verification.

Each recipient has one recorded issuance. Repeating the command verifies its original receipt and ownership without minting again. Another recipient is a new explicit issuance. Reconcile an in-flight issuance with its original recipient before proceeding. Issuance does not regenerate the configuration snapshot.

## Recovery and artifacts

`deployment.<network>.state.json` is the mode-`0600`, gitignored schema-6 operator journal. It contains execution/source bindings, transaction intents and receipts, package identities, bootstrap attribution, setup caps, and issuance records, but no keys. A repository-shared network lock prevents concurrent runs.

Preserve the journal, exact source commit, binary, configuration, gas caps, and publication metadata after interruption. Reconcile known digests on-chain; never replace ambiguous submissions. Every completion runs a fresh audit. After success, commit generated `Published.toml` records and the manifest without changing source. Publication records preserve other-network history. Cap issuance permits artifact-only commits; ordinary resumes require the original source commit.

An authorized script-only correction after all publications can use `--resume-script-from <full-original-source-commit>` with `--execute`. This rejects in-flight transactions and changes outside deployment script/tests/README and generated artifacts. It re-verifies packages, retains `sourceCommit`, and records correction commits in ordered `scriptCommits`. Subsequent interruptions use ordinary `--execute` at that recorded commit. A script switch cannot resume a complete deployment or publish changed contracts.

`deployment.testnet.json` retains integration schema 8. `deployment.mainnet.json` uses schema 9: `objects.usdcCurrency` names native USDC's existing shared Currency rather than a newly published test currency. Both contain stable package/shared/oracle identities, external authorization, replay checkpoint, units, and version/digest-anchored initial configuration. They exclude operator addresses, bootstrap accounts, receipts, and admin caps. Runtime consumers read mutable policy from chain. Only a complete audited journal can generate a manifest.

## Verification

```sh
corepack npm run build
node --import tsx --test deployment/deploy.test.ts
python3 -m unittest discover -s deployment -p 'test_*.py'
```

Tests cover explicit targets, non-broadcasting defaults, source/package binding, identity validation, network publication history, recovery, both orchestration paths, interruption boundaries, native-USDC lock transaction and event validation, market resume, explicit recipient parsing, atomic cap issuance, and manifest validation. These deterministic tests do not prove live dependency verification or the funded gas budget passes.
