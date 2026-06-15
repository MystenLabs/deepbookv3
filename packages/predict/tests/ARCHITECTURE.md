# Predict Test Framework — Architecture

> The reusable layering that makes a new flow- or error-path test a few lines, not a bespoke
> setup. Modeled on deepbook core's test framework and improving on it where core is weak.
> Authoritative for `packages/predict/tests/**` and `packages/fixed_math/tests/**`.
> Companion: `.claude/rules/unit-tests.md` (the 18 cardinal rules). The build-out
> worklists (coverage matrix, bug ledger, reachability recipes) were consumed and
> deleted when the suite reached full error-constant coverage; create a fresh
> `.redesign/BUGS_FOUND.md` ledger if a future bug-finding pass needs one.

## Ground truth

- Predict suite is **278/278 green** on the pruned funding/NAV branch with the runnable
  subset restored. Tests for removed sync supply/withdraw, pool NAV, incentives,
  compaction, per-expiry funding, and old rebate-claim surfaces were deleted with those
  APIs.
- Two packages: `packages/predict` (`deepbook_predict::*`) and `packages/fixed_math`
  (`fixed_math::{math,i64}` — extracted from predict; predict depends on it).

## Hard constraints

- Avoid source edits for tests. Minimal `#[test_only]` source seams are allowed only when a
  production object has no other valid local-test lifecycle path, such as explicit expiry
  cash seeding while pool funding is absent.
- On finding a bug: leave the test RED, ledger it in `.redesign/BUGS_FOUND.md`
  (create it if absent), tag `// KNOWN-FAILING: BUG-NNN`. Never adjust expecteds,
  never re-express as `expected_failure` of buggy behavior, never touch source.

## Layered design (largely BUILT — extend, don't restart)

```
Layer 0  test_constants.move      — single source of truth: addresses + every named market/
                                     oracle/price/strike/supply/SVI literal. No magic numbers
                                     anywhere else (rules 7/8).
Layer 1  test_helpers.move        — domain-free leaf utils: destroy_2/3/4 macros, setup_test /
                                     begin_registry_test / finish_registry_test registry base,
                                     and the rule-10 math carve-out assert_within /
                                     assert_within_relative (principled bounds only).
Layer 2  oracle_fixture.move      — lightweight production-valid registry+config+cap+
                                     Propbook PythFeed+BlockScholesFeed+ExpiryMarket bring-up
                                     for pricing/oracle error paths that don't need a funded
                                     market. Pyth uses the irreducible
                                     pyth_feed::record_raw_for_testing seam; BS uses the
                                     stub verifier's public update constructor.
                                     take_oracle/return_oracle pairing includes OracleRegistry.
         flow_test_helpers.move   — the tradeable market Fixture: production create path plus
                                     explicit test-only expiry cash seeding while pool funding is
                                     absent; parameterized setup_market(tick) +
                                     setup_market_default(); lifecycle advancers (create_expiry /
                                     prepare_live_oracle); composites
                                     (setup_live_market, setup_everything → past create+live+
                                     seeded-cash+funded-manager); flow wrappers (mint / redeem /
                                     redeem_settled / liquidation); take_market +
                                     return_market (per-method, non-nested take/return);
                                     ExpectedManagerState + check_manager state sheet.
Layer 3  invariants               — invariant-level one-call assertions (rule 17), added to
                                     flow_test_helpers: expiry cash backing and manager state
                                     sheets. Reads production getters, compares to independently-
                                     tracked expectations.
Layer 4  reference/               — committed generators + reference data, NOT in CI path:
                                     tests/helper/reference/generate_constants.py →
                                     math_reference.csv (fixed_math), and
                                     generate_pricing_reference.py →
                                     tests/pricing/pricing_reference_data.move (predict).
                                     Executable independence (rule 16).
```

### File tree (mirrors `sources/` domains; per-domain, never mega-files)

```
packages/predict/tests/
  helper/    test_constants · test_helpers · oracle_fixture · flow_test_helpers · reference/
  config/    one *_tests.move per config module
  pricing/   pricing_tests · pricing_exact_tests · pricing_reference_data (generated)
  pool/      pruned with synchronous funding/NAV/incentive tests; add fresh files when new LP APIs land
  order/     order_tests
  strike_exposure/  strike_grid · strike_payout_tree · c1 flow · liquidation_book · guard tests
  flows/     framework_smoke · lifecycle · expiry_market_gate (+ invariant passes NEW)
  (root)     predict_manager_tests · registry_create_tests · expiry_cash_tests · ewma_tests
packages/fixed_math/tests/
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
  (`check_manager`, expiry-cash sheets).
- **`assert_eq!` exact** everywhere math is exact; `assert_within`/`assert_within_relative`
  **only** for fundamental fixed-point error with a principled/documented bound — never a bound
  measured from contract output (rule 10).
- **Production-valid fixtures** (rule 12): markets/oracles always through real
  `register_underlying`, Propbook feed creation/binding, and `create_expiry_market`;
  config nudges through real admin setters; the only state seam is the irreducible
  Pyth raw-update one.

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

## Near-term additions

1. **Funding rebuild tests**: replace temporary explicit cash seeding with production-valid
   pool funding flows once those APIs return.
2. **Lifecycle advancers** beyond settle: pause/version-disable toggles, second-expiry +
   second-manager builders and leveraged-order builders — added as coverage work demands them
   (no speculative helpers).
3. **Pyth edge-case fixture support** in `oracle_fixture` and Propbook tests
   (stale/future/zero-normalized spot behavior through `update` where reachable,
   else the documented `pyth_feed::record_raw_for_testing` seam).

## Provenance warnings

- The redesign-exploration repo's `.move` test files target stale source — never import them.
