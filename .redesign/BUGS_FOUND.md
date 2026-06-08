# Predict Bug Ledger (framework bug-finding pass)

> **Status: 2 candidate findings surfaced (BUG-001 exp, BUG-002 ln); both RESOLVED
> as in-spec under the now-documented precision budget. 0 active RED.** This is the
> deliverable ledger for the unit-test framework effort (see
> `.redesign/UNIT_TEST_FRAMEWORK_PLAN.md`).
>
> Each entry is a discrepancy between an **independently-derived** expected value and the
> contract's **actual** behavior, found by a test left **RED**. An entry is later marked
> **RESOLVED** only when (a) the contract is fixed, or (b) the deviation is shown to be
> within a principled, downstream-derived precision budget documented in source — never by
> adjusting an expected value to match output. Active-RED entries map 1:1 to
> `// KNOWN-FAILING: BUG-NNN` tags in the test tree and to the suite's failing-test count.
>
> **Cardinal rule:** never adjust an expected value to make a test pass, and never assert the
> buggy behavior as `expected_failure`. A failing test found a bug — leave it failing, record
> it here.

## Reconciliation

- Active-RED tags in tree: `grep -rho 'KNOWN-FAILING: BUG-[0-9]\+' packages/predict/tests | sort -u`
- Active-RED ledger entries: ledger `BUG-NNN` headings **not** marked `RESOLVED`.
- The two lists **must match**, and the count **must equal** the suite's failing-test count.
- **Current state:** 0 active-RED tags in tree, 0 failing tests (257/257 pass), 0 active-RED
  ledger entries (BUG-001/002 both RESOLVED; BUG-003 FIXED; R1 FIXED — see DEFERRED). Reconciled.

## Special status: DEFERRED (out of scope — do not treat as fresh findings)

- **R1 / `plp.move` (`synced_pool_value` unguarded subtraction underflow)** — **FIXED (2026-06-07).** Extracted the pure `plp::lp_pool_value(idle, credits, debits, share, active)` and floored LP value at 0 with `exclusion.min(gross_pool_value)`, so the protocol-profit exclusion can no longer exceed gross and underflow-brick PLP supply/withdraw. Tests: `plp_tests::lp_pool_value_*` (RED→GREEN; `lp_pool_value_floors_at_zero_when_exclusion_exceeds_gross` reproduces the documented withdraw-against-collapsing-mark scenario, credits=900/debits=800/share=50% → 0). The `.min` clamp is the safe backstop; the complementary withdrawal floor (`idle >= share*(credits-debits)`) / conservative-NAV marking (C3) remain follow-ups. Still overlaps C3.
- **C3 (`strike_nav_matrix::live_value` aggregate-floor precondition)** — product decision; separate effort.

If a P0-3 (PLP sync NAV) test naturally hits either, ledger it under this section as `DEFERRED`, not as a new BUG-NNN.

---

<!-- Entries begin here. Template per the plan:

## BUG-NNN — <one-line title>
- **Test:** `<module>::<fn>` (`packages/predict/tests/<path>:<line>`)
- **Inputs:** <exact inputs>
- **Expected (independent):** <value + how derived: hand math / scipy fixture / spec>
- **Actual (contract):** <value>
- **Suspected root cause:** <file:line + reasoning>
- **Class:** economic | liveness | correctness | rounding
- **Severity:** critical | high | medium | low
- **Status:** RED (known-failing)

-->

> **Precision-spec gap — RESOLVED.** The gap (`math.move` documented no error
> bound or rounding convention for `ln`/`exp`/`normal_cdf`/`sqrt`) is now closed:
> a **precision contract** is documented in `math.move` (module doc, `# Precision
> contract`) and encoded as named budget constants in `math_tests.move`. The
> budgets are derived from **downstream pricing sensitivity** (`pricing.move`:
> `up_price = Φ(d2)`, with `ln`/`sqrt` feeding `d2`), NOT from contract output:
> exp/ln **≤ 1e-7 relative**, normal_cdf **≤ 2e-8 absolute (20u@1e9)**, sqrt
> **≤ 1 ULP**. The tests now assert the contract within those budgets via
> `assert_within_relative` (exp/ln) / `assert_within` (cdf/sqrt) against the
> independent reference (`tests/helper/reference/generate_constants.py`). The
> deliberately-strict 1-ULP pass (revision C) had surfaced BUG-001/002 as candidate
> findings; under the documented budget both are **in-spec** (see below).

## BUG-001 — `exp()` approximation error — RESOLVED (in-spec under documented budget)
- **Tests (now GREEN):** `math_tests::exp_of_one_within_reference`, `exp_of_two_within_reference`, `exp_of_ten_within_reference` (`packages/predict/tests/math/math_tests.move`)
- **Inputs / Expected (independent, round(eˣ·1e9) via stdlib `math`) / Actual (contract) / relative error:**
  - `exp(1)`: expected `2_718_281_828`, actual `2_718_281_820` → **−8** units = **rel −2.9e-9**
  - `exp(2)`: expected `7_389_056_099`, actual `7_389_056_092` → **−7** units = **rel −0.95e-9**
  - `exp(10)`: expected `22_026_465_794_807`, actual `22_026_465_902_592` → **+107_785** units = **rel +4.9e-9**
- **Ledger correction:** the prior entry reported `exp(10)` as `rel ~4.9e-6` — a **1000× arithmetic slip** (107_785 / 2.2026e13 = **4.9e-9**, not 4.9e-6; the divide treated e¹⁰·1e9 ≈ 2.2e10 instead of 2.2e13). Corrected, `exp` is uniformly accurate to **≤ 5e-9 relative** across all points; the +107k absolute at `exp(10)` is just 4.9e-9 of a 2.2e13 magnitude, the *same* relative accuracy as `exp(1)`. `exp_of_ten` passing the 1e-7-relative test (tolerance ≈ 2.2e6 units) empirically confirms this.
- **Bias:** sign-varying (`exp(1)/exp(2)` low, `exp(10)` high), magnitude ~1e-9 — NOT "always high" as the prior entry stated. No systematic tilt against the pool.
- **Usage:** `exp` is invoked **only** internally by `normal_cdf` (the `exp(-x²/2)` tail factor) at moderate negative args where its relative error is ~1e-9; the large-positive (`exp(10)`) path is unused on the pricing path.
- **Resolution:** the −8/−7/+107_785 deltas are well inside the documented **≤ 1e-7 relative** budget (math.move "Precision contract"). The strict 1-ULP test failed only because 1 absolute unit on a 2.2e13 value demands ~4.5e-14 relative — not an attainable or needed precision. In-spec; no contract change.

## BUG-002 — `ln()` approximation error — RESOLVED (in-spec under documented budget)
- **Test (now GREEN):** `math_tests::ln_of_ten_within_reference` (`packages/predict/tests/math/math_tests.move`)
- **Input / Expected / Actual:** `ln(10)`: expected `2_302_585_093` (round(ln(10)·1e9)), actual `2_302_585_090` → **−3** units = **rel −1.3e-9**. (`ln(2)` within 1 unit, rel ≤1.4e-9.)
- **Bias:** low at `ln(10)`; magnitude ~1e-9. `ln` enters pricing as `k = ln(strike/forward)`, attenuated by `φ(d2) ≤ 0.399`, and its error is largest at deep-OTM strikes where `φ(d2) → 0` — so the quote impact is sub-ULP everywhere.
- **Resolution:** −3 units = rel 1.3e-9, ~80× inside the documented **≤ 1e-7 relative** budget. In-spec; no contract change.

## BUG-003 — `exp()` silently overflows for large positive inputs (Move `<<` wraps, not aborts) — FIXED
- **Found by:** code inspection during the precision review (not a RED test), confirmed with a throwaway probe: `(2¹²⁸−1) << 1 == max − 1`, i.e. Move's `<<` **truncates/wraps silently** and only aborts when the shift *amount* ≥ bit width, never on value overflow.
- **Defect:** `math::exp` / `exp_u128` (`sources/math/math.move`) positive path computes `result << n`. For `x ≳ 67` the u128 `<<` silently drops high bits, so `exp` could return a **wrapped garbage value** through the final `as u64` cast. For `23.638 < x < 67` the true result exceeds `u64::MAX` and the cast aborts, but with no named error code.
- **Reachability:** `exp`'s only protocol caller is `normal_cdf` (negative args, right-shift path), so the bad path was **unreached in production** — but `exp` is public API surface, so a future caller/composer could hit it.
- **Class:** correctness (silent wrong result) — latent. **Severity:** low (unreached by protocol; public-API hardening).
- **Status:** **FIXED.** Added `EExpOverflow` guard `assert!(x_negative || x_mag <= EXP_MAX_INPUT, EExpOverflow)`. Negative path unaffected (`e^-x < 1`). Distinct from BUG-001/002 (those are in-spec precision; this is a real correctness footgun, now closed).
- **Refinement (edge-test audit):** the boundary test `exp_at_u64_fit_bound_returns_within_reference` initially RED'd — `EXP_MAX_INPUT` was first set to the exact *math* bound `23_638_153_718` (`floor((64·ln2 − 9·ln10)·1e9)`, where *true* `e^x·1e9 ≤ u64::MAX`), but the impl runs slightly high there, so its computed value overflowed the `as u64` cast (raw arithmetic abort at `math.move:137`) instead of the named guard, for a ~100-unit window of inputs. Tightened `EXP_MAX_INPUT` to the **budget-conservative** bound `23_638_153_618` (largest `x` with `e^x·1e9·(1+1e-7) ≤ u64::MAX`), so every admitted input is guaranteed to fit `u64` even at the precision ceiling and the named `EExpOverflow` always fires first. Tests now pin all three boundary cases (returns at bound; named-aborts at bound+1; named-aborts well past).
