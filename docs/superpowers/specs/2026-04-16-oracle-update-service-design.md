# Oracle Update Service — Design

**Date**: 2026-04-16
**Status**: Draft (approved by aslan@mystenlabs.com)
**Target branch**: `predict-testnet-4-16`

## Purpose

Replace the prior `scripts/services/oracle-feed.ts` (at/predict branch) with a new long-running service that pushes price + SVI volatility surface parameters from BlockScholes into on-chain `predict::oracle` shared objects for a rolling set of BTC option expiries.

Initial target cadence: 4 concurrent oracles per tier × 4 tiers (15min, 1h, 1d, 1w) = 16 concurrent live oracles. Rolling replacement as each expires.

One transaction per second, PTB-composed, fired from a pool of 20 parallel lanes each pairing an owned gas coin with an owned `OracleSVICap`.

## Scope

In scope:
- Oracle lifecycle: creation, cap registration, activation, price / SVI updates, settlement, compaction
- Self-healing idempotent startup — no separate bootstrap script
- BlockScholes WebSocket client with reconnect, per-oracle subscription management
- Gas + cap lane pool with round-robin selection
- Structured logging layer
- Configuration, deployment, testing strategy

Out of scope (for this iteration):
- Non-BTC underlyings
- Multi-replica / horizontal scaling
- Automatic gas pool refill (operator-driven)
- Prometheus metrics + Grafana (deferred)
- Alerting / PagerDuty integration (deferred)

## Goals

1. Stream price + SVI params to every tracked oracle fast enough that `oracle.timestamp + staleness_threshold_ms!() (30s)` is always satisfied for live oracles.
2. Create new oracles on-schedule as wall clock crosses expected expiry boundaries. Never miss a rotation.
3. Survive WebSocket drops, transient Sui RPC failures, and partial transaction failures without operator intervention.
4. Self-healing startup: restart from any state (empty signer, partial bootstrap, fully-loaded) produces the same reconciled running state.
5. Gas-efficient: create cost (~30 SUI per oracle with 100k-strike grid) is largely recovered through `predict::compact_settled_oracle` calls after each oracle settles.
6. Observable: every state transition and every tick emits a structured log line with stable event names.

## Non-goals

- High throughput beyond 1 tx/s (workload doesn't require it)
- Recovering from operator-induced state corruption (deleted caps, destroyed shared objects)
- Supporting arbitrary on-chain operations beyond the five oracle intent types defined below

## Architecture

Single Node process. Five components operate on a shared typed `ServiceState` object. Two wall-clock timers (1s executor, 60s rotation) drive work. Subscriber is event-driven on WS frames. Logger is a pino singleton.

```
                          ┌────────────────────────────┐
                          │   BlockScholes WebSocket   │
                          └─────────────┬──────────────┘
                                        │ spot / fwd / SVI frames
                                        ▼
┌──────────────────────────────────────────────────────────────────────┐
│                          Oracle Service (Node process)               │
│                                                                      │
│  ┌─────────────┐   ┌─────────────────┐   ┌──────────────────────┐   │
│  │ Subscriber  │──▶│                 │◀──│  RotationManager     │   │
│  │ (WS client) │   │   SharedState   │   │  (60s wall-clock     │   │
│  └─────────────┘   │                 │   │   tick)              │   │
│                    │  - OracleRegistry│   └──────────────────────┘   │
│  ┌─────────────┐   │  - PriceCache    │                              │
│  │  GasPool    │◀─▶│  - SVICache      │   ┌──────────────────────┐  │
│  │ (20 lanes)  │   │  - IntentQueue   │◀──│      Executor        │  │
│  └─────────────┘   │  - LaneState     │   │  (1s wall-clock tick)│  │
│                    └────────┬────────┘    └──────────┬───────────┘  │
│                             │                         │              │
│                             └──────── Logger ◀────────┘              │
│                                       (pino/JSON)                    │
└──────────────────────────────────────────────────────────────────────┘
                                        │ signed PTBs (1 per second)
                                        ▼
                               ┌──────────────────┐
                               │  Sui testnet     │
                               └──────────────────┘
```

Correlation IDs on all log events: `tickId` (monotonic), `laneId` (0..19), `oracleId` (short hex), `txDigest` after submission, `component`, `event`.

## Shared state model

```typescript
type ServiceState = {
  registry: OracleRegistry;
  priceCache: PriceCache;
  sviCache: SVICache;
  intents: IntentQueue;
  lanes: LaneState;
  adminCapInFlight: boolean;  // serializes create_oracle + register_caps intents
  clock: { tickId: number };
};

type OracleId = string;
type Tier = "15m" | "1h" | "1d" | "1w";

type OracleState = {
  id: OracleId;
  underlying: "BTC";
  expiryMs: number;
  tier: Tier;
  status: "inactive" | "active" | "pending_settlement" | "settled";
  lastTimestampMs: number;
  registeredCapIds: Set<string>;
  matrixCompacted: boolean;
};

type OracleRegistry = {
  byId: Map<OracleId, OracleState>;
  byExpiry: Map<Tier, Map<number, OracleId>>;
};

type PriceCache = {
  spot: { value: number; receivedAtMs: number } | null;
  forwards: Map<OracleId, { value: number; receivedAtMs: number }>;
};

type SVICache = Map<OracleId, {
  params: { a: number; b: number; rho: number; m: number; sigma: number };
  receivedAtMs: number;
  lastPushedAtMs: number | null;
}>;

type Intent =
  | { kind: "create_oracle"; tier: Tier; expiryMs: number }
  | { kind: "bootstrap_oracle"; oracleId: OracleId } // register_caps × 20 + activate + first update
  | { kind: "register_caps"; oracleId: OracleId; capIds: string[] }
  | { kind: "activate"; oracleId: OracleId }
  | { kind: "compact"; oracleId: OracleId }
  | { kind: "settle_nudge"; oracleId: OracleId };

type IntentQueue = {
  pending: Intent[];
  inflight: Map<string, Intent[]>; // txDigest → intents included in that tx
  deadLetter: Intent[];
};

type Lane = {
  id: number;                          // 0..19
  gasCoinId: string;
  gasCoinBalanceApproxMist: number;
  capId: string;
  available: boolean;
  lastTxDigest: string | null;
};

type LaneState = {
  lanes: Lane[];                       // length LANE_COUNT
  nextHint: number;
};
```

Key constraints:
- `PriceCache.spot` is global (one BTC spot value shared across all oracles).
- `SVICache.lastPushedAtMs` prevents duplicate SVI pushes.
- `OracleState.registeredCapIds` tracks which of our 20 caps the oracle has authorized; partial registration is a valid recoverable state.
- `Intent.register_caps` carries the *remaining* unregistered subset, not the full list.
- `IntentQueue.inflight` maps tx digest to the intents bundled in that tx; on finality the entries are applied or rolled back.
- `IntentQueue.deadLetter` retains intents that failed N times; not auto-retried, operator inspects.

## Oracle lifecycle

### Expected set from wall clock

At time `t`, `RotationManager` expects these oracles:

| Tier | Boundary | Target set |
|---|---|---|
| 15m | `:00 :15 :30 :45` UTC | next 4 quarter-hour marks after `t` |
| 1h  | top of hour UTC | next 4 hour marks after `t` |
| 1d  | `08:00 UTC` | next 4 days' 08:00 UTC after `t` |
| 1w  | Friday `08:00 UTC` | next 4 Fridays' 08:00 UTC after `t` |

Strike grid for all oracles: `min_strike=50_000`, `max_strike=150_000`, `tick_size=1` (100,001 strikes, BTC $1 granularity).

### Startup dispatch

Every 60s rotation tick (and immediately on startup), compute expected set, compare to `registry.byExpiry`:
- Missing expected expiry → enqueue `create_oracle`
- Present but unexpected → no action (oracle will expire and settle naturally)

After startup discovery PTB, each existing oracle is classified and dispatched:

| Status | Action |
|---|---|
| `INACTIVE` | enqueue `bootstrap_oracle` (register missing caps + activate + first update) |
| `ACTIVE` | enqueue `register_caps` if any of 20 caps missing; otherwise resume |
| `PENDING_SETTLEMENT` (past expiry, unsettled) | enqueue `settle_nudge` → then `compact` |
| `SETTLED` | enqueue `compact` (idempotent; no-op if already compacted) |

### Creation sequence

| Tick | PTB contents |
|---|---|
| N | `registry::create_oracle(Registry, Predict, AdminCap, cap_lane_i, "BTC", expiryMs, 50_000, 1, ctx)` |
| N+1 | `bootstrap_oracle`: `register_oracle_cap` × 20 + `activate` + first `update_prices` + first `update_svi` (if cached) |
| N+2 onward | routine `update_prices` / `update_svi` |

Precreation timing: RotationManager enqueues `create_oracle` as soon as the expected expiry enters the "next 4" window. Given 60s rotation ticks and minimum 15min lead time for the 15m tier (the tightest cadence), a new oracle has at least ~15 minutes between enqueue and its own expiry — plenty of buffer for create → bootstrap → first update to complete well before the oracle becomes the head of its tier and needs to support trading.

### Settlement + compaction

When wall clock passes `oracle.expiryMs`, the next `update_prices` tick hits the `PENDING_SETTLEMENT` branch in `oracle.move:160–171`:
- Sets `settlement_price`
- Sets `active = false`
- Emits `OracleSettled`

Service parses the event from tx effects, flips `status = settled`, enqueues `compact`. Next `compact` tick calls `predict::compact_settled_oracle(predict, oracle, cap)` which destroys the dense `StrikeMatrix` → storage rebate flows to the lane's gas coin. Post-compact, `matrixCompacted = true` and the oracle drops from active tracking.

## Gas + cap lane pool

### Lane identity

20 lanes, each a pair: `(gas_coin, OracleSVICap)` — both owned objects, paired 1:1 for concurrency safety.

### Idempotent self-healing startup

Every service start runs the same sequence:

1. Load signer, AdminCap ID, Registry ID, Predict ID, package ID from env.
2. Query owned `OracleSVICap` objects. If `< 20`, bootstrap PTB creates the missing count. Lock in first 20 as `cap_0..cap_19`.
3. Query owned SUI coins sorted by value desc. If `sum(top 20) < GAS_POOL_FLOOR_SUI`, abort with clear error. If main coin is disproportionately large, split via `pay::split_vec`. Pair `coins[i] ↔ caps[i]`.
4. Discovery `devInspect` PTB: for each cap_id, read `registry.oracle_ids[cap_id]`, fetch `(expiry, active, timestamp, settlement_price, authorized_caps)` for each oracle.
5. Classify each oracle by status (Section "Startup dispatch") and enqueue appropriate intents, including `register_caps` for any missing cap coverage.
6. Start Subscriber, RotationManager, Executor.

No persisted state. No separate bootstrap script. Chain + config is the full source of truth.

### Round-robin selection

`GasPool.nextAvailableLane()`:
1. Start from `lanes.nextHint`, walk forward (wrap at LANE_COUNT)
2. First lane with `available: true` wins
3. Mark `available: false`, advance `nextHint`

If every lane is in-flight at tick fire: skip the tick, emit `warn`.

### AdminCap serialization

`create_oracle` and `register_oracle_cap` both require `&AdminCap` (see `registry.move:94` and `:104`). `AdminCap` is a single owned object, so at most one AdminCap-using transaction can be in-flight across the whole service — regardless of how many lanes are free.

Executor maintains a boolean `adminCapInFlight` flag. When draining the next one-off intent:

1. If intent is `create_oracle` or `register_caps` (aka bootstrap_oracle's register batch) AND `adminCapInFlight == true`: push intent back to pending (not dead-letter), skip this tick's one-off drain; still bundle routine updates and fire
2. Otherwise: set `adminCapInFlight = true` when submitting, reset on finality

At the target cadence (4 creates/hour peak + their bootstrap_oracle follow-ons = ~8 AdminCap-using txs/hour × ~2s each ≈ 16s of AdminCap-busy time per hour) this serialization is not a throughput concern. The flag just prevents equivocation errors when two AdminCap-using intents queue up adjacently.

Intents that don't need AdminCap — `activate`, `compact`, `settle_nudge`, `update_prices`, `update_svi` — fire on any available lane with no serialization.

### Lane release on tx finality

Parse effects for gas usage + storage rebate → update lane's `gasCoinBalanceApproxMist`. Set `available: true`.

### Low-gas exclusion

| Balance | Behavior |
|---|---|
| `≥ LANE_CREATE_RESERVE_SUI` (default 5) | Usable for any intent |
| `< 5 SUI` | Excluded from `create_oracle` intent selection |
| `< LANE_MIN_SUI` (default 1) | Excluded entirely |

Pool-level thresholds:
- ≥10 of 20 lanes below 5 SUI → `error` log
- Total pool below 100 SUI → `fatal`, stop accepting `create_oracle` intents, routine updates continue on remaining gas.

## Executor tick

```
on tick(tickId):
  lane = gasPool.nextAvailableLane()
  if lane is None: log.warn({event: "no_lane_available"}); return

  ptb = new Transaction()
  ptb.setSender(signer)
  ptb.setGasPayment([lane.gasCoin])
  includedIntents = []

  # 1. drain ONE one-off intent (respecting AdminCap serialization)
  if intents.pending.length > 0:
    intent = intents.pending[0]
    if intent.usesAdminCap AND adminCapInFlight:
      pass   # skip the one-off this tick; will try next tick
    else:
      intents.pending.shift()
      ptb.add(buildIntentCalls(intent, lane))
      includedIntents.push(intent)
      if intent.usesAdminCap: adminCapInFlight = true

  # 2. append update_prices for every active oracle with fresh cache
  for oracle in registry where status == "active":
    if priceCache has fresh spot AND fresh forwards[oracle.id]:
      ptb.add(update_prices(oracle.id, lane.capId, spot, fwd, clock))

  # 3. append update_svi for oracles with fresh SVI delta
  for oracle in registry where status == "active":
    svi = sviCache[oracle.id]
    if svi exists AND (lastPushedAtMs is None OR receivedAtMs > lastPushedAtMs):
      ptb.add(update_svi(oracle.id, lane.capId, svi.params, clock))

  if ptb.commandCount == 0: gasPool.release(lane); return

  lane.available = false
  digest = await client.signAndExecute(ptb, signer, { waitForLocalExecution: false })
  intents.inflight[digest] = includedIntents
  log.info({tickId, laneId, digest, commandCount})

  finality(digest).then(applyEffects).catch(rollback)
```

### Key rules

- **One one-off intent per PTB**: isolates failure modes across intent kinds. Routine price/SVI updates are always bundled with the one-off.
- **AdminCap serialization**: `create_oracle` and `bootstrap_oracle` use `AdminCap` (owned). Executor skips the one-off drain on ticks where the next pending intent needs AdminCap and `adminCapInFlight == true`. Other intent types fly freely.
- **Intent priority**: FIFO, except `settle_nudge` jumps to the front (unblocks the oracle's settlement path).
- **PTB composition order**: one-off first, then all `update_prices`, then all `update_svi`. Consistent ordering simplifies log parsing.
- **Size**: worst case ~60 MoveCalls in a single PTB (bootstrap_oracle tick with 16 active oracles also getting routine updates). Well under Sui's 1024-command limit.
- **Non-blocking finality**: `waitForLocalExecution: false`. Finality watcher is async; doesn't block the next tick. Sustains 1s cadence even under 3–4s finality latency.

### Effects application on tx success

| MoveCall | State update |
|---|---|
| `update_prices` → success | `oracle.lastTimestampMs = now`; on `OracleSettled` event, flip `status = settled` and enqueue `compact` |
| `update_svi` → success | `sviCache[oracleId].lastPushedAtMs = <svi.receivedAtMs at PTB build time>` |
| `register_oracle_cap` | `oracle.registeredCapIds.add(capId)` |
| `activate` | `oracle.status = active` |
| `create_oracle` | Parse `OracleCreated` event → add oracle to registry as `inactive` → enqueue `bootstrap_oracle` |
| `compact_settled_oracle` | `oracle.matrixCompacted = true`; drop from active tracking |

### Failure rollback

On tx failure:
- Move `includedIntents` back to `pending` head (priority retry)
- Increment `retries` counter per intent
- After `INTENT_MAX_RETRIES` (default 5): move intent to `deadLetter`, log `error` at `event: intent_failed_final`

Routine `update_prices` / `update_svi` have no retry state — each tick regenerates them fresh from cache. A failed tick is superseded by next tick.

Both success and failure paths reset `adminCapInFlight = false` on tx finality if the tx used AdminCap. This frees up the next AdminCap-requiring intent to fire on the following tick.

## Subscriber (BlockScholes WS)

Long-lived WebSocket to `wss://prod-websocket-api.blockscholes.com/`. Writes to `PriceCache` and `SVICache`. No timer — purely event-driven.

### Subscription topology

| Kind | Batch shape | Count at 16 oracles |
|---|---|---|
| Spot (`index.px`, global) | 1 item | 1 subscribe |
| Forwards (`mark.px`, per expiry) | up to 10 items per §3.1 | 2 subscribes (10 + 6) |
| SVI (`model.params`, per expiry) | 1 item per §4.8 | 16 subscribes |

Subscription parameters:
- Pricing: `frequency: "1000ms"`
- SVI: `frequency: "20000ms"`, `retransmit_frequency: "20000ms"` (effective once BlockScholes ships the server-side fix; design is forward-compatible)

### Dynamic add/remove

Each sub is tagged with a sid containing the oracle_id. On new oracle: incremental `subscribe`. On oracle drop: `unsubscribe` (or ignore frames if unsupported).

### Reconnect

Exponential backoff: `500ms → 60s cap`. Reset on first successful frame. On reconnect: re-auth + re-subscribeAll.

Auth failure on reconnect (e.g., key revoked) → `fatal`, `process.exit(1)`.

### Heartbeat

Client-side WS ping every 20s. No pong in 10s → tear down + reconnect. Catches silent TCP half-closes.

### Per-subscription error

If a specific oracle's `subscribe` errors (catalog miss, rate limit): log `warn`, skip that oracle's sid, retry on next reconnect. Executor tolerates empty cache entries by omitting the oracle from the tick.

## Logger

Library: `pino`. JSON stdout only. No file I/O in-process.

### Levels

| Level | Contents |
|---|---|
| `debug` | Per-tick PTB shape, cache values, lane selection. Off by default. |
| `info` | Tick results, oracle lifecycle transitions, WS sub add/remove, reconnect attempts |
| `warn` | Skipped ticks, WS retransmit misses, per-oracle sub failures, partial intent retries, low-gas lanes |
| `error` | Tx reverts after N retries, WS auth failures, gas pool near exhaustion, devInspect failures |
| `fatal` | Unrecoverable config/state errors. Followed by `process.exit(1)`. |

### Correlation fields

Every log line carries (where applicable): `tickId`, `laneId`, `oracleId`, `txDigest`, `component`, `event`.

### Event names

Finite, stable, documented strings. Examples: `tick_fired`, `tx_finalized`, `oracle_created`, `oracle_settled`, `oracle_compacted`, `ws_reconnect`, `ws_connected`, `intent_failed_final`, `no_lane_available`. Defined as a union type in code.

### Config

One env var: `LOG_LEVEL` (default `info`).

## Failure modes + retry policy (summary)

- Generic intents: retry up to `INTENT_MAX_RETRIES` (5), then dead-letter
- Routine `update_prices` / `update_svi`: no retry state; next tick supersedes
- WS: auto-reconnect with exponential backoff; fatal only on auth rejection
- Gas: lane exclusion on low balance; fatal only on full pool exhaustion
- Discovery: fatal on devInspect failure (config error)
- Equivocation: fatal (indicates duplicate service instance)

Deadlock prevention: per-oracle isolation in routine updates, dead-letter for stuck intents, 60s rotation tick re-discovers new on-chain oracles created outside the service.

## Configuration

```
# Network
NETWORK=testnet
SUI_RPC_URL=https://…
SUI_SIGNER_KEY=suiprivkey1…
PREDICT_PACKAGE_ID=0x…
REGISTRY_ID=0x…
PREDICT_ID=0x…
ADMIN_CAP_ID=0x…

# BlockScholes
BLOCKSCHOLES_API_KEY=…
BLOCKSCHOLES_WS_URL=wss://prod-websocket-api.blockscholes.com/

# Tiers
TIERS_ENABLED=15m,1h,1d,1w

# Strike grid
STRIKE_MIN=50000
STRIKE_MAX=150000
TICK_SIZE=1

# Pool
GAS_POOL_FLOOR_SUI=600
LANE_CREATE_RESERVE_SUI=5
LANE_MIN_SUI=1
LANE_COUNT=20

# Runtime
LOG_LEVEL=info
EXECUTOR_TICK_MS=1000
ROTATION_TICK_MS=60000
PRICE_CACHE_STALE_MS=3000
WS_PING_INTERVAL_MS=20000
WS_PONG_TIMEOUT_MS=10000
INTENT_MAX_RETRIES=5
```

Underlying hardcoded to `"BTC"` — multi-underlying is a future iteration.

## Deployment

Single Docker container, single replica, `always` restart policy.

- Base: `node:22-slim`
- Entrypoint: `pnpm tsx services/oracle-service/index.ts`
- Secrets via k8s Secret (`SUI_SIGNER_KEY`, `BLOCKSCHOLES_API_KEY`)
- Config via k8s ConfigMap
- Resources: ~256 MB memory, 0.2 CPU
- Health check: HTTP `/healthz` returns 200 if WS connected within 60s AND last successful tick within 10s

No horizontal scaling — service owns caps and gas coins; two replicas would equivocate.

## Testing

**Unit** (vitest or repo's existing runner):
- IntentQueue: priority, retry, dead-letter
- GasPool: lane selection, release, exclusion
- Expiry math: wall-clock → expected set at known UTC times
- WS frame parser: JSON-RPC frames → cache updates
- PTB builder: mock state → expected MoveCall sequence

**Integration against local Sui node + local packages/predict**:
- Full startup on empty signer (bootstrap → split → first tick)
- End-to-end oracle lifecycle: create → activate → update → settle → compact
- Lane isolation: simulate one stuck lane, verify others fire
- Rotation: mock `Clock`, verify new oracle creation at boundary crossings

**Manual testnet smoke** (pre-production):
- 24h with `TIERS_ENABLED=1h` only
- 72h with `1h,1d,1w`
- 24h with all four tiers enabled once BlockScholes ships retransmit fix

## Rollout plan

1. PR #972 merged (confirmed in branch at `predict.move:270`)
2. Clean up `#[test_only]`-scoping in `vault.move` and `strike_matrix.move` (minor follow-up)
3. Implement service per this design
4. Local integration tests
5. Testnet deploy with `TIERS_ENABLED=1h,1d,1w` (15m gated off)
6. Flip `15m` tier on after BlockScholes ships retransmit fix (config-only change, no code)
7. 72h observation → declare testnet-ready

## Open items

None blocking implementation. Two deferred:
- Prometheus metrics + Grafana (iterate after first week of operation)
- `unsubscribe` RPC shape: docs didn't cover; confirm with BlockScholes or fall back to "ignore stale sids"

## References

- `packages/predict/sources/oracle.move` — `OracleSVI`, `OracleSVICap`, `update_prices`, `update_svi`, `activate`, `create_oracle`, `register_cap`
- `packages/predict/sources/oracle_config.move:200–225` — `assert_live_oracle`, `assert_quoteable_oracle`, 30s staleness threshold
- `packages/predict/sources/registry.move:94–134` — `register_oracle_cap`, `create_oracle_cap`, `create_oracle`
- `packages/predict/sources/predict.move:270–279` — `compact_settled_oracle`
- `packages/predict/sources/helper/constants.move:46` — `staleness_threshold_ms() = 30_000`
- BlockScholes WebSocket API: `https://docs.blockscholes.com/data-access/websocket-api`
- Prior service (reference only, at/predict branch): `scripts/services/oracle-feed.ts`
