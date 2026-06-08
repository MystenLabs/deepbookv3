# Predict Bug Ledger — framework bug-finding pass (session: predict-test-fw2)

> **Status: 0 active RED.** This session completed the test-framework scalability
> layer (PART 1, green/mergeable) and ran an inverted-TDD bug-finding pass (PART 2)
> over the freshly-changed + hot surface (settlement, strike_exposure, plp NAV,
> expiry_market gates, order packing, pricing). Every independent expected value
> derived matched the contract: the fresh/hot code examined is **well-guarded**
> (saturating subtractions, monotone-floor ordering, gates firing). No confirmed
> economic RED was produced. One genuine **candidate concern** (C-1, plp incentive
> exit) is documented below — investigated, plausibly real, but NOT reproduced as a
> clean failing unit test, so it is **not** ledgered as a BUG-NNN RED.
>
> **Cardinal rule (honored):** no expected value was adjusted to pass; no contract
> code was changed; no buggy behavior was asserted as `expected_failure`. Every
> green test below asserts an INDEPENDENTLY-derived value (hand math / documented
> layout / structural invariant), not the contract's own output — so green means
> "independently confirmed correct," not "rubber-stamped."

## Reconciliation (manifest)

- Active-RED `// KNOWN-FAILING: BUG-NNN` tags in tree: **0**
  (`grep -rho 'KNOWN-FAILING: BUG-[0-9]\+' packages/predict/tests | sort -u` → empty)
- Active-RED ledger entries: **0**
- Suite failing-test count: **0** (295 / 295 pass)
- The three lists match. Reconciled.

## Prior-session resolved items — NOT re-flagged

- math `exp`/`ln` precision (BUG-001/002) — in-spec under the documented ≤1e-7
  relative budget. `EExpOverflow` guard added (BUG-003). Untouched.
- R1 `plp::lp_pool_value` underflow — FIXED via `exclusion.min(gross)`; re-confirmed
  by the existing `lp_pool_value_*` tests, unchanged here.
- C3 `strike_nav_matrix` aggregate-floor — product decision, out of scope.

---

## Candidate concerns (investigated; NOT confirmed REDs)

### C-1 — `plp::withdraw` aborts `EZeroWithdraw` before the in-kind incentive claim, so a collapsed-NAV holder cannot exit to claim SUI/DEEP incentives
- **Where:** `plp.move:428` (`dusdc_for_withdraw` asserts `withdraw_amount > 0`,
  `EZeroWithdraw`) runs **before** the SUI/DEEP incentive claim at `plp.move:404-405`.
- **Independent reasoning:** the `withdraw` doc states incentives are "paid in-kind
  below from their live released balances (no oracle)" — i.e. claimable
  independently of the DUSDC NAV. But when the DUSDC payout rounds to 0
  (`withdraw_amount = mul(dusdc_value, div(lp_amount, total_supply)) == 0`, reachable
  when NAV-per-share < 1 raw unit after a NAV collapse, or for a dust share), the
  guard aborts the **entire** withdraw — including the incentive payout. A holder
  with a real incentive entitlement but a zero DUSDC payout is then blocked, and the
  incentives have no other claim path. Contradicts the plan's L4 ("a stale/zero feed
  cannot block an exit").
- **Class:** liveness. **Severity:** medium (edge-state). **Confidence:** medium.
- **Why not a RED here:** a clean focused repro needs the pool driven to
  per-share `dusdc_value` < 1 with a vested incentive present — i.e. a multi-step
  NAV collapse through the expiry mechanics, not a one-call unit test. Not
  fabricated as a RED under the cardinal rule. **Action:** product/eng decision —
  either move the `EZeroWithdraw` guard to reject only `lp_amount == 0` (already
  checked at `plp.move:391`) and allow an incentive-only / zero-DUSDC exit, or
  document that a zero-DUSDC withdraw is intentionally rejected. A vault-collapse
  integration test should accompany any fix.

### Settlement "not anchored to expiry" — RULED OUT for this code
- A worktree-isolated analysis agent (running against a STALE code revision that had
  a `valid_settlement_spot_source` latch and no `settlement_state.move`) flagged that
  settlement could latch the *latest* post-expiry spot, arbitrarily far past expiry.
- **Verified against HEAD:** does **not** apply. The current `settlement_state.move`
  latches the **first** fresh post-expiry observation
  (`record_post_expiry_candidate` sets `first_post_expiry` once, returns if already
  set — `settlement_state.move:227`); otherwise it uses the pre-expiry
  `[expiry-60s, expiry)` sample window. Settlement IS anchored to maturity. No bug.

### strike_exposure partial-close "1-ulp inversion" — RULED OUT for this code
- The same stale-code agent flagged `EInvalidPayoutTerms` when
  `terminal_payout = live_backing_payout + 1` from round-UP at different indices.
- **Verified against HEAD:** does **not** apply. `live_index_terms`
  (`strike_exposure.move:627-632`) uses `math::mul` (round-DOWN) for both
  `terminal_floor` and `floor_amount_at_open`. Since `terminal_floor_index >=
  index_at_open` and `floor()` is monotone, `terminal_floor >= floor_amount_at_open`
  always ⟹ `terminal_payout <= live_backing_payout` always. No inversion possible.

### `conservative_active_nav` haircut underflow — RULED OUT (already guarded)
- Hypothesis: `nav_optimistic - Q` underflows when the haircut `Q` exceeds the
  optimistic NAV. **Verified:** the function uses `sat_sub` end-to-end
  (`plp.move:677-680`), so it floors at 0. New boundary tests
  (`conservative_active_nav_haircut_{exceeding,equal_to}_optimistic*`) confirm this.

---

<!-- BUG-NNN entries would go here, each tagged `// KNOWN-FAILING: BUG-NNN` in tree.
     None this session. Template:

## BUG-NNN — <title>
- **Test:** `<module>::<fn>` (`packages/predict/tests/<path>:<line>`)
- **Inputs:** <exact>
- **Expected (independent):** <value + derivation>
- **Actual (contract):** <value>
- **Suspected root cause:** <file:line>
- **Class / Severity / Status:** … / … / RED (known-failing)
-->
