# Asynchronous pool NAV valuation — problem summary and design history

This doc summarizes an open design problem in Predict's LP layer, what has been tried, and where the
implementation currently stands. It is written to be self-contained for readers outside the project;
we are looking for outside thoughts on the open questions at the end. Code: [PR #1120][pr-1120]
(current direction), [PR #1116][pr-1116] (earlier full design, kept as reference).

[pr-1120]: https://github.com/MystenLabs/deepbookv3/pull/1120
[pr-1116]: https://github.com/MystenLabs/deepbookv3/pull/1116

## The setting

Predict sells European cash-or-nothing range digitals on Sui. A single liquidity pool backs every
market: LPs supply cash to the pool, the pool allocates capital to per-expiry markets, and traders
mint and redeem digital contracts against those markets.

LP supply and withdrawal are asynchronous: requests queue, and a periodic privileged transaction —
the **flush** — values the whole pool and fills both queues at that NAV. One mark prices both
directions, so it has to be *accurate*, not merely conservatively bounded: an understated NAV mints
too many shares to new suppliers, an overstated NAV overpays withdrawals — either way incumbent LPs
lose value.

A market's NAV is its free cash minus the live liability of its order book, floored at zero. The
liability is exact: a full walk over the book's strike-exposure tree, pricing every live order at
the current oracle (spot/forward plus an implied-volatility surface).

## The problem

Today the flush is one atomic transaction. A hot potato snapshots the active market set; every
market must be visited exactly once (settled markets are swept and contribute zero, live markets are
walked at the live oracle); the finisher proves completeness and drains the queues. Sui bounds how
many objects one transaction may touch (~1,000 cached objects), and a single busy market's walk
measures close to that limit on its own. With several active markets the flush aborts — it is
aborting on testnet today.

So valuation must split across transactions: each market values itself independently (a
**refresh** that walks the book and stores the result), and the flush aggregates stored results,
reading markets immutably. That opens a **staleness window** between when a market was valued and
when the pool trades on that value. The requirements on the window:

- Markets keep trading inside it. Pausing mints between refresh and flush is not acceptable, so the
  flush must be able to consume marks dirtied by post-refresh activity.
- The operator driving refreshes and flushes gets tens of seconds of slack (30–90s target).
  Correctness must never depend on transactions landing close together in time.
- No interleaving of trades, refreshes, oracle updates, and the flush inside the window may let the
  pool be drained or systematically mispriced.
- Whatever error the window admits must be honest — bounded, priced, or visible; never silently
  absorbed by incumbent LPs.

## Why the window is hard

The staleness error has two independent sources with very different characters.

**Activity** — mints, redeems, and liquidations after the refresh. Discrete, on-chain, and exactly
knowable: every liability-changing operation computes its own exact effect on the book, so a stored
liability can in principle be kept exactly current. This axis is solvable exactly.

**Oracle movement** — the underlying and the vol surface move after the refresh. Continuous,
off-chain, and unknowable at flush time without re-walking the book. The instruments make this
axis brutal: digitals near expiry have effectively unbounded price sensitivity — an at-the-money
digital minutes from expiry can reprice by a large fraction of face on a tiny spot move. "This mark
is N seconds old" therefore carries no useful error bound by itself, and near-expiry marks are
*structurally* always stale.

## What has been tried

An earlier complete design ([PR #1116][pr-1116]) worked through this in four steps, and its core
piece was falsified by measurement:

1. **Stored liability marks plus exact write-through.** Refresh walks the book and stores the
   liability; every subsequent mint/redeem/liquidation applies its exact delta to the stored value.
   NAV at flush is live free cash minus stored liability. This handles the activity axis cleanly.
2. **A flush-time oracle drift guard.** Refresh stores its oracle inputs; the flush re-reads live
   feeds and rejects marks whose inputs moved too far. Scalar guards (forward move, variance-floor
   move) turned out to have blind spots: the vol surface can reshape in ways that reprice the book
   heavily while every scalar the guard watches stays still.
3. **A closed-form worst-case drift envelope.** Bound the whole book's repricing between two oracle
   snapshots by per-parameter Lipschitz charges over the surface's own parameters, and enforce an
   aggregate pool-level dollar budget. Replayed against days of real market data, the envelope
   failed in both directions: fixed-point quantization near expiry produced exact, confirmed
   violations of the "worst case", and away from those corners the bound was orders of magnitude
   looser than realized moves.
4. **Two-sided marks.** Charge the proven uncertainty as a NAV bid/ask: suppliers pay mid plus the
   drift bound, withdrawers receive mid minus it — the transactor bears the staleness, incumbents
   are protected in both directions, and the flush never has to reject anything. Sound and always
   live, but with bounds that wide the honest spread at tens-of-seconds mark ages on near-expiry
   books is measured in thousands of basis points. Safe, honest, unusable.

The general lesson we took: **worst-case bounds on digital repricing over tens of seconds are
either violable or too wide to trade against.** That failure is not a fixable bug in one particular
bound; near expiry, the products simply move too much per unit of oracle motion.

## Where we stand

We restarted from the smallest correct boundary ([PR #1120][pr-1120]) rather than keep patching the
full design. Current state, deliberately minimal:

- Each market stores a mark `{liability, computed_at_ms}` written by a refresh that runs the
  existing exact full walk.
- The flush reads markets immutably, keeps the per-market zero floor and the completeness proof, and
  currently accepts a mark only if it is under **3 seconds** old and the market has not reached
  expiry (settlement and cash rebalancing are standalone prerequisites, no longer part of the
  flush). The 3-second gate is an explicit placeholder: it bounds *age*, not economic error.
- Ownership boundary: the market maintains facts about its own valuation; the pool decides what is
  acceptable and aggregates. Acceptance policy lives entirely on the pool side.

The next planned increment is exact write-through for the activity axis (step 1 above, which
survived). The oracle axis is the open problem.

## Open questions — where we would value outside thoughts

- **How would you bound, estimate, or price oracle staleness for near-expiry digitals**, given that
  provable worst-case bounds fail as described? Directions we have considered but not built:
  first-order (delta/gamma) marks with some treatment of the unbounded remainder; sensitivity
  bucketing by moneyness; giving up on *proven* bounds in favor of *measured* statistical spreads
  calibrated per underlying and staleness.
- **Who should consume a drift estimate** — rejection (mark too drifty → refresh again and retry the
  flush) or pricing (two-sided NAV with the estimate as the spread)? Or is the right answer
  structural: near-expiry markets are the pathological case and settle shortly anyway, so exclude
  them from the pool mark by construction as expiry approaches?
- **Underwater markets** (liability exceeding the market's cash) occur legitimately under adverse
  moves. Flooring each market at zero discards that information; netting across the pool preserves
  it. Which aggregation is right for a mark that prices both supply and withdrawal?
- **Prior art.** The closest analogs we found: option-AMM net-greek caching with staleness gates,
  LMSR-style aggregate loss budgets, and mutual-fund swing pricing. What are we missing?
