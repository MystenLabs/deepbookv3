# P-32 flat-versus-convex inventory charge, 2026-08-20

**Item:** P-32

**Revision:** `8277c28cf29ae7160470ba25d140e28b5163fd3f` plus the notebook and open-item changes that record this run.

**Instrument:** Part 9 of [`inventory_impact_value_ceiling.ipynb`](../../simulations/inventory_impact_value_ceiling.ipynb).

## Question and registered rule

The run compares the current capped convex potential against a flat charge on positive marginal centered capital. Flat is the implementation default because it does not need the stored absolute expected-payout level, priced refresh walk, convex scale, or RP-29 runtime response. Convexity earns that state only if, at matched aggregate inventory income, it reduces the cross-shape risk-adjusted-return spread by at least 25% without increasing the maximum per-trade charge at 100, 200, and 400 trades per market. Missing the spread threshold throughout selects flat; clearing the spread threshold while failing the charge-concentration condition is unresolved and keeps the configured rate at zero.

## Method

The experiment generated 240 books: three thicknesses, five clustering levels from fully dispersed to fully clustered, and 16 seeds. Within each thickness and seed, every clustering level reused identical quantities, widths, independent placement draws, and clustered placement draws; clustering changed only which placement each trade selected.

Charges used the implementation-shaped 100-bucket coordinate: each bucket represented 1% of probability mass, held the maximum payout over its 20 fine cells, and the coordinate subtracted fine-cell expected payout. Risk-adjusted return used true centered 95% expected shortfall over all 2,000 cells as its denominator.

The convex maximum marginal rate was 2% and its scale swept 0.10, 0.25, 0.50, 1.00, and 2.00 times median final grid capital at 50% clustering for each thickness. At every thickness and scale, the flat rate was fitted to collect the same aggregate inventory income as convexity across all clustering levels and seeds. Results therefore compare where an equal aggregate trader charge lands rather than comparing nominal rate labels.

## Result

The best spread reduction at every thickness occurred when the convex scale equaled median central-book grid capital.

- At 100 trades, baseline return spread was 6.99x, flat reduced it to 3.77x, and convex reduced it to 2.72x. Convex improved the spread 28.0% relative to flat, with paired-seed mean 28.0% and standard error 0.5%. Fully clustered return was 0.0212 under flat and 0.0245 under convex. The p95 charge was $19.19 under flat and $21.30 under convex; the maximum was $99.27 under flat and $173.56 under convex.
- At 200 trades, baseline return spread was 10.25x, flat reduced it to 5.25x, and convex reduced it to 3.81x. Convex improved the spread 27.4% relative to flat, with paired-seed mean 27.6% and standard error 0.3%. Fully clustered return was 0.0213 under flat and 0.0247 under convex. The p95 charge was $20.03 under flat and $22.02 under convex; the maximum was $162.45 under flat and $278.13 under convex.
- At 400 trades, baseline return spread was 12.61x, flat reduced it to 6.47x, and convex reduced it to 4.70x. Convex improved the spread 27.4% relative to flat, with paired-seed mean 27.5% and standard error 0.3%. Fully clustered return was 0.0210 under flat and 0.0244 under convex. The p95 charge was $21.14 under flat and $23.64 under convex; the maximum was $143.44 under flat and $207.19 under convex.

At those scales the matched flat rate was 1.144%, 1.168%, and 1.153% as thickness increased. Aggregate inventory income was 85.2%, 82.8%, and 80.8% of ordinary fee income.

## Decision

**UNRESOLVED.** Convexity clears the registered 25% materiality threshold consistently and with small paired-seed error, so the performance loss from flat charging is real: at the central 200-trade setting the return spread worsens from 3.81x to 5.25x and fully clustered return falls from 0.0247 to 0.0213. Convexity also raises the maximum individual charge at every tested thickness, failing the registered charge-concentration condition. P-32 remains open and the configured rate remains zero pending an explicit policy choice between simpler state and stronger compensation targeting.

## Limits

The flow is generated rather than production replay. The experiment covers opens only, assumes no behavioral response, uses equal-probability grid boundaries with no staleness, and evaluates real-valued arithmetic rather than Move rounding. Equal aggregate income does not equalize every trader-facing cost statistic; that difference is the measured trade-off. This run does not measure refresh gas, choose a rate, or decide whether the registered maximum-charge condition is the correct product constraint.
