# Requirements — DeepBook v3 Performance, Scalability & DX

## v1 Requirements

### Performance — Database
- [ ] **PERF-01**: Database migration adds `CREATE INDEX CONCURRENTLY idx_asset_supplied_sender ON asset_supplied(sender)` and `idx_asset_withdrawn_sender ON asset_withdrawn(sender)` to eliminate sequential scans on LP queries
- [ ] **PERF-02**: `balances` table gains a normalized `asset_normalized` column with a B-tree index, replacing the leading-wildcard `LIKE '%...%'` pattern in portfolio queries
- [ ] **PERF-03**: `REFRESH MATERIALIZED VIEW CONCURRENTLY net_deposits_hourly` is moved out of the `get_net_deposits_from_view` request path into a `tokio::time::interval` background task
- [ ] **PERF-04**: `get_portfolio` acquires a single `AsyncPgConnection` and passes it through all 3 sub-queries instead of calling `self.db.connect()` three times
- [ ] **PERF-05**: Pool metadata and ticker responses are cached in-process (`moka`) with appropriate TTLs (pool metadata: 60s, ticker: 10s)

### Scalability — Server
- [ ] **SCALE-01**: `crates/server/src/server.rs` is split into domain sub-modules under `crates/server/src/routes/` (pools, orders, portfolio, margin, points, health) each exposing a `router(state: AppState) -> Router` function
- [ ] **SCALE-02**: `get_orders` return type is changed from a 17-tuple to a named `OrderFill` struct with `#[derive(QueryableByName, Serialize)]`
- [ ] **SCALE-03**: Asset ID `0x`-prefix normalization is centralized in a single `normalize_asset_id(s: &str) -> String` utility function used by all affected queries

### Scalability — Indexer
- [ ] **SCALE-04**: At least one indexer handler is refactored as proof-of-concept for a declarative macro that generates the boilerplate (`MoveStruct` impl + DB write) from a compact declaration

### Developer Experience — API
- [ ] **DX-01**: OpenAPI 3.0 specification is generated via `utoipa` and served at `/swagger-ui/` — covers all public REST endpoints with request params and response schemas
- [ ] **DX-02**: A typed TypeScript HTTP client for the indexer REST API is published (or added to `scripts/`) covering the 15 most-used endpoints (`/get_pools`, `/trades`, `/orderbook`, `/ohclv`, `/portfolio`, `/orders`, `/ticker`, `/summary`, `/assets`, `/order_updates`, `/deposited_assets`, `/get_net_deposits`, `/get_points`, `/status`, `/deep_supply`)
- [ ] **DX-03**: Input validation (wallet address format, timestamp range, limit bounds) is moved from `reader.rs` to Axum route extractors or middleware

### Developer Experience — Testing
- [ ] **DX-04**: Integration test suite added for the 5 highest-traffic server endpoints (`/get_pools`, `/trades/:pool_name`, `/orderbook/:pool_name`, `/portfolio/:wallet_address`, `/status`) using a test PostgreSQL instance
- [ ] **DX-05**: `packages/deepbook_margin` gains basic Move unit tests covering: margin manager creation, deposit/withdraw collateral, borrow/repay loan, and liquidation trigger

### Developer Experience — Tooling
- [ ] **DX-06**: `CLAUDE.md` is updated to reflect the new module structure, testing instructions, and any new build commands introduced during this initiative

## v2 Requirements (deferred)

- Indexer handler macro covering all 54 handlers (v1 is proof-of-concept only)
- `packages/predict` Move test coverage
- TypeScript SDK extensions for margin/predict operations
- Per-endpoint HTTP latency Prometheus histograms (beyond current DB-level metrics)
- `margin_pool_snapshots` table population (blocked on separate data pipeline work)
- Table partitioning for `order_fills` and `order_updates`

## Out of Scope

- On-chain Move contract logic changes — requires full security audit
- New financial products (pool types, margin parameters, liquidation rules)
- Redis caching layer — in-process `moka` is sufficient for this workload
- GraphQL API — REST is established and working
- Kubernetes / infrastructure changes — ops team scope
- `margin_pool_snapshots` population — tracked separately

## Traceability

| Req ID | Phase | Status |
|--------|-------|--------|
| PERF-01 | Phase 1: DB Performance | Pending |
| PERF-02 | Phase 1: DB Performance | Pending |
| PERF-03 | Phase 1: DB Performance | Pending |
| PERF-04 | Phase 1: DB Performance | Pending |
| PERF-05 | Phase 2: Server Ergonomics | Pending |
| SCALE-01 | Phase 2: Server Ergonomics | Pending |
| SCALE-02 | Phase 2: Server Ergonomics | Pending |
| SCALE-03 | Phase 2: Server Ergonomics | Pending |
| DX-03 | Phase 2: Server Ergonomics | Pending |
| DX-01 | Phase 3: OpenAPI Docs | Pending |
| DX-02 | Phase 4: TypeScript Client | Pending |
| SCALE-04 | Phase 5: DX & Testing | Pending |
| DX-04 | Phase 5: DX & Testing | Pending |
| DX-05 | Phase 5: DX & Testing | Pending |
| DX-06 | Phase 5: DX & Testing | Pending |
