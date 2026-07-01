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

### 1. Full-pool NAV flush can OOG below current caps

The pool flush is one mandatory PTB:

```text
start_pool_valuation -> value_expiry for every active market -> finish_flush
```

`PoolValuation` is a hot potato, and `finish_flush` requires every snapshotted
active market to be valued. The operator can budget supply/withdraw queue drain,
but cannot budget valuation itself.

Localnet `nav-stress` confirmed:

- single-market flush OOGs around 4,580 leveraged orders in the cheap branch;
- last successful observed flush near that point used about 98% of the 5M
  computation-unit wall;
- this is below the current per-market cap of 5,000 leveraged orders;
- worst-case moneyness can be materially lower and still needs a full run.

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

- payout tree node walk is not the bottleneck;
- leveraged-order correction dominates;
- a safety target around 60% of the cap was used in prior analysis.

Approximate example envelopes from the capacity audit:

| Max live markets | Max nodes/market | Max leveraged/market | Approx flush units |
| --- | --- | --- | --- |
| 1 | 1,000 | about 2,000 | about 2.84M |
| 10 | 200 | about 175 | about 2.76M |
| 24 | 100 | about 75 | about 2.92M |

These are not final parameter choices. They show the shape: if the product keeps
24 active markets, the per-market leveraged cap must be far below 5,000 unless
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

- Full `nav-stress-atm` run targeting the expensive `normal_cdf` branch.
- Full `nav-stress-multi` run measuring pool-total capacity across many markets.
- Any final cap change should be followed by a stress run that reaches the new
  boundary and proves the flush remains below the safety target.
