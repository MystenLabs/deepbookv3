# Predict Local Testnet Bring-Up Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the predict stack on `predict-testnet-4-16` work locally against testnet and local Postgres, with a lean `oracle-feed` service that is websocket-correct and proves one `15m` oracle through settlement and compaction.

**Architecture:** Keep the existing 3-service shape (`predict-indexer`, `predict-server`, `oracle-feed`). Fix the real websocket contract first, then harden the single-signer oracle manager / push loop so it can safely create, register, activate, update, settle, and compact. Local verification runs directly from the repo with a narrowed runtime config (`15m`, one expiry) to shorten the proof loop.

**Tech Stack:** TypeScript (`tsx`, `vitest`, native WebSocket, `@mysten/sui`), Rust (`predict-indexer`, `predict-server`), Postgres, Sui testnet.

---

## File structure

- `scripts/services/oracle-feed/subscriber.ts`
  Parses Block Scholes frames and populates the in-memory price / SVI caches.
- `scripts/services/oracle-feed/executor.ts`
  Owns push-mode and manager-mode orchestration, lane-idle serialization, fresh-settlement checks, and lifecycle transitions.
- `scripts/services/oracle-feed/config.ts`
  Runtime knobs for tier selection, lookahead, health, and local verification mode.
- `scripts/services/oracle-feed/index.ts`
  Entry point wiring config, bootstrap, registry discovery, subscriber, executor loops, and shutdown.
- `scripts/services/oracle-feed/__tests__/subscriber.test.ts`
  Focused regression tests for raw websocket frame handling.
- `crates/predict-indexer/src/handlers.rs`
  Transaction metadata extraction for indexed rows.
- `crates/predict-server/src/reader.rs`
  Latest-row queries used by the local API.
- `docs/superpowers/specs/2026-04-16-predict-local-testnet-bringup-design.md`
  Approved design reference.

### Task 1: Lock down the websocket contract

**Files:**
- Modify: `scripts/services/oracle-feed/subscriber.ts`
- Create: `scripts/services/oracle-feed/__tests__/subscriber.test.ts`
- Verify with: `scripts/services/blockscholes-stream-test.ts` (local probe only, not committed)

- [ ] **Step 1: Expose a small pure parser from `subscriber.ts`**

Add a helper that accepts one parsed websocket payload and returns normalized frames:

```ts
export type NormalizedWsValue =
  | { kind: "spot"; sid: string; value: number; timestampMs: number }
  | { kind: "forward"; oracleId: string; value: number; timestampMs: number }
  | { kind: "svi"; oracleId: string; params: SVIParams; timestampMs: number };

export function extractWsValues(payload: any): NormalizedWsValue[] {
  if (payload?.method !== "subscription" || !Array.isArray(payload.params)) {
    return [];
  }

  const out: NormalizedWsValue[] = [];
  for (const entry of payload.params) {
    const timestampMs = Number(entry?.data?.timestamp);
    const values = Array.isArray(entry?.data?.values) ? entry.data.values : [];
    for (const value of values) {
      const sid = String(value?.sid ?? "");
      if (sid.startsWith("spot_") && typeof value.v === "number") {
        out.push({ kind: "spot", sid, value: value.v, timestampMs });
      } else if (sid.startsWith("fwd_") && typeof value.v === "number") {
        out.push({
          kind: "forward",
          oracleId: sid.slice(4),
          value: Number(value.v),
          timestampMs,
        });
      } else if (sid.startsWith("svi_")) {
        out.push({
          kind: "svi",
          oracleId: sid.slice(4),
          params: {
            a: Number(value.alpha),
            b: Number(value.beta),
            rho: Number(value.rho),
            m: Number(value.m),
            sigma: Number(value.sigma),
          },
          timestampMs,
        });
      }
    }
  }
  return out;
}
```

- [ ] **Step 2: Write the regression tests before changing runtime behavior**

Create `scripts/services/oracle-feed/__tests__/subscriber.test.ts` with:

```ts
import { describe, expect, it } from "vitest";
import { extractWsValues } from "../subscriber";

describe("extractWsValues", () => {
  it("keeps both pricing and svi entries when a frame has multiple params", () => {
    const payload = {
      jsonrpc: "2.0",
      method: "subscription",
      params: [
        {
          client_id: "pricing",
          data: {
            timestamp: 1776382722000,
            values: [{ sid: "fwd_0xabc", v: 74998.83913 }],
          },
        },
        {
          client_id: "svi",
          data: {
            timestamp: 1776382720000,
            values: [
              {
                sid: "svi_0xabc",
                alpha: 0.00001,
                beta: 0.00013,
                rho: 0.22782,
                m: 0.00111,
                sigma: 0.00126,
              },
            ],
          },
        },
      ],
    };

    expect(extractWsValues(payload)).toEqual([
      {
        kind: "forward",
        oracleId: "0xabc",
        value: 74998.83913,
        timestampMs: 1776382722000,
      },
      {
        kind: "svi",
        oracleId: "0xabc",
        params: {
          a: 0.00001,
          b: 0.00013,
          rho: 0.22782,
          m: 0.00111,
          sigma: 0.00126,
        },
        timestampMs: 1776382720000,
      },
    ]);
  });

  it("returns an empty list for non-subscription payloads", () => {
    expect(extractWsValues({ jsonrpc: "2.0", id: 1, result: "ok" })).toEqual([]);
  });
});
```

- [ ] **Step 3: Run the focused test and make sure it fails first**

Run:

```bash
cd scripts
pnpm test services/oracle-feed/__tests__/subscriber.test.ts
```

Expected: fail because `extractWsValues` does not exist yet and/or the current subscriber only reads `params[0]`.

- [ ] **Step 4: Wire the subscriber runtime through the helper**

Update `subscriber.ts` so the `"message"` handler:

```ts
const raw = event.data.toString();
const parsed = JSON.parse(raw);

if (parsed.id === 1 && parsed.result === "ok") {
  authed = true;
  log.info({ event: "ws_auth_ok" });
  resubscribeAll();
  reconnectAttempt = 0;
  return;
}

if (parsed.error) {
  log.warn({ event: "ws_subscribe_error", rpcId: parsed.id, error: parsed.error });
  return;
}

const extracted = extractWsValues(parsed);
if (extracted.length > 0) {
  lastFrame = Date.now();
  for (const item of extracted) {
    applyNormalizedValue(item);
  }
  return;
}
```

Add `applyNormalizedValue()` that updates `priceCache` / `sviCache` and preserves `lastPushedAtMs`.

- [ ] **Step 5: Re-run the focused test**

Run:

```bash
cd scripts
pnpm test services/oracle-feed/__tests__/subscriber.test.ts
```

Expected: pass.

- [ ] **Step 6: Re-run the live websocket probe**

Run:

```bash
set -a
source .env
set +a
cd scripts
TEST_EXPIRY="$(node -e 'const d=new Date();d.setUTCSeconds(0,0);d.setUTCMinutes(Math.floor(d.getUTCMinutes()/15)*15+15);process.stdout.write(d.toISOString().replace(/\\.\\d{3}Z$/,\"Z\"))')"
RUN_MS=35000 pnpm tsx services/blockscholes-stream-test.ts
```

Expected:
- auth ack
- subscribe acks
- forward updates
- SVI updates
- at least one combined frame carrying both pricing and SVI payloads

- [ ] **Step 7: Commit**

```bash
git add scripts/services/oracle-feed/subscriber.ts scripts/services/oracle-feed/__tests__/subscriber.test.ts
git commit -m "fix(oracle-feed): handle multi-entry websocket frames"
```

### Task 2: Harden the lean single-signer lifecycle loop

**Files:**
- Modify: `scripts/services/oracle-feed/executor.ts`
- Modify: `scripts/services/oracle-feed/index.ts`
- Modify: `scripts/services/oracle-feed/config.ts`

- [ ] **Step 1: Write focused lifecycle regression tests**

Add test coverage in a new `scripts/services/oracle-feed/__tests__/executor.test.ts` for:

```ts
it("does not settle an expired oracle from stale spot data", () => {
  // stale spot should prevent settle_nudge scheduling
});

it("fails manager mode if lanes do not drain before timeout", () => {
  // manager must not proceed onto lane0 if any lane remains busy
});
```

The exact tests can stub `ServiceState`, `Config`, and lane arrays without RPC.

- [ ] **Step 2: Run the focused lifecycle test and confirm failure**

Run:

```bash
cd scripts
pnpm test services/oracle-feed/__tests__/executor.test.ts
```

Expected: fail because the current manager window can proceed after the drain timeout and current settlement logic does not gate on fresh spot.

- [ ] **Step 3: Enforce lane-drain correctness**

Change `waitForAllLanesIdle()` to return a boolean or throw:

```ts
async function waitForAllLanesIdle(lanes: Lane[]): Promise<void> {
  const deadline = Date.now() + 15_000;
  while (Date.now() < deadline) {
    if (lanes.every((lane) => lane.available)) return;
    await new Promise((resolve) => setTimeout(resolve, 100));
  }
  throw new Error("manager window timed out waiting for lanes to drain");
}
```

Manager mode should abort that cycle if the drain fails.

- [ ] **Step 4: Require fresh spot for settlement**

In `settleOracleStep()` gate settlement exactly the same way push mode gates price updates:

```ts
const now = Date.now();
const spot = state.priceCache.spot;
if (!spot) return;
if (now - spot.receivedAtMs > config.priceCacheStaleMs) {
  log.warn({
    event: "tick_skipped_stale_prices",
    oracleId: oracle.id,
    reason: "stale_spot_for_settlement",
    spotAgeMs: now - spot.receivedAtMs,
  });
  return;
}
```

- [ ] **Step 5: Keep local verification runtime small**

Ensure `config.ts` cleanly supports:

```ts
tiersEnabled: process.env.ORACLE_TIERS ? parseTiers(process.env.ORACLE_TIERS) : ["15m", "1h", "1d", "1w"],
expiriesPerTier: process.env.EXPIRIES_PER_TIER ? Math.max(1, parseInt(process.env.EXPIRIES_PER_TIER, 10)) : 4,
```

and document the local proof settings in comments near the env parsing.

- [ ] **Step 6: Re-run the focused lifecycle tests**

Run:

```bash
cd scripts
pnpm test services/oracle-feed/__tests__/executor.test.ts
```

Expected: pass.

- [ ] **Step 7: Commit**

```bash
git add scripts/services/oracle-feed/executor.ts scripts/services/oracle-feed/index.ts scripts/services/oracle-feed/config.ts scripts/services/oracle-feed/__tests__/executor.test.ts
git commit -m "fix(oracle-feed): serialize manager mode safely"
```

### Task 3: Fix local indexing / API correctness needed for verification

**Files:**
- Modify: `crates/predict-indexer/src/handlers.rs`
- Modify: `crates/predict-server/src/reader.rs`

- [ ] **Step 1: Fix indexed package attribution**

Stop deriving row `package` from the first move call in the PTB. Use the matched event type address instead:

```rust
let package = format!("0x{}", ev.type_.address.to_canonical_string(/* with_prefix */ false));
```

Pass that package into `EventMeta` for the matching event row rather than storing the first move call package for the whole transaction.

- [ ] **Step 2: Fix latest-row ordering**

Any latest-row query used by the local API must break ties within the same checkpoint. Use:

```rust
.order_by((
    schema::pricing_config_updated::checkpoint.desc(),
    schema::pricing_config_updated::event_digest.desc(),
))
```

Apply the same tie-break pattern to:
- latest pricing config
- latest risk config
- latest trading pause
- latest oracle ask bounds union query
- enabled quote assets union query

- [ ] **Step 3: Build the local Rust services**

Run:

```bash
cargo build -p predict-indexer
cargo build -p predict-server
```

Expected: both succeed.

- [ ] **Step 4: Commit**

```bash
git add crates/predict-indexer/src/handlers.rs crates/predict-server/src/reader.rs
git commit -m "fix(predict): tighten local indexer and API correctness"
```

### Task 4: Live local bring-up and proof

**Files:**
- Modify only if required by the previous tasks.
- Runtime inputs: `.env`, local Postgres on `5433`

- [ ] **Step 1: Redeploy from this branch**

Run:

```bash
set -a
source .env
set +a
cd scripts
PGPORT=5433 pnpm predict-redeploy
```

Expected:
- package publish succeeds
- predict init succeeds
- `scripts/config/constants.ts` reflects the new package / object IDs
- `crates/predict-indexer/src/lib.rs` points at the new package
- local `predict_v2` database is recreated

- [ ] **Step 2: Start the indexer**

Run:

```bash
cargo run -p predict-indexer -- --database-url postgres://postgres:postgres@localhost:5433/predict_v2 --first-checkpoint <publish_checkpoint>
```

Expected:
- migrations run
- indexer starts consuming from the redeploy checkpoint

- [ ] **Step 3: Start the API server**

Run:

```bash
cargo run -p predict-server -- --database-url postgres://postgres:postgres@localhost:5433/predict_v2
```

Expected:
- server binds successfully
- `/health` returns `200`

- [ ] **Step 4: Start the local oracle-feed proof run**

Run:

```bash
set -a
source .env
set +a
cd scripts
NETWORK=testnet \
ORACLE_TIERS=15m \
EXPIRIES_PER_TIER=1 \
pnpm oracle-feed
```

Expected log progression:
- websocket auth / subscribe succeeds
- oracle is discovered or created
- caps are registered
- oracle is activated
- price pushes land once per second
- SVI pushes land when fresher samples arrive

- [ ] **Step 5: Confirm local DB population**

Run:

```bash
psql -p 5433 postgres://postgres:postgres@localhost:5433/predict_v2 -c "select count(*) from oracle_created;"
psql -p 5433 postgres://postgres:postgres@localhost:5433/predict_v2 -c "select count(*) from oracle_prices_updated;"
psql -p 5433 postgres://postgres:postgres@localhost:5433/predict_v2 -c "select count(*) from oracle_svi_updated;"
```

Expected:
- all three counts are non-zero after the feed has been running for a bit

- [ ] **Step 6: Confirm API reads**

Run:

```bash
curl -s http://localhost:3000/health
curl -s http://localhost:3000/oracles
curl -s http://localhost:3000/status
```

Expected:
- health is OK
- oracles endpoint shows the active `15m` oracle
- status endpoint shows advancing watermarks

- [ ] **Step 7: Let the feed run through expiry**

Wait until the tracked `15m` oracle expires, then verify:

```bash
psql -p 5433 postgres://postgres:postgres@localhost:5433/predict_v2 -c "select oracle_id, expiry, settlement_price from oracle_settled order by checkpoint desc limit 5;"
```

Expected:
- at least one settlement row appears for the tracked oracle

- [ ] **Step 8: Verify compaction**

Watch logs and API state, then run:

```bash
curl -s http://localhost:3000/oracles
```

Expected:
- settled oracle is compacted and removed from active tracking
- manager loop creates the next `15m` oracle cleanly

- [ ] **Step 9: Commit final code changes**

```bash
git status --short
git add scripts/services/oracle-feed crates/predict-indexer/src/handlers.rs crates/predict-server/src/reader.rs scripts/config/constants.ts crates/predict-indexer/src/lib.rs
git commit -m "feat(predict): complete local testnet bring-up"
```
