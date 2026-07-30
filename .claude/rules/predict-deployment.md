---
paths:
  - "packages/predict/deployment/**"
---

# Predict publication and deployment

Read this before creating, changing, running, resuming, or auditing a script that publishes or wires the Predict package suite. Also read `.claude/rules/move.md` whenever the work touches `Move.toml` or `Published.toml`.

## Workflow contract

- Treat deployment as a resumable state machine, not a linear shell recipe. The same workflow owns preflight, package publication, protocol wiring, bootstrap, capability handoff, final audit, and integration-manifest generation.
- Make the default invocation non-broadcasting. Require an explicit execution flag before any transaction can be submitted, and print the fully resolved target, signer, source commit, package plan, and expected capability recipients at the go/no-go boundary.
- Bind a run to an exact network, chain identifier, RPC environment, signer, Sui CLI version, source commit, and capability-recipient set. Refuse to start or resume if any binding changes.
- Point CLI and SDK operations at the same validated Sui client configuration and keystore for the entire run. If the workflow snapshots client configuration, keep the copy mode-restricted, remove it on exit, and never mutate the operator's active environment.
- Acquire a repository-shared lock keyed by the deployment target before preflight. Two processes must not publish or wire the same deployment concurrently.

## Preflight

- Verify the exact Sui CLI version and binary, SDK-reported chain identifier, CLI environment, active address, expected signer, gas balance, per-step gas budgets, and source commit before broadcasting.
- Require a committed source tree and enumerate the narrow generated files the workflow may change. Refuse unrelated dirt and refuse a source-commit change during a resumed run.
- Build every package with warnings treated as errors before publication.
- Resolve the complete Move dependency closure and validate an explicit topological publication plan from the package manifests. Do not copy a previous deployment's order without rechecking the current graph.
- Verify every already-published package and external object against the target chain by package or object ID, original ID where applicable, type, and ownership before any new package is published.

## Move publication

- Never use `--with-unpublished-dependencies`; implicit republication changes package and type identity.
- Use normal dependency verification by default. If an immutable on-chain dependency cannot be byte-for-byte reproduced by the selected historical toolchain, isolate the failing dependency, verify all resolved package and original IDs against the target chain, make any `--skip-dependency-verification` use explicit and local to the affected publish command, and record the justification in the workflow.
- Do not change production `Move.toml`, `Published.toml`, or contract source to accommodate localnet, simulation, or verifier behavior.
- After each publish, derive the package ID, transaction digest, created shared objects, owned capabilities, and upgrade capability from the receipt and target chain. Verify the resulting `Published.toml` identity before checkpointing the step.
- If publication metadata appears without the corresponding operator checkpoint, stop and reconcile the package and sender transaction history; do not assume either the file or journal is authoritative by itself.

## Operator journal and transaction recovery

- Keep the private operator journal separate from the public integration manifest. The journal is gitignored, mode `0600`, contains no secret material, and is written atomically with temp-file-plus-rename.
- Record the schema version, target bindings, source commit, package identities, completed steps, and current in-flight submission in the journal.
- Persist transaction intent before submission and checkpoint every irreversible result immediately after target-chain verification.
- For SDK-built transactions, derive and persist the transaction digest from the built transaction-data bytes before signing or submission, then sign and submit those exact bytes. A transport error with a known digest is an ambiguous submission to reconcile on-chain, not permission to construct replacement bytes.
- A CLI submission that fails before returning a digest is also ambiguous. Fail closed, inspect the deployer's transaction history and affected `Published.toml`, and resume only after proving whether the transaction landed.
- Never automatically retry an ambiguous write. Retry only after proving the original transaction did not execute.
- On resume, verify every completed checkpoint against the target chain and require the original source commit, signer, client environment, toolchain, package identities, and journal. Resume from verified chain state rather than trusting local completion flags.

## Wiring, configuration, and custody

- Implement every wiring operation as an idempotent `ensure` step: read current chain state, skip when it is already correct, submit only when necessary, then read back and assert the intended state.
- Treat mutable protocol and cadence configuration as chain-owned. Deployment inputs initialize shared objects; keepers and other services must read the live shared-object values rather than treating deployment defaults or the integration manifest as current authority.
- Use the Sui `Clock` and live cadence state for time-sensitive initialization. If a cadence window is full, wait for a valid slot and resume instead of changing policy or creating duplicate markets.
- Inventory every publisher, upgrade, admin, metadata, oracle-writer, and lifecycle capability created or consumed by the workflow, including its expected final owner.
- Perform irreversible capability handoff last, after package publication, authorization, oracle wiring, configuration, bootstrap, funding, and market-readiness checks succeed. Verify the final owner on-chain.

## Completion audit

- Audit package publication provenance, linked dependency identities, expected shared and owned object types, Predict application authorization, Propbook oracle bindings and writers, cadence configuration, and capability ownership from the target chain.
- Audit bootstrap events and their account attribution, enabled-cadence market coverage, funding, pending lifecycle queues, and the pool accounting invariants exposed by the deployed package.
- Record the earliest relevant package-publication checkpoint as the indexer's replay start; a later wiring or completion transaction can omit deployment events.
- Mark the journal `complete` only after the entire audit passes. A partial, failed, ambiguous, or in-flight run must never produce or replace the public integration manifest.

## Public integration manifest

- Generate the integration manifest deterministically from a complete, audited journal. It may contain stable network and chain identity, source and toolchain identity, package and shared-object IDs, coin types, oracle and writer identities, the replay checkpoint, units, and an initial configuration snapshot.
- Anchor every mutable-object snapshot to its exact object version and digest. If the RPC cannot read the requested historical version, bracket the configuration read with object-reference reads and reject the snapshot unless the version and digest remain unchanged.
- A transaction checkpoint is a verification fence, not proof that mutable object values were read at that checkpoint.
- Exclude deployer and bootstrap accounts, transaction receipts and incidental digests, temporary markets, balances, rebalances, private topology, and publisher, upgrade, admin, or metadata capabilities from the public manifest.

## Verification

- Add deterministic tests for non-broadcasting default behavior, wrong chain, wrong signer, wrong CLI version, dirty or changed source, dependency-plan validation, known-digest recovery, unknown-digest fail-closed behavior, and idempotent resume.
- Inject a failure after every irreversible step and prove the next run reconciles rather than duplicates it.
- Prove the manifest cannot be written before completion and rejects operator-only fields. Validate deterministic manifest generation against an independent explicit fixture, never an expected value derived from the generator's own output.
