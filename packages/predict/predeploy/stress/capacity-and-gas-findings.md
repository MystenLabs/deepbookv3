# Predict Capacity and Gas Findings

This is the consolidated capacity model for predeploy review. It incorporates
the 2026-06-28 localnet capacity audit plus the 2026-06-30/2026-07-01 harness
confirmations.

## Pinned Wall

The binding transaction wall is the Sui per-transaction computation cap:

- `max_gas_computation_bucket = 5,000,000` computation units
- at localnet/testnet reference gas price 1000, this is `5e9` MIST computation
  cost
- the work cap is network-independent; only the SUI cost changes with reference
  gas price

The flush and large batched trade PTBs are computation-bound. Increasing the gas
budget does not bypass this wall.

## Confirmed Findings

### 1. Full-pool NAV flush can OOG below current aggregate caps

The pool flush is one mandatory PTB:

```text
start_pool_valuation -> value_expiry for every active market -> finish_flush
```

`PoolValuation` is a hot potato, and `finish_flush` requires every snapshotted
active market to be valued. The operator can budget supply/withdraw queue drain,
but cannot budget valuation itself.

Pre-memo localnet `nav-stress` confirmed the original single-market failure:

- single-market flush OOGs around 4,580 leveraged orders in the cheap branch;
- last successful observed flush near that point used about 98% of the 5M
  computation-unit wall;
- this is below the current per-market cap of 5,000 leveraged orders;
- a `nav-stress-atm` run (moderate-moneyness strikes, 2026-07-01) OOGed around
  4,070 leveraged orders — only ~10% below the cheap branch, NOT the ~1,372 the
  earlier 100-config fuzz implied. Either the atm strategy is not reliably reaching
  the expensive `exp_series` branch or the moneyness premium is much smaller than
  that fuzz suggested; treat the ~1,372 worst case as UNCONFIRMED in-instrument
  until a run verifies the branch via the gas-by-moneyness buckets.

The landed NAV price memo changes the single-market result. It caches each priced
boundary during `walk_linear` and has the leveraged correction scan read from that
memo instead of re-pricing every order. Post-memo stress measured:

- one market at the 5,000 leveraged-order cap values successfully;
- full-book flush cost around 2.36-2.68B MIST, about 47-54% of the wall;
- single-market NAV computation no longer binds before
  `EMaxActiveLeveragedOrders`.

The pool-total case remains open. `batch-max-markets` reached about 8,640 total
leveraged orders across about 9 markets at roughly 4.60B MIST, then OOGed. That
run was entangled with `expiry_cash::EInsufficientCash`, so it is not the final
gas-only cap, but it is enough to show the current independent caps still do not
compose. At 24 active markets, even a much lower per-market book can exceed the
single-PTB wall.

Current independent caps do not compose:

| Cap | Current value |
| --- | --- |
| live expiry markets | 24 |
| payout-tree nodes per market | 1,000 |
| active leveraged orders per market | 5,000 |

The missing bound is a joint sum across all active markets, not another isolated
per-market cap.

### 2. Expired-unswept active markets are a separate liveness tail

The live-market creation cap does not by itself bound the active set processed
by the flush, because settled markets leave the active set only inside a
successful `value_expiry` / sweep path. If expired-unswept markets accumulate,
the flush must still process them.

Mitigations:

- add an out-of-flush settled deactivate/sweep path;
- bound total active markets, not only live markets;
- or document the operator cadence and retry requirement as an accepted
  off-chain liveness assumption.

### 3. Large batched trade PTBs do not scale like standalone ops

Standalone mints are cheap and mostly flat in normal one-op transactions. The
old "100-mint PTB costs 3-5B" observation was a batching artifact, not a
standalone mint-cost problem.

Harness experiments confirmed:

- a 100 leveraged-mint PTB costs about 3.4B MIST computation, roughly 68% of the
  cap;
- atomic ceiling is around 110-150 leveraged mints per PTB, data-dependent;
- the mechanism is transaction-level command-position / accumulated-state
  metering, not liquidation-book dirtying specifically;
- a leveraged mint appended after 20 1x mints, which do not write the liquidation
  book, is amplified similarly.

Normal one-op users are not affected. Routers, keepers, and integrators building
large atomic PTBs are affected.

## Cap-Setting Guidance

Use a single joint budget for the flush:

```text
sum_over_active_markets(node_count * c_node + leveraged_count * c_order + base_market_cost)
  + queue_drain_budget
  < safety_fraction * 5,000,000 units
```

Known measured terms:

- post-memo single-market pricing is no longer the bottleneck;
- the remaining per-market cost is the exact boundary walk plus liquidation-book
  iteration;
- pool-total valuation stacks that cost across every active market in one PTB;
- a safety target around 60% of the cap was used in prior analysis.

Approximate pre-memo example envelopes from the capacity audit:

| Max live markets | Max nodes/market | Max leveraged/market | Approx flush units |
| --- | --- | --- | --- |
| 1 | 1,000 | about 2,000 | about 2.84M |
| 10 | 200 | about 175 | about 2.76M |
| 24 | 100 | about 75 | about 2.92M |

These are not final parameter choices, and the memo improves the single-market
slope. They still show the shape: if the product keeps 24 active markets, the
per-market leveraged cap must be set from a measured pool-total envelope unless
the flush becomes resumable.

## Fix Options

1. Tighten caps to a measured single-PTB joint envelope.
2. Make the flush resumable across PTBs by persisting partial valuation state.
3. Add an out-of-flush settled-market sweep/deactivate path to bound the active
   tail.
4. Keep the current shape only if the operator runbook explicitly throttles
   market creation and book size below the measured wall; this is an off-chain
   acceptance, not an on-chain guarantee.

## Required Follow-Up Runs

- Full `nav-stress-atm` run that verifies (via the gas-by-moneyness buckets) it
  actually reaches the expensive `exp_series` branch — the 2026-07-01 run OOGed at
  ~4,070, which does not confirm the expensive-branch worst case.
- Clean gas-only pool-total capacity across many markets, e.g. via
  `batch-max-markets` (fast
  batched fill). Size the pool with LP supply first, so `expiry_cash`'s
  `EInsufficientCash` (pool capital) does not bound the book before the flush gas
  does — otherwise the measured OOG is entangled with a capital limit.
- Any final cap change should be followed by a stress run that reaches the new
  boundary and proves the flush remains below the safety target.

See `price-memo-findings-2026-07-01.md` for the single-market post-memo evidence
and the entangled multi-market run.
