# Predict Unit-Test Framework — Execution Report (session: predict-test-fw2)

_Branch `predict-test-fw2`, worktree `/tmp/predict-test-fw2`, base
`strike-exposure-rewrite-state @ 2e6aee27` (settlement landed). The base advanced
past the prompt's stated `3938747b`: `ede889f4` + `2e6aee27` added the settlement
rewrite. Baseline verified **270/270 green** at start. Final suite **295/295
green**. Nothing merged to the shared branch yet._

---

## ⚠️ CRITICAL / ECONOMIC FINDINGS FIRST

**No critical/solvency RED bug found.** The freshly-changed economic surfaces are
well-guarded; every independently-derived expected value matched the contract.

The one genuine **candidate concern** (not reproduced as a RED, see
`BUGS_FOUND.md` C-1): **`plp::withdraw` aborts `EZeroWithdraw` (plp.move:428)
before the in-kind SUI/DEEP incentive claim (plp.move:404-405)** — a collapsed-NAV
holder whose DUSDC payout rounds to 0 cannot exit to claim their incentives, which
contradicts the "incentives paid in-kind, no oracle" intent. Medium severity /
medium confidence; needs a vault-collapse repro + a product decision. Surfaced for
eng review.

---

## What was delivered

### PART 1 — framework scalability layer (GREEN, MERGEABLE) — commit `1c93f70a`
Built on the merged foundation (did not rebuild):
- `test_constants.move` — promoted the market/price/strike/supply consts hardcoded
  in `flow_test_helpers` into named getters (single source of truth); `float()` /
  `dusdc_unit()` aliased from the `constants::` macros (Rule 7).
- `flow_test_helpers.move` — parameterized `setup_market(spot,tick,supply)` +
  `setup_market_default()` (+ `setup_pool_with_pyth` back-compat alias);
  `setup_everything()` composite (funded pool past create_expiry + prepare_oracle +
  sync + funded manager); `ExpectedManagerState` + `check_manager` (the deepbook
  `ExpectedBalances` analog); `create_funded_manager_for(owner,..)` (second-manager
  builder); `create_active_expiry(..)` (second-expiry builder).
- `test_helpers.move` — `return_shared_2!/3!/4!` macros.
- `oracle_fixture.move` — minimal production-valid oracle/pyth bring-up on an
  UNFUNDED pool (no `plp::supply`) for market_oracle + pricing error paths; exposes
  the `MarketOracleCap` for direct guard-triggering.
- `framework_smoke_tests.move` — smoke flow (`setup_everything` + `check_manager` +
  `return_market`) and an `oracle_fixture` pricing smoke. Both green.

### PART 2 — bug-finding pass (all GREEN — independently confirms correctness)
25 new tests across the fresh/hot surface; expected values all independently derived.

| Surface | Tests | Commit | Result |
|---|---|---|---|
| `order` packing (was 0 coverage) | 13 | `…order packing + gates` | exact u256 layout vs independent Python pack; all 7 guards; **packing correct** |
| `expiry_market` 7 gates | 4 | same | mint-after-expiry, settled partial close, live `redeem_settled`, wrong oracle — **all gates fire** |
| `pricing` (was 0 coverage) | 3 | `…pricing invariants` | exact budget-free invariants: complementarity, whole-line=1, monotonicity — **consistent** |
| settlement averaging | 1 | same | 30 equal samples → exact value (shuffle-independent) — **correct** |
| `conservative_active_nav` boundaries | 2 | `…haircut-floor` | Q≥nav floors at 0 (sat_sub) — **no underflow** |
| framework smoke | 2 | `1c93f70a` | plumbing |

## Mergeable vs parked-red

- **Everything is mergeable (all green).** There are **0 RED tests** to park. The
  entire `predict-test-fw2` branch is green and can fast-forward into
  `strike-exposure-rewrite-state` as-is. (Were there reds, they would stay on this
  branch + the ledger per the merge model.)

## Coverage delta

- 270 → 295 tests (+25). New surfaces brought from **zero coverage**: `order`
  packing (+13), `pricing` (+3 structural invariants). New error-path coverage:
  4 `expiry_market` gates, all 7 `order` aborts. Plus settlement-averaging and
  NAV-haircut boundary coverage.

## Manifest reconciliation ✅

`KNOWN-FAILING` tags (0) == ledger RED entries (0) == actual failures (0).
295/295 pass. No regressions, no orphan ledger entries.

## Guardrails honored

- **Cardinal:** every expected value independently derived (hand math / documented
  u256 layout / structural invariant / hand-derived NAV formula); none adjusted to
  pass; no contract change; no buggy behavior asserted as `expected_failure`.
- **The hard guardrail (compile/run/classify in the MAIN loop only):** every
  `sui move build`/`test` and every pass/fail + bug-vs-test-error classification was
  run in the main loop. Subagents only drafted/analyzed.
- Branch hygiene: all commits on `predict-test-fw2`; nothing merged to the shared
  branch; main's primary tree untouched.

## Infrastructure note (important for future sessions)

Two Workflow/subagent failures shaped this run — **do the bug-finding analysis in
the main loop for this repo:**
1. **Non-isolated workflow agents corrupted the worktree:** one analysis agent ran
   `git reset` and another wrote a file directly into the shared worktree, wiping
   uncommitted PART-1 edits. Mitigation that worked: commit early/often; killed the
   workflow.
2. **`isolation: 'worktree'` agents analyzed STALE code:** the isolated worktrees
   resolved to an *older* revision (a `leverage_rank` `order.move`, a
   `valid_settlement_spot_source` settle path, a pre-`conservative_active_nav`
   `plp`) that does **not** match HEAD. Every finding had to be re-verified against
   the real source; most were inapplicable. Net: subagent analysis was unreliable
   here; the main-loop hand analysis (which the cardinal rule requires anyway) was
   the source of all verified results.

## Honest assessment of the green outcome

A first-write all-green suite is normally suspect (unit-tests Rule). Here the green
is **earned, not circular**: the order exact-pack asserts an independently-computed
u256 (would catch any field overlap/offset bug); the pricing complement is an exact
algebraic invariant (would catch range asymmetry); the equal-sample settlement test
is shuffle-independent (would catch an averaging/`/k` bug); the NAV tests are
hand-derived from the documented formula; the gate tests fail-to-abort if a gate
silently stops firing. They pass because the fresh code is correct. The candidate
concern C-1 is the residual lead worth an eng decision.
