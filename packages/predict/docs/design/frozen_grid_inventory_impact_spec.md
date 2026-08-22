# Frozen-grid inventory impact — review specification

> **Status:** Prototype implementation under review; the configured production rate remains zero. [P-32](../../predeploy/open-items.md#p-32-implement-frozen-grid-inventory-impact) owns implementation evidence and resolution.

## Objective

Inventory impact compensates PLPs for marginal bad-tail exposure that fair contract pricing and the ordinary spread do not already cover. It must charge the transition that creates the exposure, avoid charging a transition merely because gross payout liability rose, and be a deterministic function of the payout book under one snapshot so the same transition always costs the same.

[The inventory-impact reference](inventory_impact_reference.md) owns the economic argument and the measured value of the mechanism. This document owns the implementation contract: state, transition rules, invariants, and what must be true before a nonzero rate ships.

The design uses exactly one inventory-risk coordinate and one potential. It replaces `L` only as the input to inventory impact; the existing payout-liability formula remains unchanged for cash backing and early-redemption liquidity.

## Coordinate

Each market stores 100 immutable settlement-price buckets representing consecutive 1% probability slices under one authenticated pricing snapshot. For bucket `i`, the market tracks `P_i`, the maximum net payout attainable anywhere inside that bucket. Separately, the market tracks `E_frozen`, the additive expected net payout of the actual order ranges under that same frozen snapshot.

The frozen-grid economic-capital coordinate is

```text
K95_grid = average(top 5 bucket range-max payouts) - E_frozen
```

The first term is the conservative average payout in the worst 5% of frozen outcomes. The second removes expected settlement value already owned by contract pricing. `E_frozen` is updated from each order's signed net payout multiplied by the order range's actual probability under the frozen snapshot; it is not the average of bucket range maxima.

The subtraction is economically required because traders deliver contract value to the pool when positions open. If the book pays $1,000 in every possible bucket and the pool collected approximately $1,000 selling that complete coverage, its settlement result has no uncertainty: the top-five payout and `E_frozen` are both $1,000, so the coordinate is zero. A gross-payout coordinate would mistake fully funded size for risk.

Historical cash collected is not used directly because it depends on entry path, live oracle state, spread, and fee components. Two identical payout books could then carry different inventory potentials. Frozen expected payout values every order under one probability snapshot, preserving a book-state potential; residual approximation belongs in `B_K` and `r_K` calibration.

Bucket payout uses the payout tree's range maximum rather than a representative point. A narrow payout spike therefore raises its bucket's value instead of hiding between samples. This deliberately treats a spike as occupying its complete 1% bucket, a bounded conservative approximation.

Range maxima must not feed the centering term. If a narrow non-tail spike raised both one bucket maximum and the average of all bucket maxima, it could lower measured capital without entering the top five; repeated spikes could accumulate that discount before a later pile-on. Centering on actual frozen range probability removes that channel while retaining conservative range maxima only where conservatism is intended: the bad-tail term.

## Market initialization

Before trading is enabled, an authenticated initializer supplies the 99 interior quantile boundaries as `strike / forward` ratios, 1e9-scaled, together with a valid live pricer bound to that market. The contract supplies the two open-end sentinels itself, multiplies each ratio by the forward that pricer resolved, snapshots the SVI shape, independently evaluates the CDF at every rematerialized boundary, and rejects initialization unless every adjacent bucket has probability mass within one basis point of the 1% target: each mass must lie in `[0.99%, 1.01%]`. The stored pointer is the ratios, not the raw-price ladder.

Boundaries are supplied relative to the forward rather than as absolute prices because pricing reads a strike only as `ln(strike) - ln(forward)`. A bucket's mass is therefore a function of the ratios alone, and a caller's ladder verifies identically no matter where the forward moved between pricing it off-chain and the transaction executing. An equal-mass bucket is only a couple of basis points of the forward wide, so an absolute ladder loses that race against spot within a second and most cuts would abort the mass check.

Every later quote rematerializes `boundary_i = ratio_i × F_live` against the frozen SVI shape. Live oracle updates continue to price trades and drive ordinary fees, admission, valuation, and settlement; they also slide the dollar rungs so ATM stays in the body after a spot jump. There is no keeper refresh: the same stored ratios are the pointer for the market's life. Time-decay of the smile can still unbalance rung masses on long markets; that is a shape-stickiness question, not a spot-cut question.

The cell lattice is absolute log-price, fixed at initialize and sized past the 1%–99% creation span so moderate drift still has resolution. A quote that leaves the lattice is absorbed by the open-end cells.

## Rolling bucket state

The market stores the 100 current bucket maxima and the current `E_frozen`. It does not store only the current top five because a close can lower a top bucket and require the prior sixth-highest bucket to enter the tail.

For a proposed range transition:

- buckets outside the range remain unchanged;
- every bucket fully covered by the range changes by exactly the order's signed net payout;
- at most two boundary buckets are only partially covered and use existing payout-tree range-max queries to calculate their prospective maxima; each raw-price bucket is snapped outward to the payout-tree interval containing every reachable payout state, so no within-bucket spike is omitted;
- `E_frozen` changes by the signed net payout multiplied by the range probability computed from the immutable frozen CDF; and
- a fixed-size scan selects the five largest prospective maxima without sorting the payout tree.

The quote computes `K_before` from stored bucket state and `K_after` from the prospective updates. If the trade executes, the payout tree and bucket state commit atomically. A broad range may update all 100 array entries, but only the two partially covered boundary buckets require nontrivial tree queries.

## One capped potential

The coordinate feeds D032's single capped convex potential:

```text
Psi(book) = Phi[r_K, B_K](K95_grid(book))
```

`r_K` is the configured maximum marginal inventory-impact rate and `B_K` is the stable scale expressed in frozen-grid economic-capital units. The old `B = max_expiry_allocation` was selected for `L`-scale liability and must not be reused by default: changing the scale changes where the marginal rate reaches its cap, not merely the overall fee level. `B_K` must be re-derived from stressed `K95_grid` capacity and the desired curvature, then `r_K` calibrated separately. The exact integer evaluation order, rounding direction, cap, configuration snapshot, and zero-rate kill switch follow the same discipline as the current potential.

There is no additional `L`-based inventory fee. Lockup-rent compensation and the cost of frozen-grid approximation are absorbed into calibration of this single rate.

## Transition rules

Every live transition evaluates the same before/after potential regardless of whether the transition is called a mint or a close.

```text
charge = max(0, Psi_after - Psi_before)
```

- A transition that raises the potential pays the complete positive difference at execution, whether it is a mint or a close that removes a hedge.
- A transition that lowers the potential pays nothing and receives nothing. There is no rebate, no per-position refund credit, and no escrow.
- The charge is ordinary expiry cash on arrival. It counts in NAV, and settlement has no inventory-impact step.

Because a decrease pays nothing back, charges are path-dependent in the pool's favour only. Slicing one risk-increasing transition collects exactly the combined charge, since the intermediate potentials telescope. A path that lowers `K` and raises it again collects more than the direct transition, never less.

The opening charge is never multiplied by remaining time, because the coordinate already carries the decay: `E_frozen` is marked to the snapshot's probabilities, so `K` falls on its own once an outcome becomes decided and holds its full value while the outcome stays a coin flip. A multiplier would double-count the first case and wrongly discount the second.

## Invariants

- **Single charge:** one frozen-grid potential replaces the inventory-impact use of `L`; takers are never charged both.
- **Ratio pointer:** stored rungs are `strike / forward`; dollar boundaries are `ratio × F_live` at quote time and are not re-cut by a later keeper transaction.
- **Verified grid:** the contract, not the caller, verifies every bucket's probability mass against the 1% target and one-basis-point tolerance at initialization.
- **No refresh:** bucket maxima are derived from the cell mirror on demand, so there is no stored rolling summary that a re-cut could leave stale.
- **Spike-proof centering:** only actual frozen range probability contributes to `E_frozen`; conservative bucket maxima never enter the mean.
- **Determinism:** identical payout book, bucket snapshot, and configuration produce an identical integer charge.
- **Backing separation:** payout liability `L` continues to secure settlement and early-redemption liquidity independently of the fee coordinate.
- **No refund:** no flow returns an inventory-impact charge to any account. A transition that lowers the potential is free.
- **Split resistance:** slicing one risk-increasing transition collects the same total as executing it whole, and no path collects less than the direct transition.
- **No spike hiding:** any payout increase inside a bucket can affect that bucket through range-max evaluation.
- **Integer discipline:** top-five selection, frozen expected-payout updates, averages, and potential evaluation have fixed rounding rules and overflow bounds. Expected payout is a centering subtrahend only: a quote re-integrates the cell mirror under the live-forward view, and closes subtract saturating so residual dust can only raise `K` (see [RP-29](../../predeploy/response-policies.md)).
- **Zero-rate safety:** a zero inventory-impact rate preserves the existing disabled behavior without unnecessary grid work on trading paths.

## Design rationale

The fee coordinate measures centered bad-tail exposure across the frozen market distribution, so it distinguishes diversification, broad tail accumulation, and thin probability wings without coupling inventory compensation to the liquidity buffer used for backing.

The coordinate and rate have separate responsibilities. `K95_grid` determines which transition creates capital exposure; `r_K` and `B_K` determine the strength and curvature of compensation. Calibration must use measured PLP compensation shortfall and observed demand.

The stored ratios keep the potential on one SVI shape, while the live forward slides the dollar rungs so the charge is a function of the book in moneyness rather than of which creation-time tick it lands on. Dropping the refund removes the custody surface entirely: with no outflow there is nothing to over-claim, no cross-position subsidy to bound, and no escrow to keep covered.

## Acceptance before enabling a nonzero rate

- Grid initialization is authenticated and independently verifies each bucket on-chain within the fixed one-basis-point mass tolerance; initialization is required before trading.
- Prospective bucket updates match full recomputation across narrow, broad, open-ended, overlapping, partial-close, and cross-bucket transitions.
- Top-five and `E_frozen` arithmetic match an independent reference under all tie and rounding cases.
- Repeated narrow spikes outside the top five cannot lower `K95_grid` beyond their actual frozen expected-payout contribution.
- Risk-increasing closes charge successfully; risk-reducing transitions are free and return nothing.
- Slicing a risk-increasing transition into any number of pieces collects the same total, and no ordering collects less than the direct transition.
- A book that pays the same amount at every settlement price scores no capital, and placing away from the book's peak costs less than piling onto it.
- Payout liability and cash-backing behavior are unchanged.
- The trading path remains within the accepted gas, object-access, and object-size envelopes at 100 buckets and the maximum payout-tree size.
- The quote rematerializes the ratio ladder and reads the inline cell mirror; it does not walk the payout tree.
- `B_K` is derived in frozen-grid capital units and is not inherited from the old liability coordinate without evidence.
- `r_K` remains zero until calibration and implementation evidence satisfy P-32's resolution requirements.
