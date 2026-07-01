# Audit harness evals (self-validation)

Not unit tests for the protocol — these are **expectations the harness itself must meet**, so a full run can be
spot-checked and the skill doesn't silently rot as the code and the settled-decision ledger evolve. Run a full
audit, then check these by hand.

## A. Must re-discover (known-open / recently-found)
A run over the current tree should surface these (or note they were fixed). Update as they're resolved.
- **Cadence hard-abort** — `next_deployable_market` aborts (not skips) on an occupied non-overlap slot when
  cadences are enabled out of rank order (lens 04/07). Medium.
- ~~**`window_size` overflow**~~ — RESOLVED: `assert_cadence_window_size` now caps it at `max_cadence_window_size!()=10` (config_constants.move:188-191, called from market_manager.move). Kept as a closed-item record; a run should NOT still flag it.
- **Coverage gaps** — #1080 liquidated-settled-redeem fix has no enabled public-flow test; liquidation-book
  paging (>64) + passive scan untested (lens 01/07/09).

## B. Must classify as SETTLED (not re-raise as new)
The prior-awareness step must tag these with their D-id and downrank, never report as fresh bugs:
- D031 — oracle basis/deviation drift guards removed by design (operator trusted).
- D026 — u64 `strike_quantity` overflow accepted + documented.
- D030 — backing reserve = settlement floor + λ-buffer.
- D033 — protocol-reserve realization deferred-and-carried (`pending_protocol_profit`).
- Exact `current_nav`, single mark, **no conservative band**; privileged cron flush via `MarketLifecycleCap`.
- `account` whole-account app-auth custody + no version gate (intended non-custodial property).
- A single unsettled past-expiry market blocking the flush (documented flush-liveness precondition).

## C. Ground-truth gate must fire
- A run must `sui build`/`test` all four packages **in the main loop** and report red state as a finding.
  Regression fixture: with the in-flight BS-feed-split test migration incomplete, `sui test --path
  packages/predict` does not compile (propbook tests reference the deleted unified API; predict config tests
  reference a removed knob). A run that reports "all green" while tests are red has FAILED its eval.

## D. Empirical gate must fire
- Lens 09 must actually run a Python sim (not just describe one) and report either a reproduced break with a
  seed/scenario or quantitative coverage. A run with zero executed sims has skipped its required empirical pass.

## F. Consolidator regression suite (run after editing the script)
`python3 .claude/skills/predict-audit/evals/test_consolidate.py` — deterministic, no deps, exits
non-zero on regression. Locks the silent-slip bugs found across skill reviews: `load()` marker-gating
(a decoy preamble can't swallow the findings), id/dedup granularity (distinct findings never share an id),
errored-harness loud exit, walk-`uncertain` tagging, the panel-health render (`unverified-panel` /
`panel_degraded` / `panel_severity` never silently folded), and the no-slip accounting. Run it before
committing any change to `consolidate.py`.

## E. Seeded-bug RECALL harness (`evals/seeds.md`)
The one property two clean runs can't give you: does a run confirm a REAL bug it wasn't told about?
`evals/seeds.md` holds content-based (drift-proof) seed recipes — apply ONE in a scratch worktree, run a
cheap `depth:'low'` audit, confirm the expected finding surfaces at High/Critical, revert. A miss is a recall
hole and the highest-signal input to the next skill revision. Never commit a seeded tree.

## G. Verify-panel PRECISION bench (`verify-bench.workflow.js` + `evals/verify_corpus.json`)
Benchmarks the single most load-bearing component — the verify panel — in isolation, with NO find phase, for
a fraction of a full run. `verify_corpus.json` is a labeled corpus (each entry `expect`s refuted|settled,
grounded at HEAD); `Workflow({ scriptPath: '.claude/skills/predict-audit/verify-bench.workflow.js' })` runs
the real panel over it and reports precision + any false-positive `confirmed` LEAK. Run it after any change to
the verify prompts/panel. Recall is section E (seeds), not this bench.

## H. Pre-run drift lint (`preflight.py`) — MAIN loop, part of Step 1
`python3 .claude/skills/predict-audit/preflight.py` — fatal on module-map drift (a `primer.md` path missing
from the tree), warns on D-id drift (a cited `D0NN` absent from every committed ledger — it lives only in the
local decision journal; promote it). A stale primer misleads hundreds of agents at once, so run this before
every launch.
