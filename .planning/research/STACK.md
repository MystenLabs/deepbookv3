---
date: 2026-04-30
source: official docs + training knowledge
---

# Stack Research — DeepBook v3 Improvements

## Recommended Stack (2025)

The existing stack is well-chosen. Changes are additive — not replacements.

| Component | Current | Recommended Addition | Confidence |
|-----------|---------|---------------------|-----------|
| HTTP framework | Axum 0.7 | + `utoipa 4.x` + `utoipa-axum` for OpenAPI | HIGH |
| DB ORM | Diesel 2.2 + diesel-async | No change; add missing indexes via migrations | HIGH |
| Connection pool | bb8 (via sui-pg-db) | Refactor compound queries to reuse single connection | HIGH |
| Caching | None | `moka 0.12` (Tokio-native async cache) | MEDIUM |
| Financial precision | `f64` in API layer | `rust_decimal` or reuse existing `bigdecimal` dep | MEDIUM |
| Background tasks | tokio::spawn (partial) | `tokio::time::interval` + `MissedTickBehavior::Skip` for view refresh | HIGH |
| TS SDK | Scripts only | `@mysten/deepbook-v3` already exists — extend coverage | HIGH |

## Rust Performance Libraries

### Connection Management
- **Issue**: `reader.rs` calls `self.db.connect().await?` at the start of each method
- **Fix**: For compound queries (e.g., `get_portfolio` runs 3 sub-queries), acquire one connection at the caller and pass `&mut AsyncPgConnection` through
- **Pattern**:
  ```rust
  // Current: 3 connection acquisitions
  let margin = self.get_margin_positions(wallet).await?;
  let collateral = self.get_collateral(wallet).await?;
  let lp = self.get_lp_positions(wallet).await?;
  
  // Better: 1 connection for all 3
  let mut conn = self.db.connect().await?;
  let margin = get_margin_positions(&mut conn, wallet).await?;
  // ...
  ```

### In-Process Caching (`moka 0.12`)
```toml
moka = { version = "0.12", features = ["future"] }
```
- Pool metadata (`/get_pools`): 60s TTL — changes rarely
- Ticker/summary: 10s TTL — high-read, low-write
- Completed OHLCV candles (past hours): indefinite TTL
- **Do NOT cache**: per-wallet portfolio, order status, net deposits

### Background Materialized View Refresh
```rust
// In server startup:
tokio::spawn(async move {
    let mut interval = tokio::time::interval(Duration::from_secs(60));
    interval.set_missed_tick_behavior(MissedTickBehavior::Skip);
    loop {
        interval.tick().await;
        let _ = diesel::sql_query("REFRESH MATERIALIZED VIEW CONCURRENTLY net_deposits_hourly")
            .execute(&mut conn).await;
    }
});
```
Refresh intervals: `net_deposits_hourly` → 60s, `ohclv_1m` → 30s, `ohclv_1d` → 300s.

## OpenAPI Tooling for Axum 0.7

**Recommended: `utoipa 4.x` + `utoipa-axum`**

```toml
utoipa = { version = "4", features = ["axum_extras"] }
utoipa-axum = "0.1"
utoipa-swagger-ui = { version = "7", features = ["axum"] }
```

- `utoipa-axum` was added specifically for Axum 0.7 router integration
- Derive macros: `#[derive(ToSchema)]` on models, `#[utoipa::path(...)]` on handlers
- Zero runtime cost — docs generated at compile time
- Serves Swagger UI at `/swagger-ui/`

**Alternative: `aide`** — requires wrapping `axum::Router` with `aide::axum::ApiRouter`. Higher refactor cost for 50+ existing handlers. Not recommended for this codebase.

## TypeScript SDK Landscape

**Official SDK: `@mysten/deepbook-v3`**
```sh
npm install @mysten/deepbook-v3
```

**What it covers (confirmed):**
- Balance manager: create, deposit, withdraw, check balance, mint trade cap
- Orders: `placeLimitOrder`, `placeMarketOrder`, `cancelOrder`, `cancelOrders`, `cancelAllOrders`, `modifyOrder`, `withdrawSettledAmounts`
- Pool queries: `getLevel2Range` (order book depth)
- Referrals: full CRUD
- Staking/governance (per SDK docs index)
- Swaps, flash loans (per SDK docs index)

**What it does NOT cover (gaps for ecosystem builders):**
- Margin trading (`deepbook_margin` package operations)
- Prediction markets (`predict` package)
- Indexer API queries (no typed HTTP client for the REST API)
- Batch operations / PTB composition helpers
- Error type definitions for contract errors

**Indexer REST API:** No official TypeScript client. Developers must build raw HTTP calls against `deepbook-indexer.mainnet.mystenlabs.com`.

## Materialized View Refresh Patterns

**Pattern: Background tokio task (recommended for this codebase)**
- Pro: Already have tokio runtime, zero new dependencies
- Pro: `MissedTickBehavior::Skip` prevents refresh storms on lag
- Con: Refresh tied to server process lifetime — if server crashes, refresh stops
- Mitigation: Use `REFRESH MATERIALIZED VIEW CONCURRENTLY` (non-blocking, continues if already refreshing)

**Pattern: pg_cron extension (alternative)**
- Pro: DB-native, survives server restarts
- Con: Requires PostgreSQL extension, ops complexity
- Not recommended for this codebase

## Confidence Levels

| Finding | Confidence | Verified by |
|---------|-----------|------------|
| `@mysten/deepbook-v3` npm package exists | HIGH | Official Sui docs |
| SDK covers core order operations | HIGH | Official SDK docs |
| Indexer API endpoints list | HIGH | Official indexer docs |
| `utoipa-axum` for Axum 0.7 | HIGH | Library docs |
| `moka 0.12` async cache | MEDIUM | Training knowledge (2025) |
| Indexer has no official TS HTTP client | HIGH | Docs show no such package |
| SDK does NOT cover margin/predict | HIGH | SDK docs only list core ops |
