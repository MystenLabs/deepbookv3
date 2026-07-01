# Seeded-bug recall harness

The `verify_corpus.json` bench measures **precision** (the panel must not confirm a non-bug). This file
measures **recall** (the panel must confirm a *real* bug it was not told about) — the one property two clean
runs cannot tell you. Each seed is a **content-based** find→replace (not a line-numbered patch, so it survives
drift) against current HEAD. Apply ONE seed in a scratch worktree, run an audit, check the expected finding
surfaces at High/Critical, then revert. **Never commit a seeded tree.**

## How to run a recall check (cheap: `depth:'low'`, one pass per lens)

```bash
git worktree add /tmp/predict-seed HEAD           # isolated tree, never committed
# apply ONE seed's replacement (below) in /tmp/predict-seed
sui move build --path /tmp/predict-seed/packages/predict --warnings-are-errors   # must still compile
# from the MAIN loop, launch the orchestrator against the seeded tree with depth:'low' (full breadth, 1 round)
# then confirm the seed's "expect" finding appears in kept[] at the stated severity.
git worktree remove --force /tmp/predict-seed     # discard the seeded tree
```

A seed the run misses is a **recall hole** — either the lens that owns it isn't digging deep enough or the
verify panel refuted a real bug. Record misses; they are the highest-signal input to the next skill revision.

## Seeds (apply exactly one at a time)

### S1 — R2 rounding flip (LP share over-issuance) · lens 01 invariants · expect High/Critical
- File: `packages/predict/sources/plp/lp_book.move`, `supply_shares`.
- Replace `math::mul_div_down(amount, mark.total_supply, mark.pool_value)`
  with `math::mul_div_up(amount, mark.total_supply, mark.pool_value)`.
- Bug: a supplier now mints ≥ fair shares (rounds UP), diluting incumbent LPs — a ROUNDING_POLICY R2 violation
  (user-facing outflows/shares must round in the protocol's favor). Expect the invariants lens (R2) to flag it.

### S2 — solvency guard dropped (rebate reserve unbacked) · lens 01 / lens 06 · expect High/Critical
- File: `packages/predict/sources/expiry_cash.move`, `assert_backing`.
- Replace `cash.required_cash(payout_liability)` with `payout_liability` (drops the `+ rebate_reserve` term).
- Bug: backing now covers payout but NOT the unresolved rebate reserve, so cash can fall below
  `payout_liability + rebate_reserve` — the exact `cash >= payout_liability + rebate_reserve` invariant this
  module documents. Expect a solvency/assertion finding.

### S3 — removed version gate on a state mutator · lens 04 access-control · expect High
- File: `packages/predict/sources/expiry_market.move`, `assert_live_mint_allowed`.
- Delete the `config.assert_version();` line from that function.
- Bug: mint no longer checks the protocol version, so a disabled/rolled-back version can still create risk —
  a version-gating hole. Expect the access-control lens to flag the missing gate on a risk-creation flow.

### S4 — dead-field / write-only mirror (rule-sweep recall) · rule `dead-field-liveness` · expect High
- File: `packages/predict/sources/plp/pool_accounting.move`.
- In the reader that consumes `pending_protocol_profit` (grep it), replace the field read with a literal `0`
  (e.g. `self.pending_protocol_profit` → `0` at its sole live reader), leaving the writer intact.
- Bug: `pending_protocol_profit` becomes write-only — accrued but never subtracted from LP pricing (the D033
  carry silently stops applying). This is the canonical rebate-reserve bug class the `dead-field-liveness`
  rule sweep exists to catch. Run the **rule-sweep** harness (`rules: ['dead-field-liveness']`) for this one.

> Add a seed whenever a real bug slips past a run — the seed that would have caught it becomes a permanent
> recall guard. Keep the catalog small and each seed a single, compiling, obviously-wrong change.
