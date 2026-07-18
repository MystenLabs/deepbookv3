# Predict unit tests

Predict tests use one shared architecture so a new test extends an existing state model instead of creating another fixture world. This file explains where a test belongs, what setup it may reuse, and where its expected truth must come from.

## Claim layers

| Layer | What it proves | Expected truth |
|---|---|---|
| Framework | Scenario ownership, stable IDs, actor progression, teardown | Constructor inputs and captured identities |
| Structure | Construction, bindings, authority, config snapshots, public reads | Supplied IDs/configuration and named production guards |
| Mechanics | Exact integer operations, local state machines, boundaries, rounding | Algebra, explicit inputs, and independently calculated exact values |
| Numerical reference | Approximate on-chain math against the intended real model | A committed independent generator and an ex-ante precision bound |
| Flow/economics | Multi-object transitions, conservation, backing, liabilities, liveness | Input-derived deltas, conservation identities, and independently established economic vectors |
| Policy/audit | Deliberate response policies and regression pins | The named policy or audited requirement |

One test may use several layers as prerequisites, but it should make one primary claim. Split a test when one assertion would otherwise treat structural wiring, fixed-point output, true-model accuracy, and economic accounting as the same fact.

## Scope and intent

The directory and module name encode scope: `framework`, `mechanics`, `structure`, or `flow`. A dedicated module also carries an intent token: `behavior`, `guard`, `boundary`, `rounding`, `accounting`, `reference`, or `policy`.

Examples:

- `tests/mechanics/range_codec_rounding_tests.move` → `mechanics_range_codec_rounding_tests`
- `tests/structure/oracle_guard_tests.move` → `structure_oracle_guard_tests`
- `tests/flow/mint_accounting_tests.move` → `flow_mint_accounting_tests`

Sui's test filter matches the fully qualified test name, so either dimension is selectable:

```sh
sui move test --path packages/predict --gas-limit 100000000000 mechanics_
sui move test --path packages/predict --gas-limit 100000000000 _rounding_
sui move test --path packages/predict --gas-limit 100000000000 flow_
```

## Fixture architecture

`framework/test_world.move` is the only Scenario owner. It initializes package roots, owns Clock and administrative capabilities, records stable shared-object IDs, exposes explicit `next_tx`, and tears down the world.

Subject setup modules compose production-valid prerequisites in the caller's current transaction. Handles carry identity and immutable metadata only; shared production state remains in Scenario inventory and is taken by ID.

Use this decision sequence:

1. For pure math, value types, codecs, or local data structures, construct local values and do not create a World.
2. For construction, binding, authority, or public-read claims, create the minimum World and subject prerequisites.
3. For multi-object economics, compose the same World with production-valid market, oracle, pool, and account prerequisites.
4. Add a shared helper only after repeated callers establish the same production-valid prerequisite or identity shape. Keep one-subject builders local.
5. Never add another Scenario owner, a universal optional builder, or a fixture wrapper that mirrors a production operation.

The test body owns every post-bootstrap actor change and `next_tx`. A setup helper must not advance the transaction. The test calls its production unit under test directly; setup may call earlier production transitions only when those transitions are explicit prerequisites for a different claim.

## Expected truth

Fixtures create state; they are never correctness oracles. Before adding a test, write down its primary claim, production unit under test, fixture/profile, expected-value source, and what a failure means.

Exact chain semantics and true-model accuracy are different claims. Use exact assertions for algebraically exact integer results, identities, clamps, and explicit rounding. For approximate pricing/math, compare against committed independently generated true-model values within a bound derived before the contract runs from the documented primitive precision contracts.

Generated reference data must identify its generator and regeneration command, include every input needed to reproduce it, and exercise every emitted vector against the production function. A generator may use Python standard-library math or another independent implementation, but it must not import the contract's fixed-point replay or measure tolerance from observed Move output. The pricing generator validates profiles against the production input envelope before emission and rejects any propagated acceptance tolerance above its independently declared 10,000-unit ceiling at 1e9 scale (0.1 basis point of payout probability).

If independently valid truth falls outside its bound, keep the finding visible and follow the RED protocol in `.claude/rules/unit-tests.md`. Do not change the expected value, widen the tolerance, or convert the mismatch into an expected failure.

## Adding a test

1. Choose the primary claim layer, scope path, and intent token.
2. Identify the production UUT and the minimum state/transaction borrow set it requires.
3. Reuse the World and focused prerequisite modules; keep pure units local.
4. Establish the expected-value oracle independently before running the test.
5. Call the production UUT visibly in the test body and assert the state/output owned by that claim.
6. Return every shared object, destroy or transfer every owned non-droppable value, and finish the World.
7. Run the scope and intent filters, then the warning-strict build and full Predict suite.

Run `python3 packages/predict/tests/check_architecture.py` before the Move commands. CI runs the same deterministic structural check; it verifies the single Scenario owner, ID-based shared retrieval boundary, visible transaction progression, executable module taxonomy, and live generated-data provenance links. It does not judge expected values or economic meaning.
