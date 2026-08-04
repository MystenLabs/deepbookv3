# Harness Strategy Builder

Read this when the user wants to **add a Predict harness trading strategy** or **test a scenario in the harness** (triggers: "I want to add a harness strategy", "build a strategy", "test X in the harness", "make the harness do Y").

## Authority

- [Predict harness rules](predict-harness.md) own architecture, strategy, validation, and safety invariants.
- [`strategy.ts`](../../packages/predict/harness/ts/strategy.ts) owns the live `StrategyCtx` and `Strategy` interfaces.
- The harness [Strategies & campaigns](../../packages/predict/harness/README.md#strategies--campaigns) documentation owns the operator-facing model, built-in strategy inventory, and campaign usage.

## 1. Intake — what does the user want to test?

If the user described it, restate your understanding and fill the gaps. Otherwise ask one round (≤4 questions):
- **Behavior / scenario** — e.g. high-frequency minting, leverage→liquidation, LP churn (supply/withdraw), settlement load, adversarial/guard probing, an oracle-edge or pool-drain attempt.
- **What to measure / the success signal** — gas, NAV / pool drain, liquidation volume, a specific invariant, or simply "the bug oracle stays clean".
  - For a deliberate terminal-wall probe, use `Strategy.expect` exactly as defined in `strategy.ts`.
- **Pacing + volume** — rate (`tickMs`) and stop condition (`maxOps` for run-to-completion, or duration).
- **Expiry selection** — nearest, random, or a specific cadence.

## 2. Map the request to the `StrategyCtx`

Read the authoritative `StrategyCtx` in `strategy.ts` before promising a scenario. If the request cannot be expressed through that interface, go to 3b.

## 3a. If the scenario IS supported → build it

1. Copy the closest built-in strategy named in the harness documentation to `strategies/<name>.ts`.
2. Implement the `Strategy` contract from `strategy.ts`; derive pacing, stop condition, funding, and expiry selection from the intake.
3. Register it in `strategies/index.ts`.
4. Follow the harness rule's [Build & verify](predict-harness.md#build--verify) procedure, run the named strategy through the documented [campaign flow](../../packages/predict/harness/README.md#strategies--campaigns), and confirm the scenario's stated success signal.

## 3b. If the scenario is NOT supported → note it, then extend the harness

If the test needs something the ctx can't express (a new entrypoint, an on-chain read, a multi-account interaction, cancelling a queued LP request, a new order type, …):
1. **State the gap explicitly** — which primitive/state is missing and why the current ctx can't express it. Record it as a harness-improvement note.
2. Offer to **extend the harness**: add the PTB builder in `runtime.ts`, expose the smallest matching `StrategyCtx` method in `strategy.ts`, then build the strategy on that interface.
3. Follow the harness rule's [Don't](predict-harness.md#dont) constraints. If the scenario genuinely requires a contract change, raise it as a separate finding rather than a harness workaround.
4. Validate as in 3a, then **tee up a PR** for the harness extension + the new strategy.
