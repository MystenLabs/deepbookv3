---
date: 2026-04-29
focus: concerns
---

# Concerns

## Performance

### P1 — Sequential scans from leading-wildcard LIKE

**Location:** `crates/server/src/reader.rs` — `get_portfolio()` and related queries
**Code comment explicitly flags this:**
```sql
-- TODO: leading '%' wildcard prevents B-tree index use on balances.asset, causing a
-- sequential scan for wallets with many balance events.
LEFT JOIN asset_meta am ON b.asset LIKE '%' || SUBSTRING(am.asset_id FROM 3) || '%'
```
Same pattern used in collateral query and LP query. Affects any portfolio lookup.
**Impact:** Full table scan on `balances` per wallet query. Will degrade as `balances` table grows.
**Fix:** Add normalized asset column with a proper index, or use a functional index.

### P2 — Missing indexes on `asset_supplied` and `asset_withdrawn`

**Location:** `crates/server/src/reader.rs` — LP query in `get_portfolio()`
**Code comment:**
```sql
-- Filters on sender (wallet address). Note: asset_supplied/asset_withdrawn do not have
-- an index on sender; a future migration adding idx_asset_supplied_sender and
-- idx_asset_withdrawn_sender would improve performance at scale.
```
**Impact:** LP position lookups scan entire tables.
**Fix:** Add `CREATE INDEX idx_asset_supplied_sender ON asset_supplied(sender)` migration.

### P3 — Materialized view refreshed on every request

**Location:** `crates/server/src/reader.rs:1283`
```rust
let _ = diesel::sql_query("REFRESH MATERIALIZED VIEW CONCURRENTLY net_deposits_hourly")
    .execute(&mut connection)
    .await;
```
Called inside `get_net_deposits_from_view()` on every invocation. Even concurrent refresh has overhead.
**Impact:** Added latency on every net deposits query; potential DB contention at high request rates.
**Fix:** Schedule refresh as a background cron job separate from the request path.

### P4 — `f64` for financial calculations

**Location:** `crates/server/src/reader.rs` — all SQL queries return `f64` for USD amounts, balances, prices
**Example:**
```rust
ROUND(s.base_asset::numeric, 6)::float8 as base_asset,
```
**Impact:** Floating-point precision errors in financial display. Not a correctness issue for DeFi (raw amounts are `i64`), but can cause display artifacts (e.g., `0.9999999` instead of `1.0`).

### P5 — `server.rs` is ~1600+ lines (implied by file size)

**Location:** `crates/server/src/server.rs`
All route handlers are likely co-located. As the API grows, this becomes a maintenance and compilation-time bottleneck.

### P6 — DB connection acquired per request, not pooled optimally

**Location:** `crates/server/src/reader.rs`
```rust
let mut conn = self.db.connect().await?;
```
Called at the start of each individual query method. For compound queries (like `get_portfolio` which runs 3 sub-queries sequentially), a new connection may be acquired 3 times. `bb8` pool mitigates this but connection acquisition adds overhead.

## Developer Experience

### DX1 — 17-tuple return type in `get_orders`

**Location:** `crates/server/src/reader.rs:299`
```rust
pub async fn get_orders(...) -> Result<Vec<(String, String, String, String, i64, i64, i64, i64, i64, i64, bool, String, String, bool, bool, i64, i64)>, DeepBookError>
```
Unmaintainable — impossible to read without counting. Should be a named struct.

### DX2 — 54+ boilerplate handler files

**Location:** `crates/indexer/src/handlers/`
Each of 54+ event handler files follows identical structure. Adding a new event requires creating a new file manually with near-identical boilerplate. No macro or code-gen to reduce repetition.

### DX3 — No TypeScript SDK for DeepBook

Scripts in `scripts/transactions/` manually construct PTBs for each operation. Developers integrating with DeepBook must understand raw transaction building. A typed TS client SDK would dramatically improve DX for ecosystem builders.

### DX4 — No test suite for scripts

`package.json` has `"test": "echo \"Error: no test specified\" && exit 1"`. All 40+ transaction scripts are untested.

### DX5 — Git-pinned Sui dependencies

```toml
sui-futures = { git = "https://github.com/MystenLabs/sui.git", branch = "testnet" }
```
Branch-pinned git deps mean Cargo always fetches latest from the branch. No reproducible builds without `Cargo.lock`. Upgrading Sui requires manual branch testing.

### DX6 — No OpenAPI / schema documentation for REST API

The Axum server has no auto-generated API docs (no `utoipa`, `aide`, or similar). API consumers must read source code to understand endpoints and response shapes.

## Security

### S1 — Admin API key comparison

**Location:** `crates/server/src/admin/auth.rs`
Uses `subtle` crate for constant-time comparison — correct approach. Risk: if API key is passed via query param or URL (vs header), it may be logged.

### S2 — No input sanitization story for SQL queries

All parameterized via Diesel — SQL injection is not a concern. However, the `to_pattern()` function converts empty strings to `%` which silently changes query semantics. A caller passing `""` intending "no results" gets "all results" instead.

### S3 — `wallet_address` validation in `get_portfolio`

Validates `0x` prefix + 64 hex chars. Good. But validation happens in `reader.rs` (data layer) rather than at the route handler (API layer) — wrong layer for input validation.

## Technical Debt

### TD1 — LP share approximation (~3-4% error)

**Location:** `crates/server/src/reader.rs:1445` (code comment)
```
// NOTE: LP positions use flow-based approximation (cumulative supply - withdraw).
// This does not account for interest accrual on lending positions (~3-4% undercount).
// This will be resolved once margin_pool_snapshots is populated in production.
```
LP position values shown to users are systematically underreported.

### TD2 — `margin_pool_snapshots` table not yet populated

Referenced in the LP approximation note above. The proper snapshot-based LP calculation is blocked on this table being populated.

### TD3 — Asset ID prefix stripping (`0x` normalization)

Multiple queries strip or add `0x` prefixes to normalize asset IDs:
```rust
let cleaned_assets: Vec<String> = asset_ids.iter()
    .map(|a| a.strip_prefix("0x").unwrap_or(a).to_string())
    .collect();
```
This normalization is scattered across multiple queries with inconsistent patterns. Should be centralized.

### TD4 — No margin/predict package test coverage confirmed

`deepbook_margin` and `predict` are significant packages with complex financial logic (liquidations, oracle pricing, prediction market settlement) but no confirmed test coverage.

### TD5 — `server.rs` monolith

All route handlers in a single large file. Standard Axum pattern would split into feature-based modules.

## Fragile Areas

| Area | Fragility | Reason |
|------|----------|--------|
| Multi-version event matching | Medium | New package deployment requires manual address updates in `lib.rs` |
| OHCLV stored function | High | Logic lives in DB, not in version control visible to the indexer — drift risk |
| Materialized view refresh timing | Medium | If refresh fails silently, net deposits data goes stale |
| `f64` price arithmetic | Low-Medium | Acceptable for display but wrong for any future on-server financial calculations |
| 17-tuple `get_orders` return | High | Breaking to change; adding a new column requires touching all call sites |
