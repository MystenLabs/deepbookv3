---
date: 2026-04-30
---

# Pitfalls Research — DeepBook v3 Improvements

## Database Migration Pitfalls

**P1: Index creation locks tables on large datasets**
- `CREATE INDEX` without `CONCURRENTLY` takes an `ACCESS EXCLUSIVE` lock — blocks all reads/writes
- Fix: Always use `CREATE INDEX CONCURRENTLY` in production migrations
- Warning sign: Migration takes >1s on dev — it will take minutes on prod tables
- Phase: Phase 1 (DB indexes)

**P2: `diesel_migrations` runs synchronously at startup**
- If the indexer/server runs migrations at boot, `CREATE INDEX CONCURRENTLY` will FAIL (it cannot run inside a transaction, and Diesel wraps migrations in transactions by default)
- Fix: Run index migrations separately via `psql` or a one-off migration runner that disables transaction wrapping
- Phase: Phase 1

**P3: Materialized view CONCURRENTLY requires a unique index**
- `REFRESH MATERIALIZED VIEW CONCURRENTLY` requires a unique index on the view
- If `net_deposits_hourly` doesn't have one, CONCURRENTLY will fail silently or fall back to blocking refresh
- Fix: Verify unique index exists before moving refresh to background task
- Phase: Phase 1

## Rust Refactoring Pitfalls

**P4: 17-tuple refactor breaks Diesel type inference**
- Changing `get_orders` from a tuple to a named struct requires updating Diesel's `QueryableByName` or `Queryable` derive — the tuple was chosen because Diesel infers tuple types automatically
- Fix: Use `#[derive(QueryableByName)]` with explicit `#[diesel(sql_type = ...)]` annotations on the new struct
- Phase: Phase 2

**P5: Axum state extraction changes when splitting routes**
- Moving handlers to sub-modules changes how `Extension` or `State` extractors resolve
- If `server.rs` uses `Extension<Arc<Reader>>` but sub-modules expect `State<AppState>`, compile errors are non-obvious
- Fix: Migrate to `axum::extract::State<AppState>` (the modern pattern) before splitting; define `AppState` first
- Phase: Phase 2

**P6: `f64` → `Decimal` migration breaks Diesel serialization**
- Diesel's `f64` ↔ PostgreSQL `float8` mapping is automatic; `Decimal` requires the `numeric` feature and explicit `diesel::sql_types::Numeric` annotations
- The codebase already has `bigdecimal` in schema models — adding `rust_decimal` creates two competing decimal types
- Fix: Use `bigdecimal` consistently (already in deps) rather than adding `rust_decimal`
- Phase: Phase 2/5

## SDK Development Pitfalls

**P7: OpenAPI annotation drift**
- `utoipa` derive macros must be kept in sync with actual handler signatures
- If a handler changes its request/response shape without updating `#[utoipa::path]`, the generated spec is wrong silently
- Fix: Add a CI test that generates the spec and diffs against a committed `openapi.json`
- Phase: Phase 3

**P8: TypeScript client versioning**
- Auto-generated TS clients from OpenAPI break on every schema change
- Fix: Semantic version the client; generate from a pinned `openapi.json` snapshot; never auto-publish from CI without a version bump
- Phase: Phase 4

**P9: SDK breaking changes with no deprecation path**
- `@mysten/deepbook-v3` is likely used by external integrators; breaking changes break their code
- Fix: Add `@deprecated` JSDoc annotations + new methods before removing old ones; semver major bump for breaking changes
- Phase: Phase 4

## Performance Fix Pitfalls

**P10: Cache invalidation on pool config changes**
- If pool metadata is cached in `moka`, a pool parameter update (tick size, lot size) won't be visible until cache TTL expires
- Fix: Expose a cache invalidation endpoint in the admin API; or use event-driven invalidation when the indexer processes a `PoolConfigUpdated` event
- Phase: Phase 2

**P11: Asset normalization backfill**
- Adding a `asset_normalized` column to `balances` requires a one-time backfill of all existing rows
- On large tables this is a long-running UPDATE that can bloat the table
- Fix: Add column with `NOT NULL DEFAULT ''`, backfill in batches of 10k rows, then add index; don't backfill in a migration
- Phase: Phase 1/2

## Warning Signs (Early Detection)

| Warning | Likely cause | Action |
|---------|-------------|--------|
| Migration hangs > 30s | Missing CONCURRENTLY | Kill, fix, re-run |
| `REFRESH MATERIALIZED VIEW` error in logs | Missing unique index | Create unique index first |
| Portfolio endpoint P99 not improving after index add | Leading-wildcard LIKE still in use | Verify normalization migration ran |
| OpenAPI spec differs between deploys | Annotation drift | Add CI spec diff check |
| TypeScript client type errors after server update | Schema changed, client not regenerated | Trigger client regen in CI |
| `moka` cache hit rate < 50% | TTL too short or key cardinality too high | Instrument cache hits/misses |
