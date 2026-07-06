# Predict Exact-Timestamp Settlement Liveness

Status: accepted operational assumption as of 2026-07-02.

This note resolves the former `S-1` deploy gate and the former `C-2`
settled-but-unswept active-market liveness item. No contract change is planned.

## Contract Requirement

Predict settlement intentionally uses an exact Propbook/Pyth timestamp. A market
settles only after the keeper inserts a Pyth Lazer observation whose signed
source timestamp matches `market.expiry` exactly. The settlement transaction then
calls `plp::rebalance_expiry_cash`, which records the terminal `MarketSettled`
event through `ensure_settled` and sweeps/deactivates the market in the same PTB.

The expected transient state is:

1. the market expires;
2. live pricing is no longer allowed;
3. the keeper queries Pyth for the exact expiry timestamp;
4. `pyth_feed::insert_at`, `plp::rebalance_expiry_cash`, `MarketSettled`, and
   the settled sweep/deactivation land atomically.

During step 3, pool flushes intentionally defer or retry rather than using an
approximate settlement mark.

## Testnet Evidence

Scope: Sui testnet, `predict-keeper-testnet` / `propbook-testnet`,
2026-07-01 through 2026-07-02. The sample covers about 870 settled BTC/USD
expiries across two keeper designs: 840 on the original poll design and 27 on
the current subscribe-first design. Observed cadences ranged from 1 minute to
multi-hour markets, with 13 to 14 concurrent expiry lanes.

`insert_at` and `MarketSettled` share one latency number because the keeper lands
the exact insert, settlement, and settled sweep/deactivation atomically in one
PTB.

| Metric | Poll design, 840 settles | Subscribe-first design, 27 settles |
| --- | ---: | ---: |
| p50 expiry to settle | 10.0s | 1.0s |
| p90/p95 expiry to settle | about 14-15s | about 6s |
| p99/max expiry to settle | 16.2s / 19.8s | about 16s single outlier |

Observed settlement behavior:

- 100% of expiries settled within 1 minute in both keeper eras, excluding the
  single stream-channel incident described below.
- No expiry remained permanently unsettled.
- No expiry required manual settlement.
- Across the sample, Pyth exact-timestamp data was available on the first
  request every time. There were zero retries caused by "exact price not yet
  published."
- The earliest successful exact-timestamp request landed 2.2 seconds after
  expiry.

## Exactness Checks

The keeper requests the exact expiry timestamp using the Pyth REST price
endpoint with an explicit timestamp. The stream path buffers frames by exact
`timestampUs` and discards non-boundary frames for settlement.

Every observed settlement log carried:

```text
pythTsUs == expiry_ms * 1000
```

This was verified programmatically over the observed settles with zero
mismatches. Cadence-created expiries are minute-aligned by construction, and all
cadence periods are whole-minute multiples.

Observed exactness failures during the sample:

- non-whole-millisecond timestamp: 0
- missing Pyth data: 0
- stale or future data: 0
- duplicate insert causing a failed settle: 0
- manual settlement: 0

Submissions are idempotent-keyed, so repeat attempts are safe.

## Operational Controls

The keeper treats expired-unsettled as a designed, monitored transient:

- retry cadence: every 10 seconds on the scan path;
- retry duration: indefinite, isolated per market;
- sweep responsibility: every expired active market is driven through
  `plp::rebalance_expiry_cash` after its exact row is available, removing it from
  the pool's active-expiry set (`pool_accounting::Ledger.active_expiry_markets`,
  reached via the vault's expiry accounting) before routine flushes;
- flush boundary guard: defer when any market is within 15 seconds of expiry or
  when an expired active market has not yet been swept/deactivated;
- stuck threshold: report a service failure if any market remains
  expired-unsettled or expired-unswept beyond 60 seconds;
- recovery: cold-start reseed from REST; pod restart is documented in the
  keeper deployment repo's `docs/operations/predict-keeper-redeploy.md` (the
  keeper is not part of this repository).

Observed flush aborts caused by pending settlement were rare, about 1 to 2 over
the period, and cleared automatically on the next tick.

Escalation signals:

- expired-unsettled market older than 60 seconds;
- expired market still present in the pool active set older than 60 seconds;
- sustained `source=rest` settlement ratio above the expected fallback level;
- flush-stuck service failure records.

## Incident

On 2026-07-02, about 6 markets were delayed for up to about 6 minutes during a
roughly 12 minute incident. The root cause was a keeper configuration change
that subscribed the new stream path to a Lazer channel whose id byte the
deployed on-chain package did not yet support, causing `channel::from_u8` to
abort.

This was not a Pyth exact-timestamp availability failure. It cleared after the
configuration fix, and the keeper now retries stream-payload failures through
the proven REST path.

## Representative Digests

- Stream-sourced settle at about 1.0s after expiry:
  `BUr8ETmhkQpAvK9fv6ZBwoLmUhRUEbiQs4aSeyTSUB85`
- Post-backlog settle:
  `62gEwBBvz2Lc8WAmsTBX9awj2oSV8po27iNQ7XiHCVqr`
- Subsequent successful flushes:
  `EcLv9zzz4ofYyeLrg9kRKP7ShHVp9VwznB3ygbZBScBt`,
  `6B3fJEfVHhsnMPd9a28oL6M1mwHQGg8oPijZN8dCKs6z`

Metrics came from keeper settlement logs
(`settled market=... pythTsUs=... source=...`) with pod timestamps, plus the
`bs_stream_stats` dashboard tooling.

## Conclusion

Exact-timestamp settlement is accepted as an operational liveness assumption.
The expected missing-exact-print window is a sub-minute transient under current
testnet operations, monitored by the keeper, and automatically clearing.

Residual risk remains off-chain keeper availability: if the keeper cannot insert
the exact expiry print, affected markets remain expired-unsettled and pool
flushes continue to defer, retry, or fail until insertion lands.
