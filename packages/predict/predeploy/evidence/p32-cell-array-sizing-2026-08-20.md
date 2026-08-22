# P-32 inline cell array as a substitute for the refresh tree read, 2026-08-20

**Item:** P-32

**Revision:** `8277c28cf29ae7160470ba25d140e28b5163fd3f` plus the uncommitted frozen-grid implementation and the ratio-boundary interface.

**Instrument:** [`simulations/inventory_cell_array_sizing.py`](../../simulations/inventory_cell_array_sizing.py), run as `baseline` and as the four robustness variants. Exact arithmetic throughout: a book's payout profile is piecewise constant, so the profile, its expectation, the continuous worst-5% average, and the 100-bucket discretisation all have closed forms over the profile's own segments, and nothing is sampled.

## Question

[`p32-refresh-gas-2026-08-20.md`](p32-refresh-gas-2026-08-20.md) established that a refresh cannot complete at a full book, not because of computation but because `walk_linear` loads one dynamic-field child per payout-tree node against a 1,000-child per-transaction ceiling that coincides with `constants::max_payout_tree_nodes`.

A `Table` entry costs one child; an inline vector costs none. The grid's own `boundaries` and `bucket_maxima` are already inline and therefore free. So: if a coarse fixed-cell copy of the payout profile were held inline beside them, a refresh could rebuild both the bucket maxima and `E` while reading zero children.

That is only worth building if the array is small enough to hold inline and still reproduces the charge. Its resolution is fixed at market creation while the settlement distribution narrows with the square root of remaining time, so resolution per bucket degrades monotonically over a market's life. This measures whether a feasible cell count survives that.

## Method

Fidelity is scored against the **exact grid**, not against the continuous measure. The grid's economics are already established by the value-ceiling and flat-versus-convex work, so a cell array that reproduces the grid's per-trade charge inherits them; re-deriving the grid's own discretisation error would answer a question that is already closed. The continuous worst-5% measure is carried in one column only to show where both sit.

Cells are geometric — uniform in log price — spanning ±4 creation standard deviations, with the two open ends absorbing anything outside. Order edges snap to the nearest cell edge. A bucket's maximum is the largest cell value among cells overlapping it, and `E` is the mass-weighted sum over cells under the current law. Books are mixed flow, 140 orders, predominantly near-the-money up/down with a minority of narrower ranges, all respecting the 1%-to-99% mint admission bound. Charges are the non-refundable convex potential difference. Each point is 40 books × 60 candidate trades in the baseline, 25 × 60 in the variants, paired so every cell count sees identical books and candidates.

## Result: 2,048 cells reproduce the tree-read charge for almost all of a market's life

Footprint is one `u64` of net payout per cell. Unlike the payout tree this needs no signed start/end pair, because a cell holds an absolute non-negative payout and a range order adds its quantity to each covered cell directly.

| Cells | Inline | Centre cell |
| --- | --- | --- |
| 512 | 4 KB | 1.60 bp |
| 1,024 | 8 KB | 0.80 bp |
| 2,048 | 16 KB | 0.40 bp |

Median relative charge error against reading the tree, on trades the tree bills:

| Elapsed | Bucket width | 512 | 1,024 | 2,048 |
| --- | --- | --- | --- | --- |
| 0% | 2.55 bp | 2.6% | 1.3% | 0.3% |
| 25% | 2.21 bp | 2.4% | 1.2% | 0.7% |
| 50% | 1.80 bp | 3.2% | 1.7% | 0.7% |
| 75% | 1.28 bp | 3.9% | 1.6% | 0.6% |
| 90% | 0.81 bp | 5.9% | 2.8% | 1.6% |
| 99% | 0.26 bp | 12.0% | 8.2% | 5.4% |

At 2,048 cells the per-trade charge correlation with the tree read is 0.993 or better through 90% of market life, aggregate billing lands within 1.1% of the tree's total, and the trades the array bills zero while the tree bills something are worth 0.23% of total charge or less. The degradation is monotone in both cell count and elapsed time, exactly as the sqrt-of-remaining-time argument predicts, and the binding case is always the end of life rather than any drift or shape effect.

## Result: geometric spacing removes spot drift from the question

Repeating the sweep with the forward moved ±2 creation standard deviations reproduces the baseline to within a thousandth on every statistic, in both directions. Uniform spacing in log price gives constant basis-point resolution across the whole span, so a bucket sees the same relative cell width wherever spot has moved to, and a cut's fidelity is scale-invariant as long as spot stays inside the span. This is the same invariance that made ratio boundaries work, arriving for the same reason.

## Result: nearest snapping beats conservative widening

Widening every order to the cells it touches — so the stored profile dominates the true one everywhere — is worse on every measure, not merely more expensive. At 99% elapsed and 512 cells it over-bills by 26.7% with a charge correlation of 0.684, against 0.996 and 0.889 for nearest snapping. Widening inflates the tail and `E` together and the errors do not cancel, so the conservative variant is rejected: nearest snapping is both simpler and more faithful.

## Result: the finding holds under a fat-tailed law

Under standardised Student-t log returns with 4 degrees of freedom, at matched total variance, 2,048 cells hold median error at 0.3%, 0.9%, 2.4% and 6.0% across the same elapsed points — within a couple of points of the lognormal figures at every horizon, and with the same ordering across cell counts.

## Reading

A 16 KB inline array reproduces the tree-read charge closely enough that the coordinate's established economics carry over, for every part of a market's life except roughly the last one percent, and it does so under spot drift and under a fat tail. That removes the object-cache ceiling from the refresh path by construction rather than by tuning, because the refresh would then load no per-node children at all.

Two things are unresolved and neither is answered here.

The per-trade cost is unmeasured. The array is rewritten on every trade as part of the market object. Sui's storage rebate means overwriting an object of unchanged size is close to cost-neutral on the storage component, so the recurring charge is expected to be serialisation rather than storage, but that is an expectation and not a measurement. This is the next gate and it belongs in a localnet campaign, not in this model.

The last percent of market life degrades and needs a policy. At 99% elapsed even 2,048 cells sit at 5.4% median error with 4.3% of billed trades missed. The options are to accept a bounded known bias there, to stop refreshing below a remaining-time threshold and leave the market on its last good grid, or to stop charging entirely near expiry. Nothing here chooses among them.

## Limits

This is a parametric settlement law, so it measures how a coarse fixed discretisation diverges from an exact one under decay and drift, not how either matches BTC. It uses one book shape and one order count; thickness was not swept. It scores the charge, not delivered compensation under selective flow — the earlier freeze-policy measurement's selectivity framing was deliberately not reused here, because the question is fidelity to a coordinate whose selectivity properties are already established, and a selectivity re-run at this sample size was too noisy to discriminate between cell counts. It does not model the Move implementation's fixed-point rounding, and it does not measure gas.
