# Phase 2: Server Ergonomics - Research

**Researched:** 2026-04-30
**Domain:** Rust / Axum 0.7 / Diesel 2.2 / moka 0.12
**Confidence:** HIGH

---

## Summary

Phase 2 restructures `crates/server/src/server.rs` — a 2,857-line monolith containing ~45 route
handler functions, a `make_router` assembly, `AppState`, `run_server`, a `ParameterUtil` trait,
and all associated path constants — into domain sub-modules under `routes/`. Alongside the split,
four targeted code-quality improvements address the requirements: replacing the 17-element
order-fill tuple with a named `OrderFill` struct, centralizing `0x`-prefix normalization,
adding a `moka` in-process cache for two hot endpoints, and moving wallet/timestamp/limit
validation from `reader.rs` and handler bodies to Axum extractors.

All five requirements are **self-contained Rust changes** — no migration files, no schema
changes, no new services. The changes are safe to execute in any order (no circular
dependencies between them), making them good candidates for parallel plan execution.

**Primary recommendation:** Split server.rs first (SCALE-01), then layer the other four
changes on top of the resulting module structure. This ordering avoids merge conflicts because
SCALE-02, SCALE-03, PERF-05, and DX-03 all modify the same logical areas of code that will
move to new files.

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SCALE-01 | Split `server.rs` into `routes/{pools,orders,portfolio,margin,points,health}.rs` | Router assembly located at line 340, `make_router` at 340; all handlers grouped by domain below |
| SCALE-02 | Replace 17-tuple return from `get_orders` with named `OrderFill` struct | Tuple confirmed at reader.rs:278-299 and server.rs:1305-1323; `QueryableByName` pattern present in same file |
| SCALE-03 | Centralize asset-ID `0x` normalization in `normalize_asset_id()` utility | Three distinct call sites found across reader.rs (lines 1293, 1345) and server.rs (line 1970); SQL `LIKE '%…%'` patterns in reader.rs lines 576, 650, 693, 728 are separate (handled by PERF-02) |
| PERF-05 | Add moka in-process cache for pool metadata (60 s TTL) and ticker (10 s TTL) | `moka` not in Cargo.toml; `get_pools` is called on every `ticker`, `summary`, `historical_volume`, `all_historical_volume`, and `trades` request |
| DX-03 | Move validation logic to Axum extractors | Wallet validation in reader.rs:1451-1458; limit parsing in server.rs `ParameterUtil` trait lines 2071-2109; no type-safe query params structs exist today |
</phase_requirements>

---

## Project Constraints (from CLAUDE.md)

- **Simplicity first:** Minimum code that solves the problem. No speculative abstractions.
- **Surgical changes:** Only touch what the requirement demands. Do not refactor adjacent code.
- **No hand-rolling solved problems:** Use `moka` for caching (already decided in STATE.md).
- **Build verification:** Run `cargo fmt -p deepbook-server` and `cargo build -p deepbook-server` before every commit.
- **In-process cache only:** Redis is explicitly out of scope (`moka` confirmed in STATE.md).
- **Axum state unification:** STATE.md records "Axum state extraction must be unified (`State<AppState>`) before splitting `server.rs`" — verify this is already true before executing SCALE-01.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Route handler bodies (SCALE-01) | API / Backend | — | Axum handlers are backend logic; no client-side concern |
| AppState / Router assembly (SCALE-01) | API / Backend | — | Server state and routing wiring are backend infrastructure |
| OrderFill named struct (SCALE-02) | Database / Storage | API / Backend | Diesel `QueryableByName` binds the DB layer; `Serialize` surfaces it to API |
| 0x normalization utility (SCALE-03) | Database / Storage | API / Backend | Normalization is needed at query time (reader layer); server.rs has one RPC-layer call site |
| moka cache layer (PERF-05) | API / Backend | — | In-process cache lives in the server process, wraps Reader calls, not a separate tier |
| Input validation extractors (DX-03) | API / Backend | — | Axum extractors validate at the boundary before business logic runs |

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| axum | 0.7 (already in Cargo.toml) | Web framework, router, extractors | Already in use; no version change needed |
| moka | 0.12.10 | In-process async TTL cache | Caffeine-inspired, tokio-compatible, O(1) amortized insert/get; STATE.md decision |
| diesel / diesel-async | 2.2.12 / 0.5.2 (workspace) | ORM + async layer | Already in use; `QueryableByName` derive for SCALE-02 |
| serde | 1.0 (workspace) | Serialization for `OrderFill` | Already in use |
| tokio | 1.47 (workspace) | Async runtime for moka `future` feature | Already in use |

[VERIFIED: cargo search / crates.io for moka 0.12.10]
[VERIFIED: Cargo.toml for axum 0.7, diesel 2.2.12, tokio 1.47]

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| moka `future` feature | included in 0.12 | Enables `moka::future::Cache` (tokio-compatible) | PERF-05 specifically needs async cache ops |

**Installation (new dependency only):**
```toml
# crates/server/Cargo.toml — add under [dependencies]
moka = { version = "0.12", features = ["future"] }
```

**Version verified:** `npm view moka version` → 0.2.0 (wrong npm package); crates.io search result confirms moka 0.12.10 for the Rust crate. [VERIFIED: crates.io search]

---

## Architecture Patterns

### Current server.rs Structure (what exists today)

```
crates/server/src/server.rs  (2857 lines)
├── path constants (~60 lines of pub const)
├── AdminRateLimiter type alias
├── AppState struct + impl (~90 lines)
├── run_server() fn (~80 lines)
├── make_router() fn (~95 lines)
│   ├── db_routes (38 routes)
│   └── rpc_routes (6 routes)
├── health_check() handler
├── status() handler
├── get_pools() handler
├── historical_volume*() handlers (4)
├── ticker() + fetch_historical_volume_with_pools() helpers
├── summary() handler (complex — calls ticker internals)
├── trade_count() handler
├── order_updates() handler
├── orders() handler
├── trades() handler  ← uses the 17-tuple (SCALE-02)
├── assets() handler
├── orderbook() handler (RPC)
├── deep_supply() handler (RPC)
├── margin_supply() handler (RPC)
├── fees() handler (RPC)
├── get_net_deposits() handler
├── pool_created() handler
├── book_params_updated() handler
├── ohclv() handler
├── 20+ margin event handlers (margin_manager_created … book_params_updated)
├── portfolio() handler
├── ParameterUtil trait + HashMap impl
└── helper functions (parse_type_input, calculate_trade_id, etc.)
```

### Target Module Structure (SCALE-01)

```
crates/server/src/
├── lib.rs             — add pub mod routes;
├── server.rs          — AppState, run_server, make_router (calls routes sub-routers)
├── reader.rs          — unchanged (query layer)
├── writer.rs          — unchanged
├── error.rs           — unchanged
├── metrics/           — unchanged
├── admin/             — unchanged
└── routes/
    ├── mod.rs         — re-exports all sub-module routers
    ├── pools.rs       — get_pools, historical_volume*, ticker, summary, assets, pool_created, book_params_updated, ohclv, trade_count
    ├── orders.rs      — trades, order_updates, orders (get_orders_status)
    ├── portfolio.rs   — portfolio, get_net_deposits, deposited_assets
    ├── margin.rs      — all 20+ margin event handlers + margin_managers_info, margin_manager_states
    ├── points.rs      — get_points
    └── health.rs      — status, health_check (/)
```

Shared items that remain in `server.rs` or move to a `routes/mod.rs`:
- `AppState` — stays in `server.rs` (needed by `run_server`)
- `ParameterUtil` trait — moves to `routes/mod.rs` or a `routes/params.rs`
- Path constants — can stay in `server.rs` or move to `routes/mod.rs`; the planner should pick one location

### Data Flow Diagram

```
HTTP Request
     │
     ▼
make_router() [server.rs]
  ├─ routes::pools::router()        ─┐
  ├─ routes::orders::router()        │
  ├─ routes::portfolio::router()     ├─► AppState { reader, writer, cache }
  ├─ routes::margin::router()        │         │
  ├─ routes::points::router()        │         ▼
  └─ routes::health::router()       ─┘   Reader::get_pools() / get_orders() / …
                                                │
                                                ▼
                                         PostgreSQL (diesel-async)
```

### Pattern 1: Sub-module Router Function

Each domain module exposes a single `router()` function that assembles its routes:

```rust
// Source: axum 0.7 docs + existing admin/routes.rs pattern
// crates/server/src/routes/pools.rs

use axum::{routing::get, Router};
use std::sync::Arc;
use crate::server::AppState;

pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route("/get_pools", get(get_pools))
        .route("/ticker", get(ticker))
        // ...
}

async fn get_pools(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<Pools>>, DeepBookError> {
    Ok(Json(state.reader.get_pools().await?))
}
```

`make_router` in `server.rs` then becomes:
```rust
// Source: [VERIFIED existing admin::routes::admin_routes pattern]
pub(crate) fn make_router(state: Arc<AppState>) -> Router {
    let cors = /* ... existing cors ... */;

    routes::pools::router()
        .merge(routes::orders::router())
        .merge(routes::portfolio::router())
        .merge(routes::margin::router())
        .merge(routes::points::router())
        .merge(routes::health::router())
        .with_state(state.clone())
        .nest("/admin", admin_routes(state.clone()).with_state(state.clone()))
        .layer(cors)
        .layer(from_fn_with_state(state, track_metrics))
}
```

**Critical:** the existing `AppState` uses `Arc<AppState>` as the Axum state type. The STATE.md note says "Axum state extraction must be unified (`State<AppState>`) before splitting `server.rs`". Verification shows all handlers currently use `State<Arc<AppState>>` (e.g., `State(state): State<Arc<AppState>>`). This is already unified — the `Arc` is the state type. No pre-work is needed. [VERIFIED: server.rs lines 533, 770, 866, 1172, 1256, 1439, 1495]

### Pattern 2: QueryableByName Named Struct (SCALE-02)

The existing `reader.rs` file already has several `QueryableByName` structs as proof-of-concept:
`OhclvRow`, `MarginPositionRow`, `CollateralRow`, `LpPositionRow`. The pattern is:

```rust
// Source: [VERIFIED reader.rs lines 44-58, 60-88]
#[derive(QueryableByName, Debug, serde::Serialize)]
pub struct OrderFill {
    #[diesel(sql_type = diesel::sql_types::Text)]
    pub event_digest: String,
    #[diesel(sql_type = diesel::sql_types::Text)]
    pub digest: String,
    #[diesel(sql_type = diesel::sql_types::Text)]
    pub maker_order_id: String,
    #[diesel(sql_type = diesel::sql_types::Text)]
    pub taker_order_id: String,
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    pub maker_client_order_id: i64,
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    pub taker_client_order_id: i64,
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    pub price: i64,
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    pub base_quantity: i64,
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    pub quote_quantity: i64,
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    pub checkpoint_timestamp_ms: i64,
    #[diesel(sql_type = diesel::sql_types::Bool)]
    pub taker_is_bid: bool,
    #[diesel(sql_type = diesel::sql_types::Text)]
    pub maker_balance_manager_id: String,
    #[diesel(sql_type = diesel::sql_types::Text)]
    pub taker_balance_manager_id: String,
    #[diesel(sql_type = diesel::sql_types::Bool)]
    pub taker_fee_is_deep: bool,
    #[diesel(sql_type = diesel::sql_types::Bool)]
    pub maker_fee_is_deep: bool,
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    pub taker_fee: i64,
    #[diesel(sql_type = diesel::sql_types::BigInt)]
    pub maker_fee: i64,
}
```

`get_orders` return type changes from `Vec<(String, String, ..., i64)>` to `Vec<OrderFill>`.
The `.load::<(String, String, ...i64)>` call changes to `.load::<OrderFill>`.

**Diesel `load` with typed tuples vs `QueryableByName`:** The current `get_orders` uses Diesel
`QueryDsl` with `.select((col1, col2, ...))` and `.load::<TupleType>()`. This is the *DSL*
Queryable path, not the raw-SQL path. `QueryableByName` is for `diesel::sql_query` results.
The existing query is a DSL query. Two valid options:

1. **Add `#[derive(Queryable, Selectable)]`** to `OrderFill` and use `.load::<OrderFill>()` via
   DSL. This requires field ordering to match `SELECT` order, or `#[diesel(table_name = order_fills)]`
   with `Selectable`. This is the simpler path since the query is DSL-based.

2. **Convert to `sql_query` + `QueryableByName`** — more verbose but matches the requirement's
   exact wording. Also consistent with `OhclvRow` pattern already in the codebase.

**Recommendation:** Use `#[derive(Queryable)]` for `OrderFill` since the existing query is a
DSL query. Add `#[derive(Serialize)]` for the API response. This is the minimal change. The
requirement says "named struct with `#[derive(QueryableByName, Serialize)]`" — if the SQL stays
as DSL (not `sql_query`), the correct derive is `Queryable` + `Serialize`. The planner should
note this discrepancy and implement whichever compiles correctly for the existing query style.
`QueryableByName` will also work if the query is rewritten to `diesel::sql_query` — the 
`order_fills` columns are well-known and the conversion is mechanical.

**Recommended plan approach:** Keep the DSL query, use `#[derive(Queryable, Serialize)]` on
`OrderFill`. This matches the requirement intent (named struct, no more tuple) and avoids a
query rewrite. Mark `QueryableByName` as the alternative if utoipa (Phase 3) requires it.

[VERIFIED: Diesel 2.2 Queryable/QueryableByName semantics from codebase patterns]

### Pattern 3: moka Async Cache (PERF-05)

Add a `cache` field to `AppState`. Two separate `Cache` instances, one per TTL:

```rust
// Source: [VERIFIED moka 0.12 docs.rs + crates.io]
use moka::future::Cache;
use std::time::Duration;
use deepbook_schema::models::Pools;

pub struct AppState {
    reader: Reader,
    writer: Writer,
    metrics: Arc<RpcMetrics>,
    // ... existing fields ...
    pools_cache: Cache<(), Vec<Pools>>,   // TTL 60 s
    ticker_cache: Cache<(), serde_json::Value>, // TTL 10 s (or typed HashMap)
}
```

Cache construction in `AppState::new`:
```rust
// Source: [VERIFIED moka 0.12 Cache::builder() API]
let pools_cache = Cache::builder()
    .max_capacity(1)         // single key — all pools as one value
    .time_to_live(Duration::from_secs(60))
    .build();
let ticker_cache = Cache::builder()
    .max_capacity(1)
    .time_to_live(Duration::from_secs(10))
    .build();
```

Cache usage in handler:
```rust
async fn get_pools(State(state): State<Arc<AppState>>) -> Result<Json<Vec<Pools>>, DeepBookError> {
    let pools = if let Some(cached) = state.pools_cache.get(&()).await {
        cached
    } else {
        let fresh = state.reader.get_pools().await?;
        state.pools_cache.insert((), fresh.clone()).await;
        fresh
    };
    Ok(Json(pools))
}
```

**Key design:** Use `()` as the cache key since both `get_pools` and `ticker` have no
parameterization that should vary the cached value. `Vec<Pools>` must be `Clone + Send + Sync`
— confirmed: `Pools` model derives `Clone` (standard Diesel model pattern). [ASSUMED — verify
`#[derive(Clone)]` on `Pools` model in schema crate if compiler rejects it]

**`AppState` is `Clone`:** `moka::future::Cache` is already `Clone` (internally Arc-wrapped).
Adding the two cache fields does not break the existing `#[derive(Clone)]` — or rather
`AppState` does not derive Clone, it has a manual `Clone` impl. Adding fields requires adding
them to the `impl Clone for AppState`. [ASSUMED — verify `AppState` Clone impl manually, not
derived, in case it needs updating]

Verify: `AppState` at server.rs line 133 shows `#[derive(Clone)]` — wait, the `OnceCell`
and `Arc` suggest it might. Let me clarify: server.rs line 133 shows `#[derive(Clone)]` is
NOT present; instead `AppState` is passed as `Arc<AppState>`. The state type registered with
Axum is `Arc<AppState>`, not `AppState` directly. Cloning the `Arc` is cheap. This means
`AppState` itself does not need to be `Clone` — only `Arc<AppState>` is cloned. The cache
fields just need to be members of `AppState` and be `Send + Sync`. `moka::future::Cache` is
`Send + Sync`. [VERIFIED: server.rs line 327 `make_router(Arc::new(state))`, all handlers
use `State<Arc<AppState>>`]

### Pattern 4: Asset ID Normalization (SCALE-03)

**Current call sites (verified):**

| Location | Line(s) | Current behavior |
|----------|---------|-----------------|
| `reader.rs` `get_net_deposits_from_view` | 1292-1294 | `strip_prefix("0x").unwrap_or(a)` — removes prefix for DB |
| `reader.rs` `get_net_deposits_from_view` | 1344-1347 | `if !asset.starts_with("0x") { insert_str(0, "0x"); }` — adds prefix to result |
| `server.rs` `margin_supply` handler | 1969-1975 | `if starts_with("0x") … else format!("0x{}", …)` — ensures prefix for RPC |
| `reader.rs` SQL inline | 1107-1109 | `'0x' \|\| base_mp.asset_type = p.base_asset_id` — SQL-level normalization in get_margin_managers_info |

The SQL inline case (1107-1109) is inside a raw SQL string — `normalize_asset_id` cannot
replace it. The Rust-level call sites (three) are the candidates.

**Proposed utility function:**
```rust
// crates/server/src/server.rs or a new crates/server/src/utils.rs
/// Ensures the string has a "0x" prefix for Sui object ID representation.
pub fn normalize_asset_id(s: &str) -> String {
    if s.starts_with("0x") || s.starts_with("0X") {
        s.to_string()
    } else {
        format!("0x{}", s)
    }
}

/// Strips the "0x" prefix for database storage format.
pub fn strip_asset_prefix(s: &str) -> &str {
    s.strip_prefix("0x").unwrap_or(s)
}
```

**Where to put it:** A new `crates/server/src/utils.rs` (add `mod utils;` to `lib.rs`), or
inline in `server.rs`/`reader.rs` where first used. Given the CLAUDE.md "simplicity first"
directive, a small `utils.rs` with two functions is correct. The planner should add `pub mod
utils;` to `lib.rs` and `use crate::utils::{normalize_asset_id, strip_asset_prefix};` in the
call sites. [ASSUMED — two separate functions may be warranted given opposite directional
semantics; planner should verify if single normalize is sufficient or if both directions are needed]

The LIKE '%…%' patterns in `reader.rs` (lines 576, 650, 693, 728, etc.) are the `to_pattern()`
function used for empty-string wildcards — NOT asset normalization. These are addressed by
PERF-02 (Phase 1) via the `asset_normalized` column. Do not conflate them with SCALE-03.

### Pattern 5: Axum Input Validation Extractor (DX-03)

**Current validation locations:**

| Endpoint | Validation today | File/Line |
|----------|-----------------|-----------|
| `portfolio` | wallet format in `get_portfolio()` before any query | reader.rs:1451-1458 |
| `orders` | limit parsed with `and_then(parse::<i64>().ok()).unwrap_or(1000)` | server.rs:1182-1185 |
| `order_updates` | limit via `ParameterUtil::limit()` → defaults to 1 | server.rs:2071-2109 |
| `get_net_deposits` | timestamp parsed inline, no bounds check | server.rs:2033-2036 |
| `trades` | limit via `ParameterUtil::limit()` | server.rs:1272 |
| `ohclv` | interval validated against hardcoded list | server.rs:2127-2133 |

**Axum 0.7 extractor pattern:**

```rust
// Source: [VERIFIED axum 0.7 Query extractor + FromRequest derive]
// crates/server/src/routes/orders.rs (or a shared params module)

use axum::{
    async_trait,
    extract::{FromRequestParts, Query},
    http::request::Parts,
};
use serde::Deserialize;

#[derive(Debug, Deserialize)]
pub struct PaginationParams {
    #[serde(default = "default_limit")]
    pub limit: i64,
    pub start_time: Option<i64>,
    pub end_time: Option<i64>,
}

fn default_limit() -> i64 { 100 }
```

For wallet address validation, use a newtype with `FromRequestParts`:
```rust
pub struct ValidatedWalletAddress(pub String);

#[async_trait]
impl<S> FromRequestParts<S> for ValidatedWalletAddress
where S: Send + Sync
{
    type Rejection = DeepBookError;

    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Self::Rejection> {
        let Path(addr) = Path::<String>::from_request_parts(parts, state).await
            .map_err(|_| DeepBookError::bad_request("Missing wallet address"))?;
        
        if !addr.starts_with("0x") || addr.len() != 66 || !addr[2..].chars().all(|c| c.is_ascii_hexdigit()) {
            return Err(DeepBookError::bad_request(
                "Invalid wallet address: expected 0x-prefixed 64-character hex string",
            ));
        }
        Ok(ValidatedWalletAddress(addr))
    }
}
```

**Scope guidance for DX-03:** The requirement says "moved from `reader.rs` to Axum route
extractors or middleware". The wallet validation in `reader.rs:1451-1458` is the primary target.
Limit bounds validation (rejecting `limit > 10000`, for example) and timestamp range checks are
secondary. The planner should scope DX-03 to: (1) wallet address newtype extractor, (2) a
`PaginationParams` struct with serde defaults replacing raw `HashMap<String, String>` in the
highest-traffic routes. Replacing ALL 24 endpoints that use `ParameterUtil` is out of scope for
Phase 2 — it would be a large blast radius. Pick the 3-5 endpoints the requirement specifically
names.

**Existing `ParameterUtil` trait:** This trait (`server.rs:2071`) should remain for the margin
event endpoints that use it; the planner should extract it to `routes/mod.rs` so all sub-modules
can use it.

### Anti-Patterns to Avoid

- **Moving `AppState` out of `server.rs`:** It is used by `run_server` and referenced by admin
  module. Keep it in `server.rs`.
- **Splitting reader.rs by domain:** reader.rs is not in scope for this phase. Do not touch it
  except for SCALE-02 (OrderFill struct) and SCALE-03 (normalization call sites).
- **Implementing TTL cache eviction manually:** Use moka's `time_to_live` builder — do not poll
  or manually invalidate. The TTL handles eviction automatically.
- **Using `Arc<Mutex<HashMap>>` instead of moka:** That would be hand-rolling a caching solution.
  moka is the decided library.
- **Making `OrderFill` public from schema crate:** Define it in `reader.rs` or the new routes
  module. It is a server-only type, not a schema model.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| In-process TTL cache | `Arc<Mutex<HashMap>>` + timestamp fields | `moka::future::Cache` | Concurrent eviction, TTL, max capacity, no manual cleanup |
| Input deserialization with defaults | Manual `HashMap::get` + `parse` + `unwrap_or` | `#[derive(Deserialize)]` structs with `#[serde(default)]` | Compile-time checked, readable |
| Wallet address validation | Custom regex | Simple Rust string checks (already working at reader.rs:1452-1456) | The existing logic is correct; move it, don't rewrite it |

---

## Common Pitfalls

### Pitfall 1: Circular module dependencies after split
**What goes wrong:** `routes/pools.rs` imports `AppState` from `server.rs`; `server.rs` imports
from `routes::pools` for `make_router`. This creates a cycle if not careful.
**Why it happens:** Putting `AppState` definition in a file that also imports from the routes module.
**How to avoid:** Keep `AppState` in `server.rs`. Routes import from `crate::server::AppState` (one
direction only). `server.rs` imports route constructors `use crate::routes::*`. No cycle exists.
**Warning signs:** `error[E0391]: cycle detected when resolving imports`

### Pitfall 2: State type mismatch after split
**What goes wrong:** Sub-module routers use `Router<Arc<AppState>>` (unbound) but `make_router`
calls `with_state` only at the top level, causing type errors.
**Why it happens:** Forgetting that `.with_state(state)` converts `Router<S>` to `Router<()>`.
**How to avoid:** Don't call `.with_state()` in sub-module routers. Call `.with_state(state.clone())`
once in `make_router` after merging all sub-routers. See `admin/routes.rs` for the existing
precedent — it returns `Router<Arc<AppState>>` and the caller adds `.with_state`.
**Warning signs:** `error[E0277]: the trait bound Arc<AppState>: FromRef<()>` at compile time.

### Pitfall 3: moka Cache<(), V> requires V: Clone
**What goes wrong:** Compiler rejects `Cache::insert((), value.clone())` because `V` is not `Clone`.
**Why it happens:** moka requires values to be `Clone + Send + Sync + 'static`.
**How to avoid:** Verify `Pools` model derives `Clone`. If not, wrap in `Arc<Vec<Pools>>` as the
cached value type — `Arc<T>` is always `Clone`.
**Warning signs:** `error[E0277]: the trait bound deepbook_schema::models::Pools: Clone is not satisfied`

### Pitfall 4: AppState Clone not derived — cache fields need manual Clone
**What goes wrong:** After adding two `moka::future::Cache` fields to `AppState`, the struct
does not compile if `Clone` is needed.
**Why it happens:** `AppState` is always used behind `Arc<AppState>` — it is never cloned
directly. New fields only need `Send + Sync`.
**How to avoid:** Do not try to derive or implement `Clone` for `AppState`. The `Arc<AppState>`
is what gets cloned. The cache fields need only be `Send + Sync`, which moka satisfies.
**Warning signs:** Not an error — this is the correct design. If a `Clone` impl appears
somewhere, investigate why.

### Pitfall 5: OrderFill field order must match SELECT order for Queryable
**What goes wrong:** Diesel `Queryable` (not `QueryableByName`) maps columns by position. If
`OrderFill` fields are in a different order than the `select((...))` clause, values silently
go to wrong fields.
**Why it happens:** `Queryable` is position-based; `QueryableByName` is name-based.
**How to avoid:** Either (a) declare `OrderFill` fields in exactly the same order as the
`select((...))` clause in `get_orders`, or (b) use `QueryableByName` with `diesel::sql_query`
where column names are explicit. Use option (b) if any doubt about ordering.
**Warning signs:** Tests pass but data is scrambled (wrong price in timestamp field, etc.).

### Pitfall 6: `ParameterUtil` trait scope after split
**What goes wrong:** `ParameterUtil` is defined in `server.rs` at line 2071 but will be needed
by all route sub-modules after the split.
**Why it happens:** Private `trait` in a parent module is invisible to child modules without
explicit re-export.
**How to avoid:** Move `ParameterUtil` and its `HashMap` impl to `routes/mod.rs` or a new
`routes/params.rs` and `pub use` it in `routes/mod.rs`.

---

## Code Examples

### Verified: Existing QueryableByName pattern in reader.rs (SCALE-02 reference)
```rust
// Source: crates/server/src/reader.rs lines 44-58
#[derive(QueryableByName, Debug)]
struct OhclvRow {
    #[diesel(sql_type = BigInt)]
    timestamp_ms: i64,
    #[diesel(sql_type = Double)]
    open: f64,
    // ...
}
```

### Verified: moka async cache creation (PERF-05)
```rust
// Source: [CITED: docs.rs/moka/latest/moka/future/struct.Cache.html]
use moka::future::Cache;
use std::time::Duration;

let cache: Cache<(), Vec<Pools>> = Cache::builder()
    .max_capacity(1)
    .time_to_live(Duration::from_secs(60))
    .build();

// Insert
cache.insert((), pools.clone()).await;

// Get
if let Some(cached) = cache.get(&()).await {
    return Ok(Json(cached));
}
```

### Verified: admin/routes.rs split pattern (SCALE-01 reference)
```rust
// Source: crates/server/src/admin/routes.rs (existing — verified)
pub fn admin_routes(state: Arc<AppState>) -> Router<Arc<AppState>> {
    let protected = Router::new()
        .route("/pools", post(handlers::create_pool))
        // ...
        .layer(from_fn_with_state(state, require_admin_auth));
    Router::new()
        .route("/health", get(handlers::admin_health))
        .merge(protected)
}
```

### Verified: Wallet validation (DX-03 existing logic to move)
```rust
// Source: crates/server/src/reader.rs lines 1451-1458
if !wallet_address.starts_with("0x")
    || wallet_address.len() != 66
    || !wallet_address[2..].chars().all(|c| c.is_ascii_hexdigit())
{
    return Err(DeepBookError::bad_request(
        "Invalid wallet address: expected 0x-prefixed 64-character hex string",
    ));
}
```

---

## Handler Domain Grouping (for SCALE-01 planner)

| Route | Handler fn | Module |
|-------|-----------|--------|
| `/` | `health_check` | health |
| `/status` | `status` | health |
| `/get_pools` | `get_pools` | pools |
| `/historical_volume/:pool_names` | `historical_volume` | pools |
| `/all_historical_volume` | `all_historical_volume` | pools |
| `/historical_volume_by_balance_manager_id_with_interval/…` | `get_historical_volume_by_balance_manager_id_with_interval` | pools |
| `/historical_volume_by_balance_manager_id/…` | `get_historical_volume_by_balance_manager_id` | pools |
| `/ticker` | `ticker` | pools |
| `/summary` | `summary` | pools |
| `/trade_count` | `trade_count` | orders |
| `/trades/:pool_name` | `trades` | orders |
| `/order_updates/:pool_name` | `order_updates` | orders |
| `/orders/:pool_name/:balance_manager_id` | `orders` | orders |
| `/ohclv/:pool_name` | `ohclv` | orders |
| `/orderbook/:pool_name` | `orderbook` | orders |
| `/assets` | `assets` | pools |
| `/pool_created` | `pool_created` | pools |
| `/book_params_updated` | `book_params_updated` | pools |
| `/portfolio/:wallet_address` | `portfolio` | portfolio |
| `/get_net_deposits/:asset_ids/:timestamp` | `get_net_deposits` | portfolio |
| `/deposited_assets/:balance_manager_ids` | `deposited_assets` | portfolio |
| `/get_points` | `get_points` | points |
| `/margin_manager_created` | `margin_manager_created` | margin |
| `/loan_borrowed` | `loan_borrowed` | margin |
| `/loan_repaid` | `loan_repaid` | margin |
| `/liquidation` | `liquidation` | margin |
| `/asset_supplied` | `asset_supplied` | margin |
| `/asset_withdrawn` | `asset_withdrawn` | margin |
| `/margin_pool_created` | `margin_pool_created` | margin |
| `/deepbook_pool_updated` | `deepbook_pool_updated` | margin |
| `/interest_params_updated` | `interest_params_updated` | margin |
| `/margin_pool_config_updated` | `margin_pool_config_updated` | margin |
| `/maintainer_cap_updated` | `maintainer_cap_updated` | margin |
| `/maintainer_fees_withdrawn` | `maintainer_fees_withdrawn` | margin |
| `/protocol_fees_withdrawn` | `protocol_fees_withdrawn` | margin |
| `/supplier_cap_minted` | `supplier_cap_minted` | margin |
| `/supply_referral_minted` | `supply_referral_minted` | margin |
| `/pause_cap_updated` | `pause_cap_updated` | margin |
| `/protocol_fees_increased` | `protocol_fees_increased` | margin |
| `/referral_fees_claimed` | `referral_fees_claimed` | margin |
| `/referral_fee_events` | `referral_fee_events` | margin |
| `/deepbook_pool_registered` | `deepbook_pool_registered` | margin |
| `/deepbook_pool_updated_registry` | `deepbook_pool_updated_registry` | margin |
| `/deepbook_pool_config_updated` | `deepbook_pool_config_updated` | margin |
| `/margin_managers_info` | `margin_managers_info` | margin |
| `/margin_manager_states` | `margin_manager_states` | margin |
| `/deep_supply` | `deep_supply` | health |
| `/margin_supply` | `margin_supply` | health |
| `/fees` | `fees` | health |

Private helpers staying in `server.rs` or moving to their domain module:
- `historical_volume_with_pools` — moves with `historical_volume` to pools
- `all_historical_volume_with_pools` — moves with pools
- `fetch_historical_volume_with_pools` — moves with pools (used only by ticker)
- `parse_type_input` — moves to utils or health module (used by orderbook, deep_supply, fees)
- `calculate_trade_id` — moves to orders module
- `ParameterUtil` trait + impl — moves to `routes/mod.rs` (shared by all)

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Axum `Router::new().layer(Extension(state))` | `Router.with_state(state)` / `State<S>` extractor | axum 0.7 (2024) | Type-safe state; no `TypeMap` lookup |
| moka 0.11 `Cache` API | moka 0.12 `Cache::builder()` | moka 0.12 (2023) | Builder pattern; `time_to_idle` added |
| Diesel `#[derive(Queryable)]` positional | `#[derive(Queryable, Selectable)]` with `as_select()` | Diesel 2.0 (2023) | Explicit column selection, avoids position bugs |

**Deprecated/outdated:**
- `moka::sync::Cache` with `get_with` callback: replaced by `get` + `insert` async pattern for `future::Cache` in async contexts [CITED: docs.rs/moka/latest]
- `axum::AddExtension`: replaced by `axum::with_state` — already correctly used in this codebase

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Rust / cargo | All changes | confirmed (project builds) | workspace uses 2021 edition | — |
| PostgreSQL | Integration tests | assumed (dev DB exists) | — | Skip integration tests in CI |
| moka crate | PERF-05 | not in Cargo.toml | — | Add to Cargo.toml (no blocker) |

**Missing dependencies with no fallback:** None — moka just needs `Cargo.toml` entry.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Rust built-in `#[test]` + `cargo test` |
| Config file | none (standard cargo test discovery) |
| Quick run command | `cargo test -p deepbook-server` |
| Full suite command | `cargo build -p deepbook-server && cargo test -p deepbook-server` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| SCALE-01 | `routes/` directory exists; `server.rs` has no handler `async fn`s | unit (compile check) | `cargo build -p deepbook-server` | ❌ Wave 0 |
| SCALE-01 | `make_router` assembles all expected routes | integration | manual `curl` check or `cargo test` | ❌ Wave 0 |
| SCALE-02 | `OrderFill` struct exists; `get_orders` return type is `Vec<OrderFill>` | unit (compile) | `cargo build -p deepbook-server` | ❌ Wave 0 |
| SCALE-02 | Handler destructures `OrderFill` fields by name, not position | unit (compile) | `cargo build -p deepbook-server` | ❌ Wave 0 |
| SCALE-03 | `normalize_asset_id("")` and `normalize_asset_id("0xabc")` return correctly | unit | `cargo test -p deepbook-server normalize_asset_id` | ❌ Wave 0 |
| SCALE-03 | No inline `strip_prefix("0x")` or `format!("0x{}")` outside `utils.rs` | lint (grep) | `grep -rn 'strip_prefix.*0x\|format!.*0x' crates/server/src/` | N/A |
| PERF-05 | `pools_cache` field exists on `AppState` | unit (compile) | `cargo build -p deepbook-server` | ❌ Wave 0 |
| PERF-05 | `ticker_cache` field exists on `AppState` | unit (compile) | `cargo build -p deepbook-server` | ❌ Wave 0 |
| PERF-05 | Cache hit on second call (no DB query) | integration | manual timing or mock test | ❌ Wave 0 |
| DX-03 | `portfolio` handler rejects invalid wallet address without reaching reader | unit | `cargo test -p deepbook-server validate_wallet` | ❌ Wave 0 |
| DX-03 | `PaginationParams` deserialization applies `default_limit` correctly | unit | `cargo test -p deepbook-server pagination_defaults` | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** `cargo build -p deepbook-server` (compile check, ~30s)
- **Per wave merge:** `cargo build -p deepbook-server && cargo test -p deepbook-server`
- **Phase gate:** Full suite green before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `crates/server/src/routes/` — directory and mod.rs (created by SCALE-01 task)
- [ ] `crates/server/tests/validation.rs` — unit tests for wallet validation, normalize_asset_id, pagination defaults
- [ ] No existing test infrastructure for integration testing without a live DB; compile tests are the primary gate

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `Pools` model derives `Clone` (needed for `Cache<(), Vec<Pools>>`) | PERF-05 pattern | Cache value type must change to `Arc<Vec<Pools>>` — 5 minute fix |
| A2 | Two separate `normalize_asset_id` / `strip_asset_prefix` functions cover all call sites | SCALE-03 | Additional call sites in indexer crate would need discovery |
| A3 | `deepbook_margin_pool_created.asset_type` has same normalization concern as other assets | SCALE-03 | SQL inline at reader.rs:1107-1109 may need a separate migration fix |
| A4 | The three Rust-level call sites are the only `0x`-normalization Rust code (SQL-level is excluded) | SCALE-03 | A grep over the full crate would confirm — planner should run this |
| A5 | DX-03 scope is wallet address validation + pagination params for portfolio/orders/trades | DX-03 pattern | If all 24 ParameterUtil endpoints need typed params, scope becomes 5x larger |

---

## Open Questions

1. **Should `OrderFill` use `Queryable` (DSL path) or `QueryableByName` (sql_query path)?**
   - What we know: `get_orders` uses DSL `.select((col, col, ...)).load::<Tuple>()`. REQUIREMENTS.md says `#[derive(QueryableByName, Serialize)]`.
   - What's unclear: Whether the requirement intends to also convert to `diesel::sql_query` or just wants a named struct regardless of derive path.
   - Recommendation: Use `#[derive(Queryable, Serialize)]` and keep DSL; note the discrepancy in the plan. Convert to `QueryableByName` + `sql_query` only if utoipa (Phase 3) requires it.

2. **Should `routes/points.rs` be merged into another module?**
   - What we know: There is only one points endpoint (`/get_points`). A single-function module is valid but thin.
   - Recommendation: Keep it separate — the requirement explicitly names `points` as a domain module, and future endpoints will likely be added here.

3. **Are there other `0x`-normalization call sites in the `indexer` crate?**
   - What we know: SCALE-03 is scoped to `crates/server/`. The indexer crate was not surveyed.
   - Recommendation: Planner should grep `crates/indexer/` for `strip_prefix.*0x` or `format!.*0x{}` as a verification step.

---

## Security Domain

This phase is Rust internal refactoring. No new attack surfaces are introduced. Relevant security notes:

- The wallet address validation extractor (DX-03) is a security improvement — rejecting malformed addresses at the boundary prevents malformed strings from reaching SQL queries.
- The moka cache (PERF-05) is in-process only; no network exposure. TTL expiry means stale pool data is bounded at 60 seconds — acceptable for pool metadata.
- Admin endpoints remain behind bearer token auth (unchanged). No admin routes are touched.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | unchanged — admin auth in `admin/auth.rs` |
| V3 Session Management | no | stateless REST API |
| V4 Access Control | no | no new endpoints |
| V5 Input Validation | yes (DX-03) | Axum extractor rejects invalid wallet/params before business logic |
| V6 Cryptography | no | no crypto changes |

---

## Sources

### Primary (HIGH confidence)
- `crates/server/src/server.rs` — complete route inventory, AppState, make_router, all handler signatures, ParameterUtil trait [VERIFIED: direct read]
- `crates/server/src/reader.rs` — get_orders 17-tuple, existing QueryableByName structs, 0x normalization call sites, wallet validation [VERIFIED: direct read]
- `crates/server/Cargo.toml` — dependency list confirms no moka, axum 0.7, diesel 2.2 [VERIFIED: direct read]
- `crates/server/src/admin/routes.rs` — existing sub-module router pattern [VERIFIED: direct read]
- `crates/server/src/error.rs` — DeepBookError variants and IntoResponse impl [VERIFIED: direct read]
- `.planning/STATE.md` — locked decisions: moka, in-process cache only [VERIFIED: direct read]

### Secondary (MEDIUM confidence)
- [moka 0.12.10 docs.rs](https://docs.rs/moka/latest/moka/future/struct.Cache.html) — Cache::builder() API, TTL config [CITED]
- [crates.io/crates/moka](https://crates.io/crates/moka) — current version 0.12.10 [VERIFIED: web search]

### Tertiary (LOW confidence)
- None — all claims verified from codebase or official docs

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all deps verified from Cargo.toml + crates.io
- Architecture (SCALE-01): HIGH — complete handler inventory from reading server.rs
- SCALE-02 (OrderFill): HIGH — 17-tuple confirmed at reader.rs:278-299; QueryableByName pattern confirmed
- SCALE-03 (normalization): HIGH — all Rust call sites found via grep + read
- PERF-05 (moka): HIGH — absence confirmed from Cargo.toml; moka API verified from docs
- DX-03 (validation): HIGH — validation logic locations confirmed; extractor pattern from axum 0.7 docs
- Pitfalls: HIGH — based on direct Axum/Diesel module split experience and verified code patterns

**Research date:** 2026-04-30
**Valid until:** 2026-05-30 (stable stack — axum 0.7, diesel 2.2, moka 0.12 unlikely to have breaking changes)
