# Lens 09 — Economic Simulation & Invariant Fuzzing

## STEP 0 — read shared context (required)
Read `../primer.md` in full first. Treat it as binding. If you cannot read it, stop and ask.

## Your lens
Economic simulation & invariant fuzzing — the **empirical** lens. The other lenses reason about the code; you
**run it** and try to break it with numbers. You own `packages/predict/simulations/`. Your deliverable is
either a reproduced break (with the exact scenario/seed) or quantitative evidence that the load-bearing
economic invariants hold under stress. Do NOT settle for re-running the existing parity harness — it is a
happy-path harness (one vault, one market, one manager, generated normal rows). To find bugs you must **author
new adversarial scenarios and property/fuzz tests.**

**The toolbox (and where each runs):**
- `python_indexes/strike_payout_tree.py`, `python_indexes/liquidation_book.py` — Move index mirrors.
- `python_replay.py` — mint-admission / pricing / NAV mirror. `summarize_economics.py`, `charts/` — outputs.
- `bash run.sh` — full **localnet** parity (MAIN-LOOP ONLY; trips the subagent watchdog). If you need a
  localnet PoC, write the scenario + the exact command and hand it back to the main loop.
- `bash run.sh --python-only` and any ad-hoc Python you write to the scratchpad — **subagent-safe**.

**Required campaigns (write new scenarios; assert invariants after every step):**
1. **Solvency / conservation fuzz.** Randomized sequences of mint / redeem / liquidate / supply / withdraw over
   the python mirrors. After each op assert: cash-backing (`balance >= payout_liability + rebate_reserve`),
   no negative balances, DUSDC conserved across the trader/LP/protocol/builder split, rounding favors the
   protocol (never the user). Report any breaking seed + the minimal reproducing sequence.
2. **NAV mark symmetry / timing.** Drive supply and withdraw across a flush at a moving mark; confirm
   `supply_NAV == withdraw_NAV == TRUE` at the valuation boundary and that no deposit-before / withdraw-after
   sequence extracts value from incumbents (the canonical LP-dilution attack).
3. **Leverage / liquidation stress.** Many leveraged orders crossing their static floors rapidly; force payout
   tree `walk_linear` and liquidation-book paging (>64 orders) across budgeted passive passes; confirm no order
   is skipped, double-liquidated, or left under-floor un-liquidated, and the aggregate-floor NAV precondition
   is maintained (else NAV overstates recoverable value).
4. **Settlement / payout arb.** Settled-vs-live payout differences; liquidated-then-settled redeem (the #1080
   path); off-grid/absent settlement print (fails closed?).
5. **Adversarial price paths.** Worst-case oracle paths within the consumer envelope (and freshness-skewed
   spot/forward/svi) driving the pool toward insolvency; measure fee coverage vs payout and any drain.

**Discipline:** when a Python mirror disagrees with the Move source, suspect the mirror first — confirm the
break reproduces against the contract (a localnet run via the main loop, or by reading the Move path) before
reporting it as a protocol bug, so a sim-mirror bug is never reported as a contract bug. Keep one CSV row = one
PTB; reuse Move defaults from `scenario_config.json` so the economics match the contract.

## Output
Report each reproduced break in the primer's report format with Evidence = the scenario/seed + the assertion
that failed (and the localnet command if a full PoC is needed). For invariants that held, give the quantitative
coverage (ops fuzzed, price paths, order counts) so "no break found" is meaningful, not vacuous. Top 3 =
highest-value breaks or the riskiest untested economics. Return structured findings to the orchestrator or
write `.claude/predict-review/reports/<date>/09-economic-simulation.report.md` when solo. Never modify source
or commit into the package; temp sims live in the scratchpad.
