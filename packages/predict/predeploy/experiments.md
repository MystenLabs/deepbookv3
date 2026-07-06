# Predict Harness Experiment Ledger

Updated 2026-07-02. The running list of capacity / safety / liveness experiments
driven through the localnet harness (`packages/predict/harness`). This ledger is
the bridge between the trackers and the harness: every experiment names the
**driving ID** it informs (an `open-items.md` item or a `response-policies.md`
entry) and carries a **decision rule written before the run**, so results flip a
tag or close an item instead of being read as ambient reassurance.

Findings graduate to `stress/` (dated finding doc, then the consolidated
`stress/capacity-and-gas-findings.md`); decisions graduate to
`response-policies.md` or resolve `open-items.md` entries.

## Status legend

- **DONE** — run + analyzed, finding written and linked.
- **BUILT** — strategy exists and registers; full run not yet executed.
- **READY** — harness supports it; strategy not yet written.
- **BLOCKED** — needs a harness extension first (see the extension table).
- **RETIRED** — the question no longer exists at HEAD (say why).

## Experiments

### E1 · `nav-stress` · DONE

- **Drives:** C-1 (flush joint valuation budget).
- **Question:** how large can ONE market's leveraged book get before the pool
  flush OOGs?
- **Result:** single-market flush OOGed at ~4,580 leveraged orders (cheap
  `normal_cdf` branch), 98% of the 5M computation-unit wall; linear ~1,086
  units/order (R²=0.998). Superseded for current HEAD by the NAV price memo
  (single-market cheap-branch now ~47–54% of the wall); remains the evidence
  base for the pool-total joint budget.
- **Refs:** `stress/nav-stress-findings-2026-06-30.md`,
  `stress/price-memo-findings-2026-07-01.md`,
  `stress/capacity-and-gas-findings.md` · strategy `ts/strategies/navStress.ts`.

### E2 · `nav-stress-atm` · BUILT — full run pending

- **Drives:** C-1 (the worst-case per-market cost input to the joint budget).
- **Question:** reproduce the expensive-branch (`exp_series`, near-ATM) per-order
  cost in-instrument; E1 rode the cheap branch.
- **Decision rule:** the measured worst-branch cost per order replaces the
  fuzz-derived ~3,644 units/order in the C-1 cap sizing; if the joint budget at
  current caps exceeds ~60% of the 5M wall, C-1's cap tightening becomes a
  deploy blocker rather than a recommendation.
- **Strategy:** `ts/strategies/navStressAtm.ts`. Prior smoke run reached only
  ~2% of the cap and predates the strike-tuning fix — a full run to the
  breakpoint is required before citing a number.

### E3 · `nav-stress-multi` · BUILT — full run pending

- **Drives:** C-1 (pool-total confirmation).
- **Question:** does the pool-total flush OOG at ~the single-market total, and
  is the per-market base stable × K markets?
- **Decision rule:** confirms (or corrects) that the binding constraint is
  `Σ_markets(value_expiry cost)` under one wall; the measured per-market base
  feeds the same C-1 cap sizing as E2.
- **Strategy:** `ts/strategies/navStressMulti.ts`.

### E4 · `mint-batch` · DONE

- **Drives:** C-3 (batched PTB amplification) — closed 2026-07-06 as
  accept + disclose (`response-policies.md` RP-10, `docs/risks.md`
  § Batched transactions).
- **Question:** why does a 100-mint PTB cost 3–5B computation when 100
  standalone mints ≈ 650M?
- **Result:** per-transaction metering / command-position accumulation, NOT
  liquidation-book page dirtying (discriminator: a leveraged mint appended after
  20 1x mints — no prior liq-book writes — amplified 20.2×). Replicated across
  two runs. Atomic ceiling ~110–150 leveraged mints/PTB.
- **Refs:** `stress/mint-batch-findings-2026-07-01.md` · strategy
  `ts/strategies/mintBatch.ts` (+ `batchMaxBook.ts` / `batchMaxMarkets.ts`).

### E5 · `lp-adversary` · BLOCKED → extension #3

- **Drives:** C-4 / RP-2 / RP-3 (flush-brick liveness), P-7 (unbounded mark
  exposure for queued requests), S-4 + P-5 (BS push steering/blanking the NAV
  mark the privileged flush consumes).
- **Question:** reproduce the LP-flush liveness and economic vectors distinct
  from the gas OOG: drive the NAV mark (inflate → LPs withdraw idle → collapse
  → sticky exclusion exceeds gross → NAV = 0) and observe the queues.
- **Measures:** `current_nav` mark trajectory vs supply/withdraw fills; the
  `EInvalidDrainMark` abort (bug oracle) is the brick signal.
- **Decision rule:** if the mark trajectory can be driven to a degenerate flush
  sample with realistic oracle motion, RP-2's risk profile flips
  BEST-GUESS → MEASURED and the C-4 fix priority escalates; a clean campaign
  bounds (does not close) the organic-reachability estimate.
- **Needs:** extension #3 (scripted-oracle trajectory, approach (a) — keeps the
  one-stream updater invariant; design against `oracleService.ts` before
  building). NAV/idle readback (extension #2) already shipped.

### E6 · `dust-mark-window` · READY (design)

- **Drives:** RP-2 (dust-mark fill overflow + supply ratchet; C-4 extension).
- **Question:** measure the fragile band's real width — under realistic
  collapse trajectories, how long does `lp_pool_value` sit in a band where a
  queued fill would overflow u64 or mint ratchet-scale shares, and what does the
  cheapest entry (young, small pool) look like?
- **Decision rule (pre-registered):** if no sampled flush instant across the
  campaign lands in the band at mature-pool scale AND the young-pool entry
  requires a loss the bug oracle can't produce organically, RP-2 keeps
  BEST-GUESS with a measured lower bound; if any flush samples inside the band,
  the C-4 fix becomes a deploy gate.
- **Builds on:** E5's extension #3 (same scripted-trajectory need); the Move
  boundary tests (`lp_book_tests`) pin behavior at the exact edges; this
  measures reachability dynamics only.

### Backlog (low-priority probes)

- **liq-budget** — public `liquidate()` takes an unbounded caller budget →
  self-DoS probe. Needs a raw liquidate builder + `ctx.submitLiquidate`.
- **payout-tree joint stress** — max payout nodes + max leverage together
  (prior runs reached only 83 boundaries; the 1,000-node cap was never
  benchmarked). Drives C-1's node-count term.
- ~~genesis-CB~~ · RETIRED — the upper PLP price circuit breaker was removed
  (RP-1, commit `cc67ed9f`); a genesis-appreciated pool no longer has a breaker
  to trip.

## Harness extensions (enablers)

| # | Extension | Enables | Status |
|---|---|---|---|
| 1 | Batched-mint PTB (`runtime.mintBatchTx` + `ctx.submitMintBatch`) | E4 | shipped |
| 2 | NAV / mark readback (`ctx.currentNav(market)` / `ctx.idleBalance()`) | E5/E6 observability | shipped |
| 3 | Scripted-oracle trajectory (updater follows a configured mark path; keeps the one-stream invariant) | E5, E6 | designed (approach a), not built |

## Update rules

- Every experiment names its driving ID and a decision rule **before** the run.
- A DONE experiment links its dated finding under `stress/`; the consolidated
  capacity doc is updated first, the dated doc only if its conclusion changed.
- When an experiment flips a `response-policies.md` risk tag
  (BEST-GUESS → MEASURED), update the entry and link the finding.
- Retire experiments whose question no longer exists at HEAD; say why inline.
