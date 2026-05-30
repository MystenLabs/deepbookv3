# Predict Gas Experiments

Log of gas/performance experiments on the Predict Move contracts, measured with
`run.sh`. Counterpart to `ANALYSIS_NOTES.md` (economics).

**Check this doc before running a gas experiment** (avoid repeating dead ends).
When you analyze one, ask the user **"should I add this to the experiments doc?"**
Keep entries to ~5 lines; keep the whole doc tight.

## Method & caveats

- Gas = `computationCost` (storage is mostly rebated). Read per-action averages
  from `runs/<run>/artifacts/local_trace.json`.
- **Runs are NOT a controlled A/B:** each `run.sh` generates a different scenario
  (check `md5 runs/<run>/artifacts/normal_scenario.csv`). Action counts match but
  price paths, order mix, and liquidations differ.
- **Noise tell:** if an action whose code path you did *not* touch (e.g.
  `supply`/`withdraw` when you changed a mint/redeem path) moves a few %, that's the
  noise floor — treat smaller deltas as neutral. For a real signal, pin the scenario
  (same CSV pre/post).

## Cost map

Per liquidation, three structures mutate: **nav matrix > payout tree > liquidation
book**. The marginal cost of extending a scan is per-candidate pricing
(`compute_range_price` ≈ 2 SVI evals), not the index structures.

## Log

### 2026-05-30 · payout tree: store local boundary terms · KEEP (readability)
Branch `at/predict-min-size`. Store `local_start/end` on `PayoutNode` instead of
deriving from child summaries; collapse writers into `resummarize`; delete 4 fns.
Baseline `may30-1302` → `may30-1331`: mint −2.7%, redeem −2.3% — but supply/withdraw
also −4–8% on an untouched path, so **within noise → gas-neutral**. Kept for simpler
rotations (446 tests pass). TODO: pinned-scenario A/B to confirm.

### 2026-05-30 · curve pricing for short trade scan · REVERTED
Price scan candidates via the prebuilt 50-pt curve instead of per-candidate
`compute_range_price`. At the default budget (24 ≈ break-even) the curve build +
binary search cost more than exact pricing; the curve only wins well past
break-even, and the short scan is below it.

### 2026-05-30 · nav matrix `page_totals` as cross-page prefix · NOT PURSUED
Valuation already loads only curve-boundary pages (middle pages use the inline
`page_totals`); within-tx child caching means cost scales with distinct boundary
pages. The prefix change loads the same pages and adds mint cost. Real lever is
`curve_samples`, not the page-total representation.
