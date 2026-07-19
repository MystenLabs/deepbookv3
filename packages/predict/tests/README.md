# Predict unit tests

Predict tests use one shared architecture so a new test extends an existing state model instead of creating another fixture world. This file explains where a test belongs, what setup it may reuse, and where its expected truth must come from.

## Claim layers

| Layer | What it proves | Expected truth |
|---|---|---|
| Framework | Scenario ownership, stable IDs, actor progression, teardown | Constructor inputs and captured identities |
| Structure | Construction, bindings, authority, config snapshots, public reads | Supplied IDs/configuration and named production guards |
| Mechanics | Exact integer operations, local state machines, boundaries, rounding | Algebra, explicit inputs, and independently calculated exact values |
| Numerical reference | Representative implementation accuracy against the intended real model | A committed independent generator and an ex-ante precision bound |
| Flow/economics | Multi-object transitions, conservation, backing, liabilities, liveness | Input-derived deltas, conservation identities, and independently established economic vectors |
| Policy/audit | Deliberate response policies and regression pins | The named policy or audited requirement |

One test may use several layers as prerequisites, but it should make one primary claim. Split a test when one assertion would otherwise treat structural wiring, fixed-point output, true-model accuracy, and economic accounting as the same fact.

## Scope and intent

The directory encodes scope: `framework`, `mechanics`, `structure`, or `flow`. Every executable module uses the reserved shape `scope_<scope>__intent_<intent>__<subject>_tests`, where intent is `behavior`, `guard`, `boundary`, `rounding`, `accounting`, `reference`, or `policy`. Reserved `scope_*__` and `intent_*__` markers appear only in the module segment, never in test function names.

Examples:

- `tests/mechanics/range_codec_rounding_tests.move` → `scope_mechanics__intent_rounding__range_codec_tests`
- `tests/structure/oracle_guard_tests.move` → `scope_structure__intent_guard__oracle_tests`
- `tests/flow/mint_accounting_tests.move` → `scope_flow__intent_accounting__mint_tests`

Sui's test filter matches the fully qualified test name, so either dimension is selectable:

```sh
sui move test --path packages/predict --gas-limit 100000000000 scope_mechanics__
sui move test --path packages/predict --gas-limit 100000000000 intent_rounding__
sui move test --path packages/predict --gas-limit 100000000000 scope_flow__
```

## Fixture architecture

`framework/test_world.move` is the only Scenario owner. It initializes package roots, owns Clock and administrative capabilities, records stable shared-object IDs, exposes explicit `next_tx`, and tears down the world.

Create at most one World in a test function. When a test exercises several oracle profiles, reuse that World and seed each successive feed row with a strictly increasing source timestamp; restarting package initialization inside the same Sui test inventory collides with one-time registrations.

Subject setup modules compose production-valid prerequisites in the caller's current transaction. Handles carry identity and immutable metadata only; shared production state remains in Scenario inventory and is taken by ID.

Use this decision sequence:

1. For pure math, value types, codecs, or local data structures, construct local values and do not create a World.
2. For construction, binding, authority, or public-read claims, create the minimum World and subject prerequisites.
3. For multi-object economics, compose the same World with production-valid market, oracle, pool, and account prerequisites.
4. Add a shared helper only after repeated callers establish the same production-valid prerequisite or identity shape. Keep one-subject builders local.
5. Never add another Scenario owner, a universal optional builder, or a fixture wrapper that mirrors a production operation.

The test body owns every post-bootstrap actor change and `next_tx`. A setup helper must not advance the transaction. The test calls its production unit under test directly; setup may call earlier production transitions only when those transitions are explicit prerequisites for a different claim.

Executable unit tests and fixture modules live under `packages/predict/tests/**`, never `packages/predict/sources/**`. If the existing production surface and approved irreducible test-only seams cannot reach the required state or flow, stop and raise the testability gap; do not add a source-local test or convenience `#[test_only]` constructor to bypass fixture design.

## Expected truth

Fixtures create state; they are never correctness oracles. Before adding a test, write down its primary claim, production unit under test, fixture/profile, expected-value source, and what a failure means.

Exact chain semantics and true-model accuracy are different claims. Use exact assertions for algebraically exact integer results, identities, clamps, and explicit rounding. For approximate pricing/math, compare against committed independently generated true-model values within a bound derived before the contract runs from the documented primitive precision contracts.

Generated reference data must identify its generator and regeneration command, include every input needed to reproduce it, and exercise every emitted vector against the production function. A generator may use Python standard-library math or another independent implementation, but it must not import the contract's fixed-point replay or measure tolerance from observed Move output. The pricing generator validates representative profiles against the production input envelope before emission and rejects a propagated acceptance tolerance above 10,000 units at 1e9 scale (0.1 basis point) because a looser vector is not useful to this suite; these vectors prove representative implementation accuracy, not complete production-envelope calibration, a protocol accuracy guarantee, or an economic product limit.

If independently valid truth falls outside its bound, keep the finding visible and follow the RED protocol in `.claude/rules/unit-tests.md`. Do not change the expected value, widen the tolerance, or convert the mismatch into an expected failure.

An exact registered policy function name is a routing obligation, not proof by itself. Assert the observable policy output, including event identity and reason when custody crosses the funds accumulator; if the Move unit-test platform cannot observe the final settled balance or a production branch is unreachable under public admission constraints, retain that semantic gap in `check_predeploy_debt.py` instead of adding a source seam or declaring the policy complete.

## Adding a test

1. Choose the primary claim layer, scope path, and intent token.
2. Identify the production UUT and the minimum state/transaction borrow set it requires.
3. Reuse the World and focused prerequisite modules; keep pure units local.
4. Establish the expected-value oracle independently before running the test.
5. Call the production UUT visibly in the test body and assert the state/output owned by that claim; every successful test contains a direct `assert!` or `assert_eq!` in its own body, while an expected-failure annotation is the oracle for an abort test.
6. Return every shared object, destroy or transfer every owned non-droppable value, and finish the World.
7. Run the scope and intent filters, then the warning-strict build and full Predict suite.

Run `python3 packages/predict/tests/check_architecture.py`, `python3 packages/predict/tests/check_predeploy_debt.py`, `python3 -m unittest discover -s packages/predict/tests -p "*_test.py"`, and `python3 packages/predict/tests/reference/generate_pricing_reference.py --check` before the Move commands. Linux CI pins Python 3.11 for the stale-output check and runs Predict warning-strict. The deterministic structural checks reject executable tests and unapproved new test seams across Predict-cluster production sources and verify the single Scenario owner, ID-based shared retrieval boundary, post-bootstrap transaction progression only in test bodies, at most one World per test, exact executable module taxonomy and category selection, direct positive-test assertions, live generated-data provenance links, and the exact transitional predeploy debt set: missing executable pins, manually reviewed unreachable branches and accumulator-delivery obligations, uncatalogued policies, explicit non-unit exemptions, and stale named paths. The `test_world` bootstrap is the sole transaction-progression exception. The branch remains an intermediate draft until that debt manifest is empty, the wrapper is deleted, and the strict predeploy checker is clean. Structural checks freeze semantic-gap rows but do not prove their meaning.
