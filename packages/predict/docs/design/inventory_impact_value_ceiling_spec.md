# Inventory impact value ceiling — notebook specification

> **Status:** Specification for a decision experiment that gates further inventory-impact work. [P-32](../../predeploy/open-items.md#p-32-implement-frozen-grid-inventory-impact) owns the open decision. This document registers the method and the decision rule before the run; it settles nothing on its own.

## Question

[`frozen_grid_inventory_impact.ipynb`](../../simulations/frozen_grid_inventory_impact.ipynb) names the right objective — expected PLP profit per dollar of economic capital — and then calibrates against a revenue target instead of measuring that objective. It reports what one reference transition would be charged; it never reports whether charging changes the ratio.

This notebook asks the prior question:

> How much can *any* concentration-pricing mechanism improve PLP risk-adjusted return, at the best case, before we choose a coordinate or a rate?

The answer is a ceiling, not a forecast. If the ceiling is small, no coordinate and no calibration can rescue the mechanism and the remaining implementation work should stop. If the ceiling is large, the next question — which is not this notebook's — is how much of it a cheap coordinate captures.

## Objective function

Let `F` be all pool income over a market's life and `K` the pool's economic capital. The measured objective is

```text
R = F / K
```

`F` includes every income component. The frozen-grid notebook deliberately excludes base-fee and spread income from its numerator so that pricing compensation cannot excuse tail risk. That guardrail is reasonable for sizing one fee in isolation and wrong for measuring risk-adjusted return, because the ratio is a property of the whole book. A mechanism that raises one fee line by 22% while leaving `K` untouched has barely moved `R`.

`K` is the centered 95% expected shortfall of pool payout:

```text
K = mean(payout over the worst 5% of settlement outcomes) - E[payout]
```

## Independence of the denominator from the coordinate under test

`K` must be computed from the true settlement distribution at fine resolution, never from the 100-bucket frozen grid. Measuring the ceiling with `K95_grid` in the denominator would be circular: the diversification counterfactual minimizes exactly what the denominator measures, so the improvement would be an artifact of the estimator rather than a fact about the pool.

The notebook therefore represents the settlement line as 2,000 equal-probability cells and computes `K` exactly over them. `K95_grid` is then visibly one coarse, conservative estimator of that same quantity, which is what makes the later coordinate comparison meaningful rather than tautological.

## Measure independence

A range contract pays a fixed amount on a probability interval, so every quantity in this experiment is invariant to the shape of the pricing measure. Working in probability space rather than price space removes any lognormal, SVI, smile, or volatility assumption from the result. This is a real strength of the method and should be stated in the notebook: no objection of the form "your volatility surface is wrong" can reach the conclusion.

## Three channels a fee can move

The notebook must separate these, because they have very different magnitudes and very different feasibility.

- **Revenue.** Flow trades anyway and pays the charge. Raises `F`, leaves `K` alone. Requires no behavioral response, so it is fully achievable and also the weakest channel.
- **Composition.** Flow relocates to less-overlapping ranges. Leaves `F` alone and lowers `K`. Requires trader elasticity, which cannot be observed before launch, so the notebook measures its ceiling rather than its realization.
- **Refusal.** Flow that would degrade the ratio is priced out. Lowers `K` and forgoes the income the trade would have paid. Achievable deterministically by an admission cap rather than by a fee.

Relocation must preserve each trade's probability width and quantity so its premium and fee are unchanged. Composition then affects only the denominator, and the improvement is exactly `K_baseline / K_relocated`.

## Flow model and its central assumption

There is no production flow to replay, so flow is generated and the generating assumption is the main threat to validity. It must be exposed as one parameter and swept, not buried.

The parameter is **clustering**: the probability that a trade's range is drawn near a shared per-market theme location rather than independently across the line. `0` is naturally diversified flow, for which no concentration mechanism can help. `1` is every trader piling into the same region. The reported result is the ceiling as a function of clustering, not a single number.

## Parts

### Part 1 — objective and primitives

Discretization, the Predict fee formula, the payout profile, and `K`. Self-checks must reproduce Part 1 of the frozen-grid notebook: a guaranteed full-line payout gives `K = 0`, and a $1,000 payout over 5% of probability mass gives `K = $950`. Reproducing those exactly establishes that this notebook and the existing one measure the same quantity before they disagree about anything.

### Part 2 — flow and baseline

Generate flow across seeds, report the baseline `R`, and show the distribution of per-trade marginal capital so the reader can see how much of `K` a few trades create.

### Part 3 — the three channels and the ceiling

Report `R` for: baseline; revenue-only at the notebook's recommended `B_K` and `r_K`; relocation ceiling; refusal frontier swept over an acceptance hurdle, reporting the ratio-maximizing point and the volume it turns away; and relocation plus refusal combined.

### Part 4 — sensitivity to clustering

Sweep clustering and plot the ceiling improvement against it. Report the seed-to-seed spread, not only the mean.

### Part 5 — decision

Apply the rule below and state the outcome plainly, including "the mechanism cannot pay for itself" if that is the answer.

## Decision rule, registered before the run

Let `improvement` be the combined ceiling's percentage gain in `R` over baseline at the central clustering assumption.

- `improvement < 15%`: stop. No coordinate choice or calibration can make the mechanism worth its complexity. Recommend deleting the inventory-impact machinery rather than refining it.
- `15% <= improvement < 50%`: build the coordinate comparison. Whether to ship depends on how much of the ceiling a cheap coordinate captures, so the simplicity ladder is the deciding measurement.
- `improvement >= 50%`: the mechanism is worth having. The coordinate comparison becomes a question of choosing the cheapest adequate estimator, not of whether to proceed.

Two secondary rules:

- If the revenue channel alone accounts for more than 80% of the total achievable improvement, the mechanism is a revenue tool and a flat base-fee increase is the simpler substitute. Recommend that instead.
- If the refusal frontier reaches within 90% of the combined ceiling on its own, prefer an admission cap over a fee, because a cap needs no calibration and cannot be out-run by an edge larger than the rate.

## Amendment after the first run

The registered metric was the wrong one, and the record should say so rather than be quietly reinterpreted.

Improvement in `R` is unbounded under full relocation. A book of 200 trades averaging 6.4% of probability mass sells roughly thirteen line-covers of payout, so a perfect allocator tiles it nearly flat and drives `K` toward zero; any ratio with `K` in the denominator then explodes. The first run returned roughly +2,000%, which reports the degeneracy of the counterfactual rather than a property of the pool, and the 15/50 thresholds cannot discriminate against a number that large.

The notebook therefore keeps the registered metric visible for the record and takes the decision on two bounded readings instead:

- **Capital removed**, `1 - K_policy / K_baseline`, which lies in `[0, 1]`. At full relocation this measures the share of PLP capital created by *where* flow landed rather than by how much of it there was, which is the prize any concentration mechanism competes for.
- **The elasticity-free channels only** — revenue and refusal — to which the original 15/50 thresholds still apply meaningfully, because neither channel can drive `K` to zero.

The relocation counterfactual is additionally reported as a frontier over the fraction of flow that responds, since the fully steered corner is not a policy anyone can implement.

Two assumptions the first run showed to be load-bearing, and which the notebook now sweeps: flow clustering, as originally planned, and **book thickness**, which was not planned. Thickness sets how many line-covers the book sells and therefore how much room a reallocation has; the prize falls from 96% to 54% of capital as the book thins from 400 to 20 trades, so it cannot be left at one value.

## Non-claims

- This is a ceiling, not a prediction. Realized improvement requires trader elasticity that no pre-launch experiment can measure.
- Relocation is a counterfactual about the pool, not a claim that a trader would accept a different product.
- The refusal frontier is greedy in arrival order, so it is an achievable policy rather than a global optimum.
- Nothing here calibrates `B_K` or `r_K`, evaluates the frozen grid's staleness, or measures adverse selection.
