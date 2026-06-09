# Predict Test Framework — Architecture

> The reusable layering that makes a new flow- or error-path test a few lines, not a bespoke
> setup. Modeled on deepbook core's test framework and improving on it where core is weak.
> Authoritative for `packages/predict/tests/**` and `packages/predict_math/tests/**`.
> Companions: `.redesign/COVERAGE_MATRIX.md` (worklist), `.redesign/BUGS_FOUND.md` (ledger),
> `.redesign/REACHABILITY.md` (stale-source trigger hypotheses — re-verify before use),
> `.claude/rules/unit-tests.md` (the 18 cardinal rules).

## Ground truth (verified against HEAD `b10a37d7`, branch `strike-exposure-rewrite-state`)

- Suite is **316/316 green** (`predict` 212, `predict_math` 104), **0 `assert_approx`**,
  **0 `KNOWN-FAILING`**, ledger empty — consistent.
- Error-constant coverage: **60/157** (module-qualified; 148 unique names). 97 uncovered
  (P0 4, P1 56, P2 14, P3 23). **47 are regressions vs `main`** (granular test files deleted
  during suite consolidation); the rest were never covered.
- Two packages: `packages/predict` (`deepbook_predict::*`) and `packages/predict_math`
  (`predict_math::{math,i64}` — extracted from predict; predict depends on it).

## Hard constraints

- **No edits under `packages/predict/sources/**` or `packages/predict_math/sources/**`.**
  Only the existing `registry::init_for_testing`, `plp::init_for_testing`,
  `pyth_source::set_state_for_testing`, and `market_oracle::settle_with_generator_for_testing`
  seams are sanctioned (rule 18). No new `*_for_testing` source seams.
- On finding a bug: leave the test RED, ledger it in `BUGS_FOUND.md`, tag
  `// KNOWN-FAILING: BUG-NNN`. Never adjust expecteds, never re-express as
  `expected_failure` of buggy behavior, never touch source.

## Layered design (largely BUILT — extend, don't restart)

```
Layer 0  test_constants.move      — single source of truth: addresses + every named market/
                                     oracle/price/strike/supply/SVI literal. No magic numbers
                                     anywhere else (rules 7/8).
Layer 1  test_helpers.move        — domain-free leaf utils: destroy_2/3/4 macros, setup_test /
                                     begin_registry_test / finish_registry_test registry base,
                                     and the rule-10 math carve-out assert_within /
                                     assert_within_relative (principled bounds only).
Layer 2  oracle_fixture.move      — lightweight production-valid registry+config+cap+PythSource+
                                     MarketOracle bring-up for oracle/pricing/pyth error paths
                                     that don't need a funded market. Sanctioned home of
                                     set_state_for_testing. take_oracle/return_oracle pairing.
         flow_test_helpers.move   — the full PLP-funded tradeable market Fixture:
                                     parameterized setup_market(spot, tick, supply) +
                                     setup_market_default(); lifecycle advancers (create_expiry /
                                     prepare_live_oracle / sync_expiry / settle_oracle);
                                     composites (setup_live_market, setup_everything → past
                                     create+live+sync+funded-manager); flow wrappers (mint /
                                     redeem / redeem_settled / supply / withdraw); take_market +
                                     return_market (per-method, non-nested take/return);
                                     ExpectedManagerState + check_manager state sheet.
Layer 3  invariants (Phase 1 ADD) — invariant-level one-call assertions (rule 17), added to
                                     flow_test_helpers: solvency (cash backing ≥ liabilities),
                                     accounting conservation (shares↔value↔reserves), NAV
                                     directional (supply_NAV ≥ TRUE ≥ withdraw_NAV ordering),
                                     pool/vault state sheets. Reads production getters, compares
                                     to independently-tracked expectations.
Layer 4  reference/               — committed generators + reference data, NOT in CI path:
                                     tests/helper/reference/generate_constants.py →
                                     math_reference.csv (predict_math), and
                                     generate_pricing_reference.py →
                                     tests/pricing/pricing_reference_data.move (predict).
                                     Executable independence (rule 16).
```

### File tree (mirrors `sources/` domains; per-domain, never mega-files)

```
packages/predict/tests/
  helper/    test_constants · test_helpers · oracle_fixture · flow_test_helpers · reference/
  config/    one *_tests.move per config module
  oracle/    market_oracle_tests · market_oracle_settlement_tests (+ pyth_source_tests NEW)
  pricing/   pricing_tests · pricing_exact_tests · pricing_reference_data (generated)
  pool/      plp_tests · plp_nav_haircut_tests · pool_accounting_tests (+ incentive_tests NEW)
  order/     order_tests
  strike_exposure/  strike_grid · strike_payout_tree · c1 flow (+ liquidation_book,
             strike_nav_matrix, strike_exposure guard tests NEW)
  flows/     framework_smoke · lifecycle · expiry_market_gate (+ invariant passes NEW)
  (root)     predict_manager_tests · registry_create_tests · expiry_cash_tests · ewma_tests
packages/predict_math/tests/
  helper/    test_helpers (assert_within twins)
  math/      math_tests · i64_tests
```

## Idioms (load-bearing)

- **Error matrix = worker + thin dispatcher.** Where several aborts share one bring-up, write
  one parameterized worker fun and one-liner
  `#[test, expected_failure(abort_code = module::ECode)]` dispatchers. Trailing guard is
  `abort 999` (distinct from every expected code). No `test_` prefix.
- **Per-method, non-nested take/return** of shared objects by captured ID
  (`take_shared_by_id`, `take_market`/`return_market`). Never hold `Registry`/`ProtocolConfig`
  across a `next_tx`; never nest takes of the same object.
- **State-sheet assertions** over scattered `assert_eq!`s for multi-field state
  (`check_manager`; pool/vault analogs in Phase 1).
- **`assert_eq!` exact** everywhere math is exact; `assert_within`/`assert_within_relative`
  **only** for fundamental fixed-point error with a principled/documented bound — never a bound
  measured from contract output (rule 10).
- **Production-valid fixtures** (rule 12): markets/oracles always through real
  `create_expiry_market`/`create_pyth_source`; config nudges through real admin setters; the
  only state seam is the irreducible Pyth one.

## Bug-finding discipline (inverted TDD — non-negotiable)

Derive every expected value **independently** (hand math with work shown / committed generator
output / spec) → assert against the **existing** contract → if it fails, it found a candidate
bug: ledger + tag + leave RED. `#KNOWN-FAILING tags == #BUG-NNN entries == #failing tests`
(manifest check). A non-green suite is an intended deliverable; a green-on-first-write suite
is suspect.

## Improvements over deepbook core

| Dimension | Core | Predict framework |
|---|---|---|
| Fixtures | permissive `new_for_testing` constructors | production-valid `init_for_testing` + real create flows |
| Reference data | asserts contract's own snapshot (change-detector) | independent committed scipy/mpmath generators (executable independence) |
| Assertions | balance equality | invariant-level (solvency / conservation / NAV-directional), one call |
| Shared objects | ambient `take_shared` | `take_shared_by_id` + ID-as-handle, per-method non-nested take/return |
| File shape | 10k-line mega-files, setup interleaved with tests | per-domain tree + centralized `helper/` |
| Bug stance | green = done | RED + ledger; green-on-first-write is suspect |

## Phase 1 additions (this effort)

1. **Pool/vault invariant layer** in `flow_test_helpers`: `assert_cash_backing`-style one-call
   checks against independently-tracked expectations; `ExpectedPoolState`/`check_pool` analog
   of `check_manager` where getters exist.
2. **Lifecycle advancers** beyond settle: pause/version-disable toggles, second-expiry +
   second-manager builders, incentive funding, leveraged-order builders — added as coverage
   work demands them (no speculative helpers).
3. **`pyth_source` error-path fixture support** in `oracle_fixture` (stale/future/zero-spot
   update guards via the real `update_from_lazer` path where reachable, else documented).

## Provenance warnings

- `.redesign/REACHABILITY.md` was authored against the **divergent predict-track1 branch**
  (no predict_math, different module layout, 155 different constants). Every recipe is an
  UNVERIFIED HYPOTHESIS: re-check each cited file:line against HEAD before encoding a test.
- The redesign repo's `.move` test files target stale source — never import them.
