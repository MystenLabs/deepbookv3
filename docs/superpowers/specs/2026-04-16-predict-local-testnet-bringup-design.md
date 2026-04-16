# Predict Local Testnet Bring-Up Design

**Date**: 2026-04-16
**Status**: Approved for implementation
**Target branch**: `predict-testnet-4-16`

## Goal

Bring the predict stack on this branch to a state where it works locally against Sui testnet and a local Postgres on `5433`, with a lean oracle-feed service that owns the full oracle lifecycle and can be restarted safely after crashes.

The local success bar is:

1. Fresh redeploy from this branch.
2. Local `predict-indexer` populates the local database.
3. Local `predict-server` serves the indexed state.
4. Local `oracle-feed` creates, registers, activates, updates, settles, and compacts at least one short-lived oracle.
5. The 15-minute tier is proven end to end through settlement and compaction.

## Non-goals

- Preserve anything from the old `at/predict` deployment.
- Use Docker for local verification.
- Add long-term observability or deployment infrastructure beyond what is needed to verify local behavior.
- Add permanent websocket probe or diagnostic scripts.

## Service model

The runtime shape stays aligned with the working `at/predict` deployment model:

- `predict-indexer`: long-running Rust process that indexes testnet predict events into local Postgres.
- `predict-server`: long-running Rust process that serves local indexed state.
- `oracle-feed`: long-running Node process that owns the oracle lifecycle.

For local testing, all three run directly from the repo, not in Docker. Dockerfiles stay relevant for later deployment work, but local validation is direct host execution only.

Only `oracle-feed` needs crash-restart semantics. `predict-redeploy` is a one-shot operator command, and `predict-indexer` / `predict-server` just need to run correctly while testing.

## Oracle-feed design

The feed stays a single process with a single signer and a single source of truth: chain state plus live Block Scholes data. There is no local persistence.

The service has two execution modes:

- `push mode`: once per second, push `update_prices` for active oracles and `update_svi` when a fresher SVI sample exists.
- `manager mode`: on startup and on a slower interval, block `push mode`, wait for lanes to go idle, rediscover on-chain oracles, create missing ones, register missing caps, activate inactive ones once SVI exists, settle expired ones, and compact settled ones.

This split is required because there is one signer and owned `OracleSVICap` / gas coin objects cannot be equivocated. The manager path must serialize with the price-push path.

## Websocket contract

The first implementation priority is the real Block Scholes websocket contract, because the current service is wrong about how frames arrive.

### Observed handshake

Auth request:

```json
{"jsonrpc":"2.0","id":1,"method":"authenticate","params":{"api_key":"..."}}
```

Auth ack:

```json
{"jsonrpc":"2.0","result":"ok","id":1}
```

Subscribe ack:

```json
{
  "jsonrpc": "2.0",
  "result": [
    {
      "batch": {
        "frequency": "1000ms",
        "client_id": "pricing",
        "batch": [...]
      }
    }
  ],
  "id": 2
}
```

### Observed subscription frame shape

The important behavior is that one websocket message can carry multiple subscription payloads in `params[]`:

```json
{
  "jsonrpc": "2.0",
  "method": "subscription",
  "params": [
    {
      "data": {
        "values": [{ "sid": "fwd", "v": 74998.83913 }],
        "timestamp": 1776382722000
      },
      "client_id": "pricing"
    },
    {
      "data": {
        "values": [
          {
            "sid": "svi",
            "alpha": 0.00001,
            "beta": 0.00013,
            "rho": 0.22782,
            "m": 0.00111,
            "sigma": 0.00126
          }
        ],
        "timestamp": 1776382720000
      },
      "client_id": "svi"
    }
  ]
}
```

This means the subscriber must iterate **every** entry in `parsed.params`, not just `parsed.params[0]`.

### Observed value shapes

Spot / forward updates:

```json
{ "sid": "spot_BTC", "v": 75131.5558 }
{ "sid": "fwd_<oracleId>", "v": 75135.94385 }
```

SVI updates:

```json
{
  "sid": "svi_<oracleId>",
  "alpha": 0.00208,
  "beta": 0.02567,
  "rho": -0.61297,
  "m": -0.03999,
  "sigma": 0.05944
}
```

The sample timestamp lives at `params[i].data.timestamp`, not on the value itself.

### Flex expiry conclusion

The websocket supports flexible expiries, including the next quarter-hour boundary used by the 15-minute tier. A live probe against the next quarter-hour expiry returned:

- forward `mark.px` updates
- SVI `model.params` updates
- retransmitted SVI payloads every 20 seconds

This is the reason the service must use websocket data rather than REST for rotating short-dated expiries.

## Current subscriber bug

The current implementation in `scripts/services/oracle-feed/subscriber.ts` processes only:

```ts
const entry = parsed.params?.[0];
```

That drops any additional subscription entries in the same frame. In practice, this means SVI updates can be silently ignored whenever Block Scholes bundles pricing and SVI entries into one websocket message.

The implementation must treat `params` as an array of independent payloads and process each one.

## Lifecycle responsibilities

The service owns:

- discover existing oracles on startup
- create missing oracles for the configured cadence
- register all owned caps on newly created or partially bootstrapped oracles
- activate inactive oracles
- push prices continuously
- push SVI whenever fresher than the last pushed sample
- settle expired oracles via a fresh post-expiry price push
- compact settled oracles and remove them from active tracking

There is no separate lifecycle service and no separate bootstrap script for local testing.

## Lanes and serialization

The service uses a pool of `(gas coin, OracleSVICap)` lanes, but because there is one signer and owned objects can be equivocated:

- `push mode` may only use lanes when `manager mode` is not running.
- `manager mode` must wait for all lanes to be idle before using any lane.
- `create_oracle` / `register_oracle_cap` work remains serialized behind the single `AdminCap`.

This is intentionally conservative. Correctness matters more than squeezing out extra parallelism.

## Local verification shape

Local verification should intentionally narrow runtime scope so settlement is observable in-session:

- `ORACLE_TIERS=15m`
- `EXPIRIES_PER_TIER=1`

This keeps the code path the same while shortening the feedback loop. The service still uses the same websocket subscriber, manager logic, lane logic, and settlement / compaction flow; only the configured target set is smaller.

## Local run flow

1. Run `predict-redeploy` from this branch.
2. Reset local Postgres database `predict_v2` on port `5433`.
3. Start local `predict-indexer` from the publish checkpoint.
4. Start local `predict-server`.
5. Start local `oracle-feed` with real `.env` secrets.
6. Verify:
   - oracle gets created
   - caps are registered
   - oracle activates
   - live price rows and SVI rows land in Postgres
   - API surfaces the indexed data
   - the 15-minute oracle settles after expiry
   - compaction removes it from active tracking

## Acceptance criteria

- The websocket subscriber handles real Block Scholes frames, including multi-entry `params[]` messages.
- The service can be restarted locally and reconstruct state from chain truth without manual repair.
- A fresh redeploy from this branch indexes correctly into local Postgres on `5433`.
- `predict-server` returns sensible local responses for the deployed package.
- At least one 15-minute oracle is observed through `create -> register -> activate -> update -> settle -> compact`.
- The implementation stays lean: no extra services, no persistent local state, no permanent debug tooling.
