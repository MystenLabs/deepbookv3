# Frozen-grid freeze policy — experiment specification

> **Scope:** Decide how often, if ever, the inventory-impact grid must be re-derived after market creation. The coordinate itself is settled: `K95_grid = average(top 5 bucket range-max payouts) − E_frozen`, per the [frozen-grid spec](frozen_grid_inventory_impact_spec.md). This document only fixes the freeze cadence and the evidence required to choose it. [P-32](../../predeploy/open-items.md#p-32-implement-frozen-grid-inventory-impact) owns resolution.

## What changed since the frozen-grid spec

The frozen-grid spec justifies immutability as a security property: with live probabilities a trader could open while the model called a transition risk-reducing and close after an oracle move made the reverse transition also look risk-reducing, extracting escrow funded by other traders. That argument depends entirely on refunds existing. With non-refundable charges there is no escrow to extract and no reverse-direction payout, so freezing is no longer a security requirement — it is a determinism and gas choice, and its cadence is therefore open on cost/accuracy grounds alone.

## The two staleness drivers are not symmetric

Spot drift is bounded and two-sided: over a market's life spot moves on the order of one standard deviation, sometimes less, and the direction is unpredictable. Time decay is neither. Production cadences are 1m, 5m, and 1h, and markets are created up to three periods ahead, so remaining time falls from its initial value to zero in every market without exception. Because the settlement distribution's width scales with the square root of remaining time, a grid frozen at creation is `sqrt(tau_0 / tau)` times too wide by the time `tau` remains — roughly 3x too wide at 90% of the way to expiry and 10x at 99%.

The consequence to test is directional. Buckets built to hold 1% of probability each stop holding it: the outer buckets that constitute the frozen bad tail drift toward settlement prices the true distribution can no longer reach, while the region where settlement will actually land collapses into a handful of central buckets. A pile-on at current spot — the trade that most reliably creates real capital near expiry — may therefore never enter the frozen top five and may be charged nothing.

## What gets measured

The currency of interest is the charge, not the coordinate level. A level offset that is constant across a trade cancels in `phi(after) − phi(before)` and costs nothing, so level error alone is not evidence of a problem.

For a book built from mixed flow (predominantly near-the-money up/down positions, with a minority of narrower range positions, matching the expected BTC product), and for each point on a grid of elapsed-time fractions and spot moves measured in standard deviations of the market's own remaining move:

- **Marginal charge error.** Frozen `Delta K` versus true `Delta K` for an incoming trade, as a ratio.
- **Sign-error rate.** The fraction of incoming trades whose frozen charge carries the opposite sign to truth. This is the failure that matters, because a wrong sign means real capital added for free.
- **Bias direction.** Whether the frozen charge systematically over- or under-charges, since over-charging is merely inefficient while under-charging is uncompensated risk.
- **Level error.** Reported for interpretation only, not as a decision input.

Truth is the tail average of the payout profile under the current settlement distribution, minus its expectation under that same distribution. Both a lognormal and a fatter-tailed log-return law are used; a conclusion that holds under only one of them is reported as unresolved rather than as a finding.

## Candidate policies

- **Freeze once at creation.** Current implementation. No new state, no keeper work.
- **Freeze wide.** Build the grid at creation from a deliberately inflated volatility so that decay moves the frozen measure toward truth rather than away, and residual error is conservative. No new state or keeper work.
- **Re-freeze on elapsed time.** Re-derive boundaries when remaining time has fallen by a fixed fraction. Requires roughly one hundred payout-tree queries plus a re-derivation of `E`, so it is a keeper-cadence operation, not a trading-path one.
- **Re-freeze on spot drift.** Re-derive when spot has moved past a threshold in standard-deviation units.
- **Live grid.** No freeze. Bounded here as a reference point for how much accuracy any freeze gives up, not as a proposal, because re-deriving `E` per trade is out of budget.

## Pre-registered decision rules

Evaluated over the region actually reachable in production — elapsed fractions from 0 to 99% of market life, spot moves within ±2 standard deviations:

1. If freeze-once produces no sign errors and keeps median marginal charge error within ±25% across that whole region, keep freeze-once and close the question.
2. If freeze-once fails only beyond some elapsed fraction or drift threshold, and freeze-wide brings it inside the tolerance, adopt freeze-wide and record the inflation factor.
3. If freeze-wide is insufficient but a time-triggered re-freeze at some fraction satisfies rule 1, adopt it and record the trigger, accepting the keeper cost.
4. If no policy without per-trade re-derivation satisfies rule 1, report that the coordinate cannot be made accurate under a freeze and escalate the choice: accept a bounded known bias, restrict market lifetimes, or abandon the grid coordinate.

Under-charging is weighted more heavily than over-charging. A policy whose errors are all conservative may pass rule 1 at a wider tolerance, which must be stated explicitly rather than applied silently.

### Amendment after the first run

Rule 1's "no sign errors" bar is unachievable and was replaced. Bucket maxima are deliberately conservative, so a fully live grid still disagrees with the true tail average on a few percent of trades; that residual is discretization, not staleness. The live grid is therefore carried as an explicit floor and every policy is scored against it rather than against zero.

The decision criterion was also sharpened. Delivered compensation under price-taking flow turned out not to discriminate between policies, because a frozen grid's errors are two-sided and largely cancel when trades arrive at random. What discriminates is **sensitivity to flow selectivity**: how far delivered compensation falls when traders choose among the options in front of them. Selectivity is unobservable and cannot be absorbed into `r_K` calibration, so the policy whose outcome depends least on it is preferred even at equal average accuracy.

## Result

Delivered compensation on risk-adding trades, with non-refundable charges so a negative potential move bills zero:

| Policy | Price-taking flow | Trader picks cheapest of six | Trader picks best of six knowing both measures |
| --- | --- | --- | --- |
| Live grid (discretization floor) | 1.016 | 0.959 | 0.992 |
| Freeze once at creation | 0.962 | 0.719 | 0.654 |
| Freeze wide, 1.5x volatility | 1.025 | 0.795 | 0.715 |
| Re-freeze every 25% of life | 0.992 | 0.795 | 0.812 |
| Re-freeze every 10% of life | 1.007 | 0.886 | 0.894 |
| Re-freeze every 5% of life | 1.009 | 0.903 | 0.925 |

Freeze-once is adequate against price-taking flow and loses roughly a third of compensation against selection. Both the frozen boundaries and live spot are on-chain, so the divergence a trader would exploit is public information and requires no private view; the informed column is the realistic case rather than a pessimistic bound. Freezing wide does not help, because inflating the initial width does not correct a misplaced centre once spot has drifted. The same ordering holds under a fatter-tailed settlement law, where freeze-once delivers 0.626 and a 5% re-freeze delivers 0.914.

The selectivity spread — price-taking minus informed — is the decision-relevant quantity: 2 points for a live grid, 8 for a 5% re-freeze, 11 for 10%, 18 for 25%, and 31 for both freeze-once and freeze-wide.

This inverts the frozen-grid spec's security argument. Freezing was adopted to prevent oracle movement from creating rebate arbitrage. With rebates removed, freezing no longer prevents anything, and staleness instead creates a compensation shortfall that a trader can harvest by choosing when and where to trade.

## Open implementation question

Re-freezing at 10% of market life is roughly one keeper tick for the 1m cadence and less frequent for longer ones, so the cadence itself is affordable. The cost is per re-freeze: new boundaries require about one hundred payout-tree range-max queries, and `E` must be re-derived under the new measure. `E` is the harder half, because it needs each bucket's *average* payout rather than its maximum, which the payout tree does not currently summarise. Whether to add that aggregate, walk the tree once per re-freeze, or bound re-freezing to longer cadences is an implementation decision this experiment does not settle.

## Non-claims

This experiment does not calibrate `B_K` or `r_K`, does not model trader response to the charge, and does not measure gas. It uses a parametric settlement law as truth, so it establishes how a frozen discretization diverges from its own generating measure under decay and drift — not how well either matches BTC.
