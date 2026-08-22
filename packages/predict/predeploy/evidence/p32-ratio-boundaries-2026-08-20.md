# P-32 forward-relative grid boundaries, 2026-08-20

**Item:** P-32

**Revision:** `8277c28cf29ae7160470ba25d140e28b5163fd3f` plus the uncommitted frozen-grid implementation and the ratio boundary interface this record measures.

**Instrument:** the contract-faithful fixed-point mirror in `simulations/python_replay.py`, scored over the captured oracle snapshot from the `capacity-tree-aug20-154939-53024` instance, plus two paired Move tests in `tests/strike_exposure/inventory_impact_tests.move`.

**Supersedes:** the "off-chain boundaries are not operable against a live pricer" conclusion in `p32-refresh-gas-2026-08-20.md`. That record's measurement stands as taken; the absolute-price interface it measured no longer exists.

## Question

The earlier run found that supplying absolute equal-mass boundaries from off-chain aborts `EInvalidBucketMass` for most cuts, because the check leaves roughly 0.25 basis points of spot drift between the generator's snapshot and the observation the contract prices against. Does expressing the boundaries relative to the forward remove that race, and what error remains if it does?

## Why it should

`pricing::compute_nd2` forms log-moneyness as `k = math::ln(strike).sub(ln_forward)` and every term after it — the SVI total variance, `d2`, the slope correction — is a function of `k` and the SVI parameters alone. A boundary's probability therefore depends on the strike only through its ratio to the forward. Fix the ratios and a forward move cannot change any bucket's mass.

## Method

The generator's absolute ladder for the longest-dated expiry in the captured snapshot (2.75 hours out, forward $72,668.11) was converted to 1e9-scaled ratios against the forward the contract's own integer arithmetic resolves. Both ladders were then scored under the fixed-point mirror at a drifted spot: the absolute ladder as-is, and the ratio ladder re-materialized against the drifted forward the way `inventory_grid::materialized_ladder` does. Tolerance is 100,000 against a 10,000,000 target.

## Result: spot drift stops mattering

| Spot drift | Move on the forward | Absolute: buckets outside tolerance | Ratio: worst error | Ratio: buckets outside tolerance |
| --- | --- | --- | --- | --- |
| 0 | $0 | 0 | 108 | 0 |
| 0.25 bp | $1.82 | 1 | 181 | 0 |
| 1 bp | $7.27 | 47 | 143 | 0 |
| 5 bp | $36.33 | 89 | 188 | 0 |
| 50 bp | $363.34 | 99 | 149 | 0 |
| 250 bp | $1,816.70 | 100 | 160 | 0 |

The ratio ladder's error stays between 108 and 196 at every drift tested, which is the fixed-point residue of the ratio round trip rather than a function of drift. It does not grow with the move, and there is no drift at which a bucket leaves tolerance.

## Result: the remaining budget is time, and it is tens of seconds

With ratios, the only surviving error source is the SVI roll-down between the generator pricing the surface and the transaction executing. Holding the ladder fixed and advancing the pricing timestamp on the same market:

| Submission delay | Worst bucket error | Verdict |
| --- | --- | --- |
| 0 | 120 | passes |
| 1 s | 3,340 | passes |
| 5 s | 16,537 | passes |
| 10 s | 33,034 | passes |
| 30 s | 98,901 | passes |
| 60 s | 197,348 | 4 buckets outside tolerance |

The error grows about 3,300 per second, so the cut has roughly 30 seconds of budget on this market. Repeating each delay at 0, 10, and 50 basis points of drift changes the worst error by less than 20 units, so the two error sources are independent and drift contributes nothing.

The operational consequence is a change of regime rather than a wider margin: the old budget was a quarter of a basis point of spot, which is gone in well under a second and cannot be met by submitting faster, and the new one is tens of seconds of wall clock on a keeper that already runs a per-tick loop.

## Pinning tests

- `one_ratio_ladder_stays_valid_after_the_forward_moves` initializes a grid, moves the resolved forward 1% by republishing the Block Scholes forward under an unchanged clock, and refreshes with the identical ratios.
- `the_same_move_invalidates_a_ladder_of_absolute_prices` rescales those ratios so they materialize back to the pre-move absolute prices and asserts `EInvalidBucketMass`. Without it the first test would pass on a mass check that never had teeth.

## Limits

The far-market budget above is measured on one 2.75-hour surface. Roll-down error scales with how fast remaining time is shrinking, so shorter cadences have proportionally less time budget; this record does not establish where the shortest workable cadence sits, and the grid lane's two-hour restriction is unchanged. The measurement is a fixed-point replay of a captured surface, not a live campaign, and no campaign has yet been re-run against the ratio interface. Nothing here bears on the object-runtime cached-objects ceiling from the superseded record, which remains the binding constraint on refreshing a market at its maximum tree size.
