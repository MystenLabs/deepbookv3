# Harness Strategy Builder

Read this when the user wants to **add a Predict harness trading strategy** or **test a
scenario in the harness** (triggers: "I want to add a harness strategy", "build a strategy",
"test X in the harness", "make the harness do Y"). Also read `.claude/rules/predict-harness.md`
(the harness invariants) before writing or extending any strategy code.

The harness ships with example strategies in `packages/predict/harness/ts/strategies/`
(`fuzz`, `mint-only`, `mixed-churn`, `liq-churn`) — use them as templates. A strategy is a
self-contained code module; building one should NOT require touching the runner, the keeper, or
the contracts.

## 1. Intake — what does the user want to test?

If the user described it, restate your understanding and fill the gaps. Otherwise ask one round
(≤4 questions):
- **Behavior / scenario** — e.g. high-frequency minting, leverage→liquidation, LP churn
  (supply/withdraw), settlement load, adversarial/guard probing, an oracle-edge or pool-drain
  attempt.
- **What to measure / the success signal** — gas, NAV / pool drain, liquidation volume, a
  specific invariant, or simply "the bug oracle stays clean".
- **Pacing + volume** — rate (`tickMs`) and stop condition (`maxOps` for run-to-completion, or
  duration).
- **Expiry selection** — nearest, random, or a specific cadence.

## 2. Map the request to the `StrategyCtx`

A strategy's `tick(ctx)` may use ONLY what the ctx exposes — `ts/strategy.ts` is the authoritative surface (a table that lived here drifted from it and was removed); read it before promising anything. If the request needs something the ctx can't express, go to 3b.

## 3a. If the scenario IS supported → build it

1. Copy the closest example (`strategies/<closest>.ts`) to `strategies/<name>.ts`.
2. Implement `tick(ctx)` for the behavior; set `name`, `tickMs` (≥ ~1s), `maxOps` (0 =
   duration-only), and `fund` (DUSDC the keeper grants the trader — size it for the op count). No
   `cadence` field — every keeper runs the full prod cadence set; a strategy spans cadences via the
   expiries it picks (`nearestExpiry`/`randomExpiry`, or filtering `ctx.markets()` by expiry).
3. Register it in `strategies/index.ts` (the registry; `meta.ts` then exposes it to `campaign`
   automatically).
4. Validate — run these in the **main loop or background, never a blocking subagent**:
   - `cd packages/predict/harness/ts && npx tsc --noEmit` (0 errors)
   - `python3 -m harness campaign <name> --timeout N` then read the analyze verdict: the new ops
     appear, the bug oracle is **clean** (exit 0), and the measured signal behaves as intended.

## 3b. If the scenario is NOT supported → note it, then extend the harness

If the test needs something the ctx can't express (a new entrypoint, an on-chain read, a
multi-account interaction, cancelling a queued LP request, a new order type, …):
1. **State the gap explicitly** — which primitive/state is missing and why the current ctx
   can't express it. Record it as a harness-improvement note.
2. Offer to **extend the harness** (an improvement, not a workaround): add the PTB builder in
   `runtime.ts` and a thin `StrategyCtx` method in `strategy.ts` (wrapping `submit` + bookkeeping
   + `trace`), then build the strategy on top.
3. **Never modify the Predict contracts or `dusdc`** to suit a strategy — the harness drives the
   deployed contracts as-is (re-signing oracle data with a local key). If the test genuinely
   needs a contract change, raise it as a separate finding, not a harness edit.
4. Validate as in 3a, then **tee up a PR** for the harness extension + the new strategy.

## 4. Invariants every strategy must respect

`.claude/rules/predict-harness.md` owns them; the ones strategies most often violate are custody-only supply / read-before-withdraw, one-op-per-tick pacing (`tickMs ≥ ~1s`), ctx-only access, and one data stream.

## References
- `ts/strategy.ts` — the `StrategyCtx` + `Strategy` contract (the only surface a strategy sees).
- `ts/strategies/{fuzz,mintOnly,mixedChurn,liqChurn}.ts` — copy-from templates.
- `.claude/rules/predict-harness.md` — harness invariants + the `campaign` flow.
