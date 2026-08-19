# Flush aborts on a stale active-market list — testnet, 2026-07-30

**Item:** RP-31 · **Instrument:** live testnet observation (`predict-6-24`) · **Date:** 2026-07-30

Status: reproduced failure, observed on chain. The full-pool flush aborts when the
market list it was built from no longer matches the active set the flush snapshots at
execution. This is a race between an off-chain read and on-chain state, not a pool
condition — no book size, oracle state, or capital level is involved.

## The observation

A failed flush transaction on testnet:

```
digest   GNSardn95EJRcuwKEqvKqx8JbnFYYkN86V3mxb6upmjt
package  0xdb3ef5a5129920e59c9b2ae25a77eddb48acd0e1c6307b97073f0e076016446e
status   failure
abort    MoveAbort(plp::assert_expiry_ready_to_value, 0) in command 9
```

Abort code `0` in `plp` is `EExpiryMarketNotActive`, and it is the first assertion in
`assert_expiry_ready_to_value`. Note it does not uniquely identify the sweep race: on
the deployed build the set-membership check runs *before* the registration check, so an
unregistered or wrong-vault market id lands on the same code. A double-value would raise
`EExpiryMarketAlreadyValued` (1), so that alternative is excluded, but attributing this
specifically to a sweep rests on the surrounding operational sequence rather than on the
code alone.

```move
assert!(valuation.expected_expiry_markets.contains(&expiry_market_id), EExpiryMarketNotActive);
```

The transaction shape is the deployed single-PTB flush — `generate_lifecycle_proof` →
`start_pool_valuation` → `value_expiry` × N. The abort at command 9 means one of the
`value_expiry` calls named a market that was absent from the set
`start_pool_valuation` had snapshotted three commands earlier in the same transaction.

Rate: roughly **13 failures over 3 hours** on one operator, reported alongside this
digest. At a ten-minute flush interval with no fast retry on this abort, that is ~18
attempts, so **~5 flushes still landed in the window** — the LP queues drained roughly
every 35 minutes rather than not at all.

The rate is not stable, and that matters for diagnosis. An earlier occurrence on
2026-07-07 ran at roughly 1-in-8 attempts, with flushes demonstrably landing between
aborts. A fixed race probability does not move ~6x on its own, so something
environmental — active-market count, transaction latency, fullnode read lag — drives the
rate. Treat this as an intermittent liveness degradation whose severity varies, not a
standing outage.

## Mechanism

`start_pool_valuation` snapshots `expiry_accounting.active_expiry_markets()` when the
transaction **executes**. The list of markets to value has to be chosen when the
transaction is **built**, because each one is a separate command with its own object
argument. Any sweep in between invalidates the built list.

A sweep is `deactivate_expiry_if_present`, reachable from:

- `value_expiry`, inside a flush, and
- `rebalance_expiry_cash`, which is **permissionless and standalone** — an operator's
  own settlement path calls it after `try_settle`, and so may anyone else.

So the ordinary market roll produces the race: settle an expired market, sweep it, and
any flush already built against the pre-sweep list aborts. Nothing adversarial is
required, and no participant is misbehaving.

The window is not merely stumbled into, which is why the rate can be so high. A caller
that defers its flush while a market is expired-unsettled, and resumes as soon as that
clears, is *scheduling itself* into the seconds immediately after the settle-and-sweep
transaction — precisely when a read can still return pre-transaction shared-object
state. Caller-side scheduling therefore amplifies the race well above its floor; the
contract change removes the failure regardless of scheduling, but a caller that reads
its market set immediately after sweeping will still be reading a stale set for other
purposes.

Note the registered-expiry row survives a sweep (`deactivate_expiry_if_present` only
removes from `active_expiry_markets`), so `assert_registered_expiry` still passes and
the abort lands specifically on active-set membership.

## Why the resumable flush does not change it

RP-29 splits the flush but keeps the membership assertion, moving it into
`snapshot_expiry_pricer`. The same stale list produces the same abort, earlier and more
cheaply — before any payout-tree walk — but the flush still fails. The failure is
independent of the capacity work in RP-29 and RP-30.

## Decision rule this record supports

RP-31 makes both stages skip a market outside the snapshotted set rather than abort. The
completeness proof is unaffected: `seal_valuation_snapshot` requires a frozen pricer for
every expected market and `finish_flush` requires every expected market valued, so a
market that genuinely belongs to the flush still cannot be skipped.

Reopen if flush failures with this signature persist after RP-31 lands — that would mean
the divergence runs in the other direction (a market entering the active set after the
list was built), which still aborts at the seal by design.
