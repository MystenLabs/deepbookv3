# On-chain quote calibration — the adverse-flow calibrator (DBU-733)

> **Status:** design, not implemented and not scheduled. The
> [quote calibration plan](./quote-calibration-plan.md) describes what is being
> built: a correction table measured off-chain and published by a permissioned
> keeper. This document describes a successor that derives the same table from
> settled outcomes on-chain and removes the keeper. It reuses the applying half
> of that design unchanged and replaces only the source of the numbers.

## Setting

Predict quotes a binary market by pushing a vendor implied-variance surface
through a fixed formula; the quoted UP probability at a strike is a pure
function of that surface and the market's remaining time
(`sources/pricing/pricing.move`, and
[pricing-and-oracles](../concepts/pricing-and-oracles.md)). Because a quote is a
model output and settlement is an observed fact, the two can be compared: for
any strike the market either settled above it or it did not, and across many
settled markets the realized frequency of settling above a strike can be set
against the probability that was quoted for it.

The [quote calibration plan](./quote-calibration-plan.md) adds a correction
table that closes a measured gap between the two. The table is a map from quoted
probability to corrected probability, on a grid of remaining-time keys and
probability knots, applied inside `up_price` after the formula runs. That half
of the design — the grid, the interpolation law, the clamp, the staleness
window, the kill switch, and the single application point — is settled and is
not revisited here.

What is unsettled is where the numbers come from. In the plan, an off-chain
keeper measures the gap and publishes a table under a capability that admin
mints and revokes. The keeper is therefore a trusted writer on the pricing path:
within the bounds the protocol enforces, whatever it publishes is what the
protocol quotes.

This document specifies the alternative. The protocol accumulates the same
measurement itself, as markets settle, and derives the table from its own state
by a rule fixed in the package. There is no writer to trust because there is no
writer: the derivation is a pure function of accumulated counts, so any caller
produces the same table, and the capability, the allowlist, and the publication
entrypoint are all deleted.

The mechanism is named for what supplies its signal. Traders who believe a quote
is wrong trade against it; when they are right, the outcome records that the
quote was wrong, and in which direction. The calibrator reads the flow that
selects against mispriced quotes and moves the quoting function toward the
prices that flow implies.

## Why the derivation can move on-chain

Three properties of the existing code decide this, and none of them were added
for it.

**The outcome of a quote is a pure comparison.** A settled position's payout is
`order.quantity()` when the settled price lies in the position's tick range and
zero otherwise (`strike_exposure::settled_order_payout`, via
`range_codec::settlement_in_range`). It depends on the two ticks, the settlement
price, and the tick size — nothing else. So once a market settles, the protocol
can score any quote it recorded, immediately, without the position being
redeemed and without consulting the payout tree.

**The corrected quantity is the digital.** The correction applies to the UP
probability at a single strike, because `up_price` is the one point both public
reads funnel through and `range_price` is the difference of two of its results.
The calibrator therefore measures digitals, which is simply measuring the
function at the level the function emits. Measuring range outcomes instead would
fit a map on range probabilities and then apply it to digital ones.

**The outcome decomposes exactly as the price does.** `settlement_in_range` is
`lower_tick < limit && (higher_tick == pos_inf || limit <= higher_tick)`, where
`limit` is the settled price expressed as a tick. That is the difference of two
one-sided indicators, exactly as a range price is the difference of two
digitals. Prices and outcomes therefore decompose along the same axis, so
calibrating digitals calibrates ranges exactly rather than approximately.

What the chain cannot do is read its own history. Move has no access to past
events, so a table cannot be derived retrospectively from what the protocol
emitted; the measurement has to be accumulated as it happens. That constraint,
not the arithmetic, is what shapes the rest of this design.

## What gets sampled

At mint, the protocol records the model's predicted UP probability at the
order's strike edges, together with the tick each was taken at. An order with
two finite edges contributes two observations, at two different points on the
probability curve. Infinite edges are skipped: `up_price` returns exactly one at
`neg_inf` and zero at `pos_inf`, so those carry no information and consume no
slot. A one-sided bet therefore contributes one observation.

Sampling is a census of cells, not of orders. Each market holds at most one
observation per grid cell — one remaining-time key crossed with one probability
knot — and a mint fills a cell only if it is empty. Three things follow:

- **State and work are bounded by the grid, not by volume.** A market holds at
  most 209 records regardless of how much trades through it, and in practice far
  fewer, because most cells never see an order.
- **Flooding buys nothing.** An observation carries one unit of weight
  independent of its size, and a cell admits one observation per market, so
  wash-trading a cell cannot outweigh honest observations in it.
- **Settlement work is bounded.** Scoring a settled market walks a fixed maximum
  number of records rather than its order book.

The per-market buffer hangs off the market's `UID` as a dynamic field. Adding a
field to `ExpiryMarket` would change a struct layout that already exists
on-chain, which a package upgrade cannot do.

## What a range order says

A range mint is two digital positions in opposite directions: buying `[L, H]` is
buying the digital at `L` and selling the digital at `H`. A trader who takes it
is asserting that `up(L)` is too low **and** that `up(H)` is too high.

The choice of shape is itself informative. If only the lower edge were
mispriced, selling the upper leg would be expected-value neutral, and with fees
it is expected-value negative; the trader would buy the one-sided `[L, inf)`
instead. Adding the second leg pays only if the second leg is also wrong in
their favour. So a range order carries evidence about two points on the curve,
and a one-sided order carries evidence about one.

Worked through: suppose the model quotes `up(90k) = 0.70` and `up(100k) = 0.20`,
so the range `[90k, 100k]` prices at 50c. A trader who believes those should be
0.80 and 0.15 values the range at 65c and buys it. The market settles at 96k:

| Digital | Quoted | Settled 96k | Observation | Direction |
| --- | --- | --- | --- | --- |
| 90k | 0.70 | above | resolves yes | pushes 0.70 up |
| 100k | 0.20 | below | resolves no | pushes 0.20 down |

Both corrections the position implied, at the two points it implied them, in
opposite directions. The DOWN sides follow with no extra machinery, since
`down(K)` is the range `[-inf, K]` and `up_price` returns exactly one at
`neg_inf`, making `down(K) = 1 - up(K)` exactly.

This is also what keeps the sample two-sided. Every range order feeds a
resolves-yes observation to one cell and a resolves-no observation to another,
so a book of range orders cannot be one-sided in the coordinate the calibrator
measures, whatever direction its traders believe they are taking.

## Scoring at settlement

When a market settles, each recorded observation is scored against the settled
price by the same one-sided comparison the payout uses — the digital resolved
yes when its tick is below the settled price expressed as a tick — and folded
into a per-underlying accumulator shared by every market on that underlying.

The accumulator holds two values per cell: a count of observations and a count
of yes-resolutions, both decayed so that recent settlements weigh more than old
ones. Decay is exponential and applied on write, matching the smoothing the
protocol already uses for its gas-price penalty
(`sources/config/ewma_config.move`), which makes the rolling window two numbers
per cell with no eviction pass and no history to store.

The accumulator is a flat vector inside one object rather than a dynamic-field
table. Scoring a market touches many cells in one transaction, and a table would
turn each into a separate dynamic-field access; a vector makes them updates to
one loaded object.

One consequence of exponential decay is worth stating: it weighs observations,
not elapsed time, so a thinly-traded cell retains its history longer in
wall-clock terms than a busy one. Decaying in time instead requires raising the
decay factor to a time-dependent power, which is affordable by repeated squaring
over a coarse tick but is not free.

## From counts to a table

A cell's corrected probability is its knot probability and its observed
frequency, blended by how much has been observed:

```
m(p) = (W * p + yes_count) / (W + count)
```

`W` is a fixed prior weight in units of observations. At zero observations the
cell is exactly the identity, so an unmeasured cell corrects nothing. As
observations accumulate the cell moves toward its realized frequency, and `W`
sets how much evidence a move requires.

That is what separates a persistent error in the quoting function from a trader
who was merely right once. A single yes at a 0.70 quote is one draw from a
0.70 coin, not evidence; only a frequency that persists across many markets
moves a cell far. `W` is therefore the parameter that decides how much informed
flow it takes to move a price, and it is the main defence against a trader
manufacturing a correction.

Cells accumulate independently, so adjacent knots can cross. A monotone repair
pass over the 19 knots restores the non-decreasing order the applying half
requires, before the row is stored. `range_price` flooring at zero remains as a
second layer.

Recomputing is a permissionless entrypoint. It reads the accumulator, applies
the blend and the repair, and writes the resulting table into the same
`ProtocolConfig` slot the plan's keeper would have published to. Any caller
produces the same table from the same state, so the entrypoint needs no
capability and grants no discretion.

## Why it converges

The mechanism is a feedback loop, and it is worth showing that the loop is
negative rather than assuming it.

Take one cell — the model quotes 0.30 at some remaining time — and suppose the
model is right on average but cannot distinguish two situations it treats
alike: in a third of markets the true probability is 0.45, and in the rest it is
0.225, averaging to 0.30. Suppose traders act whenever their edge beats a 5c
fee. The correction the calibrator settles on is the one where what gets traded
resolves at the rate being quoted:

| Correction | 0.45 markets | 0.225 markets | Sampled | Reads | Moves |
| --- | --- | --- | --- | --- | --- |
| 0.45 | edge 0 — untraded | edge 22.5c — traded | the 0.225 markets | 0.225 | down |
| 0.35 | edge 10c — traded | edge 12.5c — traded | both | 0.30 | toward 0.30 |
| **0.30** | edge 15c — traded | edge 7.5c — traded | both | **0.30** | **stable** |
| 0.225 | edge 22.5c — traded | edge 0 — untraded | the 0.45 markets | 0.45 | up |

Above the truth the correction makes the other side cheap, that side gets
traded, and the observations pull the correction back down; below it the
reverse. The true unconditional probability is the unique resting point. This is
an illustration of the loop's sign, not a proof of convergence for every
distribution.

The property doing the work is that the corrective side is *reachable*. A
correction that moves a digital in one direction necessarily makes the opposite
position cheaper by construction, since the two sides sum to one, and a range
order shorts a digital as readily as it buys one. Whenever both sides can be
traded, an overshoot in either direction pays whoever corrects it.

## Where it fails

**Cells that receive genuinely one-sided flow.** If a cell can only ever be
bought in one direction, the corrective observation never arrives and the
correction runs to whatever level makes the remaining edge equal to fees, where
it sticks. This is the failure mode to guard against, and it is a property of
what the product makes tradeable rather than of the calibrator: it is closed by
making the opposite position as reachable as the first one, not by changing the
estimator.

**Loop lag.** Observations reach the accumulator only when a market settles, and
the decay smooths them further, so the correction responds to outcomes that are
already old. Negative feedback with delay overshoots when its gain is too high.
The decay factor and `W` set that gain, and they need simulating against a
realistic settlement rate rather than choosing.

**Sampling time within a key.** A caller who could choose when inside a
remaining-time bucket an observation is taken could prefer moments when the
quoting inputs are least fresh. One observation per market per cell bounds what
that is worth, and the prior weight damps it further, but it is not fully
closed.

The calibrator does not attempt to defend against traders whose edge is speed
rather than a standing error in the quoting function. A correction is a level;
it cannot answer a counterparty who chooses when to trade, because shifting a
level relocates the deviations it is exploiting rather than removing them. That
exposure belongs to the fee and inventory-impact layers
([fees-and-rebates](../concepts/fees-and-rebates.md)), which charge per trade.
The calibrator's job is confined to the standing accuracy of the quoting
function.

## What holds by construction

- **Bounded movement.** The clamp is unchanged and still applied when a quote is
  priced, so `|m(p) - p| <= max_deviation` at every probability and every
  remaining time, for any table the derivation can produce. The bound does not
  depend on the derivation being correct.
- **Monotonicity.** The repair pass makes each stored row non-decreasing, and
  the interpolation and clamp preserve that, so `up_price` stays non-increasing
  in strike and `strike_payout_tree::ENonMonotonePrice` continues to hold.
- **Total probability.** The endpoints `m(0) = 0` and `m(1) = 1` remain implicit
  and unstored, so a partition of the strike line still sums to one.
- **Fail-safe.** An empty accumulator yields the identity through the blend
  rather than through a special case, so a fresh underlying quotes exactly as it
  does today. The switch, the staleness window, and the absent-table path are
  unchanged and still resolve to the uncorrected formula output.
- **No privileged writer.** The table is a pure function of accumulated state,
  so every caller of the recompute entrypoint produces the same table. There is
  no publication a caller can bias and therefore no capability to hold.

## What it replaces, and what it leaves alone

Removed: `QuoteCalibrationCap`, its `Registry` allowlist, the mint and revoke
entrypoints, `registry::publish_quote_calibration`, and the tests and trust
argument attached to them. The keeper service the plan describes is not built.

Unchanged: the grid, the interpolation law, the clamp, `staleness_ms`, the
`enabled` switch, the `Pricer` field, the single application point in
`up_price`, and every property the plan's construction section establishes about
them. `max_deviation` remains a bound on a wrong table, which matters more here
rather than less, since the derivation has no operator to catch an implausible
result before it is stored.

Added on the hot paths: one bounded check and an occasional write at mint, and a
bounded walk plus one accumulator update at settlement. Both are new work on
paths that already exist, which is why the measurements below come before the
implementation.

## What must be measured first

Each of these can change the design, and all are answerable before any Move is
written.

- **Mint cost.** Mint is the most latency- and cost-sensitive path in the
  protocol. The added check and conditional write must be measured there, not
  estimated.
- **Settlement cost at a full buffer.** Scoring a market with every cell
  occupied is the worst case. If it does not fit alongside the work settlement
  already does, the walk has to be chunked, which interacts with how a valuation
  is sequenced.
- **Sample adequacy.** How long a cell takes to reach a count where the blend
  moves it meaningfully, per underlying, at realistic market cadence and order
  mix. If cells fill too slowly to track a drifting error, the mechanism does
  not do its job however sound it is.
- **Loop damping.** The decay factor and `W` simulated against a realistic
  settlement rate, checking for overshoot and oscillation, before either is
  fixed as a constant.
- **Two-sidedness.** Per cell, whether the corrective side is actually traded in
  practice. This decides whether the convergence argument above holds for this
  book, and it is the single measurement the design most depends on.
