---
date: 2026-04-30
---

# Architecture Research — DeepBook v3 Scalability

## Indexer Architecture Patterns

**Current:** 54 separate handler files, each implementing `MoveStruct` trait with identical boilerplate.

**Recommended refactoring approaches (pick one):**

1. **Declarative macro registry** (recommended):
```rust
define_handlers! {
    OrderFill => { module: "pool", name: "OrderFilled", table: order_fills },
    PoolCreated => { module: "pool", name: "PoolCreated", table: pool_created },
    // ...
}
```
Generates the handler struct + trait impl + DB write at compile time. Reduces 54 files to ~1 macro invocation + a model definition per event.

2. **Trait object dispatch table**: Single `HashMap<EventKey, Box<dyn EventHandler>>` registered at startup. Less boilerplate, but loses type-safety and makes adding handlers runtime rather than compile-time.

3. **Code generation (build.rs)**: Generate handler files from a TOML manifest. More complex but preserves one-file-per-handler structure while eliminating manual duplication.

## Database Scalability Patterns

**Immediate wins (no schema changes):**
- `CREATE INDEX CONCURRENTLY idx_asset_supplied_sender ON asset_supplied(sender)`
- `CREATE INDEX CONCURRENTLY idx_asset_withdrawn_sender ON asset_withdrawn(sender)`
- Add normalized `asset_normalized TEXT` column to `balances` with functional index (eliminates leading-wildcard LIKE)
- Move `REFRESH MATERIALIZED VIEW CONCURRENTLY` to background task

**Medium-term (if table size becomes concern):**
- Partition `order_fills` and `order_updates` by `checkpoint_timestamp_ms` range (monthly)
- PostgreSQL native partitioning — transparent to Diesel queries
- Archive tables older than rolling window to cold storage

**Indexer write performance:**
- Batch INSERTs per checkpoint (already likely done by `sui-indexer-alt-framework`)
- Verify `ON CONFLICT DO NOTHING` on all handlers (idempotent replay)

## Server Refactoring Patterns

**Split `server.rs` monolith by domain:**
```
crates/server/src/
├── routes/
│   ├── mod.rs          // merge all sub-routers
│   ├── pools.rs        // /get_pools, /pool_created, /orderbook, /ohclv
│   ├── orders.rs       // /trades, /order_updates, /orders, /orders_status
│   ├── portfolio.rs    // /portfolio, /deposited_assets, /get_net_deposits
│   ├── margin.rs       // all margin_* endpoints
│   ├── points.rs       // /get_points, /trade_count, /referral_fee_events
│   └── health.rs       // /status
```

Each module: `pub fn router(state: AppState) -> Router`. Merge in `mod.rs`.

**Shared state pattern:**
```rust
#[derive(Clone)]
struct AppState {
    reader: Arc<Reader>,
    cache: Arc<moka::future::Cache<String, CachedResponse>>,
    metrics: Arc<RpcMetrics>,
}
```

## SDK Architecture Patterns

**TypeScript indexer HTTP client** — two viable approaches:

1. **Auto-generate from OpenAPI** (recommended long-term): Add `utoipa` to server → generate `openapi.json` → run `openapi-ts` codegen → publish `@mysten/deepbook-indexer-client`

2. **Hand-craft typed client** (faster short-term):
```typescript
export class DeepBookIndexerClient {
  constructor(private baseUrl: string) {}
  
  async getPools(): Promise<Pool[]> { ... }
  async getTrades(poolName: string, params: TradeParams): Promise<Trade[]> { ... }
  async getPortfolio(walletAddress: string): Promise<Portfolio> { ... }
}
```

## Suggested Build Order / Dependencies

```
Phase 1: DB indexes + MV refresh (no code changes, just migrations + background task)
    ↓
Phase 2: Named struct + server.rs split (ergonomics, enables Phase 3 safely)
    ↓
Phase 3: OpenAPI docs (requires structured handlers from Phase 2)
    ↓
Phase 4: TS indexer HTTP client (generated from Phase 3 OpenAPI spec)
    ↓
Phase 5: Handler macro/code-gen + test coverage (architectural improvements)
```

Phase 1 delivers the most performance impact with the least risk. Each phase is independently deployable.
