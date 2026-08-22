# Inventory impact under persistent adverse selection — notebook specification

This is a specification for a short notebook, not the notebook itself. It names each cell, what that cell must contain, and what it must show. The intended reader should be able to understand the economic question and result without reading Predict source.

The notebook asks:

> If a trader has a persistent edge after pricing and all ordinary fees, how much expected value can they extract before inventory impact makes the next liability-increasing trade uneconomic?

This follows `packages/predict/simulations/inventory_impact_calibration.ipynb`. The existing notebook explains the mechanism and trader-facing magnitude. This notebook tests whether a candidate rate has a direct economic effect on expected LP loss.

Before treating a run as formal Predict evidence, attach the experiment and decision rule to the owning item in `packages/predict/predeploy/open-items.md`.

## Scope and assumptions

- Residual edge `ε` is assumed, persistent, and already net of pricing and every ordinary fee. The notebook does not model the base fee.
- The core attacker uses 1× contracts, repeatedly mints the same mispriced range, and holds through settlement.
- A same-range full pile-on adds approximately one dollar of payout liability per dollar of quantity.
- The attacker submits another trade only while expected incremental profit is positive.
- Core plots use 1¢ and 2¢ edges; the final communication table covers 2¢, 3¢, and 4¢ per $1 of quantity.
- Candidate maximum rates are 0%, 1%, 2%, 2.5%, 3%, and 4%.
- Primary impact scale is the current one-minute testnet value, `B=$50,000`.
- Voluntary closes and disjoint attacks appear only as limitations.
- Block Scholes data is deferred; it may later supply realistic market states but must not replace assumed `ε`.

For quantity `q` and inventory charge `I`:

`Π = εq − I`.

For a small full-pile-on trade below the scale:

`marginal inventory cost per quantity ≈ r × L/B`.

The approximate stopping utilization is:

`u_stop = ε/r`.

If `r≤ε`, inventory impact never strictly exceeds the edge. For infinitesimal full-pile-on flow starting from zero with `r>ε`, cumulative expected extraction before stopping is:

`Π_cumulative = Bε²/(2r)`.

Exact reported results must use Move-parity integer arithmetic and finite fills.

## Part 1 — define the economic test

### Cell 0 — Markdown: question, assumptions, and non-claims

Define `ε`, `q`, `L`, `B`, `r`, `I`, and `Π=εq−I`. State that known pricing errors still need correction; inventory impact only responds to liability movement; the attacker holds through settlement; and the result does not cover every arbitrage strategy.

**Output:** one screen of context and no executable output.

### Cell 1 — Code: configuration and exact mechanism

Define units and visible inputs: `B`, residual edges, candidate rates, starting utilization, and fill quantity. Reuse the exact inventory-potential implementation and payout-tree mirror from the existing calibration notebook. Run the existing Move fixtures before continuing.

**Output:** compact input summary and exact “Move parity passed” line. Stop on mismatch.

### Cell 2 — Code and figure: analytical benchmark

Calculate stopping utilization and cumulative extraction for each `(ε,r)` pair.

**Output:** one small table and one plot of cumulative extraction against `r`, with explicit `r=2%` callouts. Make clear that at `r=2%`, a 1¢ edge reaches marginal break-even near 50% utilization while a 2¢ edge is never strictly overcharged.

## Part 2 — replay the exact finite-fill attack

### Cell 3 — Markdown: attack procedure

Explain the loop: observe the book, quote one more same-range fill, compute exact liability movement and inventory charge, execute only if `εq−I>0`, and repeat.

**Output:** no executable output.

### Cell 4 — Code: worked trade and repeated attack sweep

First show one decomposed trade with `L_before`, `L_after`, `εq`, `I`, and incremental profit. Then run the exact attack for each edge, rate, and starting utilization.

Record final utilization, stop reason, total quantity, gross residual edge, retained inventory impact, and cumulative attacker profit.

**Output:** one worked example and one tidy result table. Label `r≤ε` cases “inventory rate cannot strictly stop this edge.”

### Cell 5 — Figure: attack path

For 1¢ and 2¢ edges at `r=2%`, plot incremental profit and cumulative extraction against utilization. Mark `L=B` and the first rejected fill, if any.

**Output:** a direct picture of how much LP value is lost before the attacker stops.

## Part 3 — decide whether a rate is economically justified

### Cell 6 — Code: decision rule

Expose two team inputs: maximum acceptable cumulative LP loss per expiry and maximum acceptable inventory charge on one explicitly named reference trade. Select the smallest rate satisfying both. If either input is unset, report the frontier without recommending a rate.

Finish with a settlement-held full-pile-on table for 2¢–4¢ edges showing `r`, utilization reached, total traded, total pricing advantage, inventory skew savings retained for LPs, and amount extracted. Label combinations where `r<edge` as unbounded rather than truncating them at the simulation horizon.

**Output:** the decision status followed by the headline economic table.

### Cell 7 — Markdown: conclusion and limitations

Summarize extraction, stopping utilization, retained impact, and reference cost for each important candidate. End with three limitations: voluntary closes can recover escrow; disjoint adverse flow is less affected; and inventory impact does not replace pricing correction or ordinary fees.

**Output:** a concise recommendation, “no tested rate works,” or “team decision inputs required.” Zero is valid.

## Implementation acceptance criteria

- At most eight cells and three parts.
- Runs top to bottom without hidden state.
- Uses exact Move-parity arithmetic.
- Treats `ε` as net of every ordinary fee.
- Reports cumulative extraction, not only stopping utilization.
- Clearly labels attacks inventory impact cannot stop.
- Does not recommend a rate without explicit LP-loss and reference-cost constraints.
- Keeps Block Scholes data and additional strategies out of the first implementation.
