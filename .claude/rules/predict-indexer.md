---
paths:
  - "crates/predict-server/**"
  - "crates/predict-indexer/**"
  - "crates/predict-schema/**"
---

# Predict Indexer / Server Rules

Read this when editing `crates/predict-schema/**`, `crates/predict-indexer/**`, or `crates/predict-server/**`. These crates index the Predict package's on-chain events into Postgres and serve them over HTTP. They **mirror** the core DeepBook crates (`crates/{schema,indexer,server}`) but are independent and intentionally improve on a few core patterns. When a rule here conflicts with what core does, this file wins **for Predict crates only** — do not change core to match, and do not copy core's known weaknesses forward.

Also read `.claude/rules/indexer.md` (shared operational gotchas: migrations can't use `CREATE INDEX CONCURRENTLY`, `IF NOT EXISTS` for idempotency, 3 connection pools, the `to_timestamp()::timestamp` cast).

## Crate Layout (mirror core exactly)

- `predict-schema` — **lib** crate. Diesel `embed_migrations!`, generated `schema.rs`, `models.rs`. Mirrors `crates/schema`.
- `predict-indexer` — **binary**. Event handlers, `PredictEventMeta`, `PredictEnv`, the handler macro, `main.rs` bootstrap, materialized-view refresh. Mirrors `crates/indexer`.
- `predict-server` — **binary**. `Reader`, routes, `/status`, `/health`. Mirrors `crates/server`.
- Same Postgres DB as core, **separate tables**, separate indexer process, separate watermark namespace (pipeline names are unique). Core crates stay untouched.

## Mirror Core Verbatim (do not reinvent)

Copy these patterns directly from core; they are good as-is:
- The `define_handler!` macro shape (`crates/indexer/src/handlers/mod.rs`) → `define_predict_handler!` (only the env/meta/schema-path differ).
- Module-per-handler under `handlers/`, registered in `main.rs`.
- `/status` watermark-lag mechanics and `/health` (`crates/server/src/server.rs` `status()` / `health_check()`) — reuse unchanged; the `watermarks` table is framework-level.
- `embed_migrations!`, run at indexer startup via `store.run_migrations`.
- The materialized-view refresh `Service` (`crates/indexer/src/materialized_view_refresh.rs`) — `REFRESH MATERIALIZED VIEW CONCURRENTLY` on a ticker.
- `Reader` generic `results()`/`first()` helpers and `Db::for_read`; `DeepBookError` (rename to `PredictError`).
- The decode-struct conventions (`#[derive(Debug,Clone,Serialize,Deserialize)]` mirroring Move field order; `ObjectID` for `ID`, `sui_sdk_types::Address` for `address`, `u64`/`bool`; `MoveStruct` trait with `const MODULE`/`const NAME`).

## Deviations From Core (intentional improvements — each fixes a known core defect)

### 1. Total intra-checkpoint ordering via `tx_index` + `event_index`
Core `EventMeta` has only `event_index` (per-tx) and orders series by `checkpoint_timestamp_ms`, which **ties within a checkpoint**. `PredictEventMeta` adds `tx_index` (the transaction's position in the checkpoint, from `.enumerate()` over `checkpoint.transactions`). **Every raw table carries `tx_index BIGINT` + `event_index BIGINT`**. The `(checkpoint, tx_index, event_index)` triple is stored and is the **only total order**: checkpoint timestamps are non-decreasing, not strictly increasing, so two *different* checkpoints can share a `checkpoint_timestamp_ms` and `tx_index` (a per-checkpoint position) is meaningless across them. Windowed feeds order by `(checkpoint_timestamp_ms DESC, checkpoint DESC, tx_index DESC, event_index DESC)` — `checkpoint` must appear before `tx_index`; top-1 "latest"/current-state queries can order by `(checkpoint DESC, tx_index DESC, event_index DESC)` alone. **Never order an event series by a domain timestamp** (`source_timestamp_ms`): a stale-but-later-landing oracle update can carry an older source timestamp. PK stays the synthetic `event_digest` (`digest + event_index`, already unique).

### 2. No lossy `as i64`
Core casts every Move `u64 as i64` into `BIGINT`, which silently wraps at ≥2⁶³. **Never `as i64` a Move `u64`/`u128`/`u256` without a documented protocol bound.** Decide per field:
- **`TEXT`** — u256 ids (`order_id`, `position_root_id`, `replacement_order_id`) and any `ID`/`address`.
- **`NUMERIC` (→ `BigDecimal`)** — DUSDC monetary amounts, share/supply totals, NAV, strike/settlement prices, and any u64 without a clear small bound. Strike/settlement prices can carry the `pos_inf()` = `u64::MAX` sentinel for open-ended ranges, so they MUST be NUMERIC (never `as i64`, which wraps `u64::MAX` to `-1`).
- **`BIGINT`** — values with a real bound: 1e9-scaled ratios (`entry_probability`, `liquidation_ltv`), `leverage`, timestamps, `checkpoint`, `tx_index`, `event_index`, `expiry`, `feed_id`.

When you choose `BIGINT` for a u64, leave a one-line comment naming the bound. When unsure, use `NUMERIC`.

### 3. First-class u256 decoding
Core has no u256 (max type is u128 → `TEXT`). `serde`/`bcs` has no native u256. Decode a Move `u256` field as a fixed `[u8; 32]` (or a u256-capable type) in the decode struct, then convert to a decimal `String` for `TEXT` columns via a shared `u256_to_decimal_string(&[u8;32]) -> String` helper in `predict-indexer`. u256 ids are identifiers, not arithmetic — store as `TEXT`, never `NUMERIC`.

### 4. Honest event attribution
Core's `package` column = the PTB's **first MoveCall** package (`try_extract_move_call_package`), which is wrong when users route through an aggregator. Predict stores the **event's own type address** (`event.type_.address.to_string()`) as `package` — always the real emitting package. Set it in `PredictEventMeta` per event (it is available on `ev.type_`), not from the transaction's first command.

### 5. Timestamp-window pagination, sane defaults
Match core's **timestamp-window pagination** — `start_time`/`end_time` (unix seconds → ms) + `limit` — but with sane limit defaults. Default limit **50**, hard cap **500**, **NEVER default 1** (core's `ParameterUtil::limit()` footgun across 24 endpoints). `start_time` defaults to 0 (no lower bound), `end_time` defaults to now. Filter `checkpoint_timestamp_ms.between(start, end)`, order by `(checkpoint_timestamp_ms DESC, checkpoint DESC, tx_index DESC, event_index DESC)` (`checkpoint` before `tx_index` — see deviation 1), and index each table on `(filter_id, checkpoint_timestamp_ms)`. (Keyset pagination with an opaque `(checkpoint, tx_index, event_index)` cursor was considered and dropped for consistency with the rest of the DeepBook API.)

### 6. Bounded current-state reads: top-1 scans by default, a maintained table only for set queries
Core's `/ticker`/`/summary` do `DISTINCT ON` + 24h scans that cause documented 504s. Predict's rule is **no unbounded scans on the hot path**, satisfied two ways:
- **"Latest X for one id"** reads (latest oracle price/SVI, latest config snapshot, latest vault `*_after` balances, latest settlement) are **top-1 index scans** over the raw tables (`ORDER BY (checkpoint_timestamp_ms, tx_index, event_index) DESC LIMIT 1` behind the `(id, checkpoint_timestamp_ms)` index — the server's `latest_row!` macro). The raw table stays the source of truth and there is no upsert machinery to get wrong. Do NOT build a maintained table for a need a top-1 scan answers; cross-event "current" rows need per-column-group LWW triples under out-of-order commits, which is exactly the complexity this rule avoids.
- **Set-membership queries** ("open orders for a manager/market") cannot be answered per-key and DO get an indexer-**maintained table**: `order_state` (the `order_state` pipeline folds all five order events; one row per packed order id, replacement rows synthesized from `LiveOrderRedeemed`). **Packed order/root ids are expiry-local** (`sequence` and `opened_at_ms` — checkpoint-quantized — are per-expiry, so two markets can produce the same id in one checkpoint): every key, conflict target, fold key, and join on a packed id MUST be the composite `(expiry_market_id, <id>)`, never the bare id.

### 7. Idempotent, order-correct maintained-table upserts
The framework reprocesses checkpoints **at-least-once** and concurrent pipelines can commit batches **out of order**, so a maintained-table upsert must be **idempotent and order-independent**. The `order_state` pattern: **write-once columns** (identity, entry facts, `replacement_order_id` — provided by exactly one event per order) use `COALESCE(existing, EXCLUDED)`; **mutable columns** (`status` + the triple) are last-write-wins via per-column `CASE WHEN (EXCLUDED.checkpoint, EXCLUDED.tx_index, EXCLUDED.event_index) >= (existing triple)`. Fold a batch to one row per key before the statement (Postgres rejects two `ON CONFLICT` rows for the same key in one INSERT) with merge semantics that mirror the SQL — keep the fold/merge as free functions with unit tests. A current-state row must never regress to an older event on reprocess. Append-only raw tables stay naturally idempotent via the `event_digest` PK + `on_conflict_do_nothing`.

## Materialized Views

- Basic analytics MV tables (vault NAV/PnL timeline, liquidation stats, funding/exposure) live here for quick local/quant tests; the real scale work is ClickHouse, so keep these few and simple.
- Every MV **must** have a `UNIQUE` index (required for `REFRESH ... CONCURRENTLY`). Register its name in `MATERIALIZED_VIEWS_TO_REFRESH` (`crates/predict-indexer/src/materialized_view_refresh.rs`).
- Build MVs over the raw tables, ordered by the `(checkpoint, tx_index, event_index)` triple.
- **Bound every time-bucketed MV to a 30-day trailing window** (`checkpoint_timestamp_ms >= EXTRACT(EPOCH FROM now())::BIGINT * 1000 - 2592000000`): `REFRESH` is a full recompute, so an unwindowed MV gets slower forever. Current MVs: `market_activity_1h`, `vault_flows_1h`, `liquidation_stats_1h`, `oracle_prices_1m` (windowed) and `position_cashflow` (keyed by position root, NOT windowed — revisit before mainnet). Bucket with integer math `(checkpoint_timestamp_ms / 3600000) * 3600000`, not `date_trunc`.

## Large tables / aggregation

- The raw append-only tables plus their `(filter_id, checkpoint_timestamp_ms)` indexes serve the **operational feeds** (market/manager order feeds) as bounded index range scans: cost is proportional to **rows-in-window**, independent of total table size.
- **Never aggregate over raw tables on the hot path.** For current-state reads (open positions, current market, latest oracle/config), use the indexer-maintained current-state tables (point lookups). For summaries/quant, use small time-bucketed MV rollups (M3). Full-scale analytics goes to ClickHouse.
- Future: time-partition + retention on the very large raw tables so the windowed feed scans stay bounded and old data can age out cheaply.
- **Pre-mainnet checklist item:** before the mainnet deploy, decide partitioning/retention for `block_scholes_prices_updated` and `pyth_source_updated` (the unbounded-growth tables) based on observed testnet ingest rates, and decide a window or ClickHouse hand-off for `position_cashflow`. Mainnet is a fresh deploy, so this is the free moment to add it.

## Testing Bar

- **Decode/map unit tests are the standing coverage** and need no deployment: hand-build the decoded Rust struct + a test `PredictEventMeta`, call the handler's free `map()` fn, assert the mapped row exactly (u256 → decimal string, `tx_index`/`event_index`/`position_root_id`, Option fields). Structure each handler so the mapping is a testable free function (`fn map(ev, meta) -> Row`), not only an inline macro closure.
- **Snapshot (`insta`) tests need a real testnet `.chk` fixture** (core downloads these from `checkpoints.testnet.sui.io`; see `crates/indexer/tests/README.md`). Predict has no deployment yet, so snapshot tests are scaffolded but **`#[ignore]`'d with a `TODO(testnet-deploy)`** until a fixture can be captured. Don't fake fixtures.
- **Every list endpoint** gets a window-pagination test (start/end bounds + default/cap limit) — runnable now via `TempDb`.
- **Every maintained/MV table** gets a reprocess-idempotency test: feed the same checkpoints twice, assert the current-state row is unchanged and never regresses.
- Apply `.claude/rules/unit-tests.md`: exact expected values, no circular logic (don't derive expected output from the code under test), name constants.

## Fail-Fast on Unset Package Address

Pre-deploy, the Predict package address is empty. `PredictEnv::package_addresses()` must **panic on an empty address** (not return empty, which would silently index nothing) with a message containing `TODO(testnet-deploy): set Predict package address`. This guards the **indexer only** — the server never reads the package address (it serves already-indexed rows), so it isn't affected. The panic fires on the **first checkpoint ingestion** (via `is_predict_tx` → `package_addresses`), not at process boot, aborting the indexer until the address is filled in after deploy.

## Pre-Push Checklist (per crate)

1. `cargo fmt -p predict-schema -p predict-indexer -p predict-server` — CI fails on formatting.
2. `cargo build -p predict-indexer -p predict-server` — catch compile errors.
3. `cargo test -p predict-indexer -p predict-server`.
4. New raw table → confirm: 7-col header + `tx_index` + `event_index`, composite index on `(checkpoint, tx_index, event_index)`, lookup-id indexes, `TEXT` for u256, `NUMERIC` for unbounded u64, and the matching `schema.rs` `table!` block + `models.rs` Insertable (omit the DB-default `timestamp`).

## Package Config

`PredictEnv` holds the Predict package addresses per env (sandbox/testnet/mainnet), mirroring `DeepbookEnv` (`crates/indexer/src/lib.rs`). The Predict address **must** be in `env.package_addresses()`/`package_ids()` or `is_predict_tx` skips every Predict tx (it checks input objects, events, and MoveCall package). Add a `ModuleType::Predict` arm in the address-resolution routing so Predict event types resolve across package versions.
