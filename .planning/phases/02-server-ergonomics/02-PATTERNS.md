# Phase 2: Server Ergonomics - Pattern Map

**Mapped:** 2026-04-30
**Files analyzed:** 9 new/modified files
**Analogs found:** 9 / 9

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `crates/server/src/routes/mod.rs` | route-assembly | request-response | `crates/server/src/admin/routes.rs` | exact |
| `crates/server/src/routes/pools.rs` | route handler | request-response | `crates/server/src/server.rs` lines 533–594 | exact |
| `crates/server/src/routes/orders.rs` | route handler | request-response | `crates/server/src/server.rs` lines 1172–1432 | exact |
| `crates/server/src/routes/portfolio.rs` | route handler | request-response | `crates/server/src/server.rs` lines 2851–2857 | exact |
| `crates/server/src/routes/margin.rs` | route handler | request-response | `crates/server/src/server.rs` lines 2159–2256 | exact |
| `crates/server/src/routes/points.rs` | route handler | request-response | `crates/server/src/server.rs` lines 2159–2178 (thin handler) | role-match |
| `crates/server/src/routes/health.rs` | route handler | request-response | `crates/server/src/server.rs` lines 436–530 | exact |
| `crates/server/src/utils.rs` | utility | transform | `crates/server/src/reader.rs` lines 1291–1347 (inline logic) | data-flow-match |
| `crates/server/src/reader.rs` (modified) | service | CRUD | `crates/server/src/reader.rs` lines 44–112 (`OhclvRow` pattern) | exact |
| `crates/server/src/server.rs` (modified) | config/state | request-response | `crates/server/src/server.rs` lines 134–236 (AppState) | exact |
| `crates/server/Cargo.toml` (modified) | config | — | existing `[dependencies]` block | exact |
| `crates/server/src/lib.rs` (modified) | config | — | existing `pub mod` declarations | exact |

---

## Pattern Assignments

### `crates/server/src/routes/mod.rs` (route-assembly, request-response)

**Analog:** `crates/server/src/admin/routes.rs` (complete file, 30 lines)

**Purpose:** Re-exports all sub-module `router()` functions so `server.rs::make_router` can call
`routes::pools::router()`, etc. Also owns `ParameterUtil` trait and its `HashMap` impl, which
must be visible to all sub-modules.

**Sub-module router function pattern** (from `admin/routes.rs` lines 16–30):
```rust
// crates/server/src/admin/routes.rs lines 16-30
pub fn admin_routes(state: Arc<AppState>) -> Router<Arc<AppState>> {
    let protected = Router::new()
        .route("/pools", post(handlers::create_pool))
        .route("/pools/{pool_id}", put(handlers::update_pool))
        .route("/pools/{pool_id}", delete(handlers::delete_pool))
        .route("/assets", post(handlers::create_asset))
        .route("/assets/{asset_type}", delete(handlers::delete_asset))
        .layer(from_fn_with_state(state, require_admin_auth));

    Router::new()
        .route("/health", get(handlers::admin_health))
        .merge(protected)
}
```

**Key rule:** Sub-module routers return `Router<Arc<AppState>>` (unbound) — do NOT call
`.with_state()` inside a sub-module. The single `.with_state(state.clone())` call lives in
`make_router` in `server.rs` after all sub-routers are merged.

**`ParameterUtil` trait to move here** (from `server.rs` lines 2071–2109):
```rust
// crates/server/src/server.rs lines 2071-2109
trait ParameterUtil {
    fn start_time(&self) -> Option<i64>;
    fn end_time(&self) -> i64;
    fn volume_in_base(&self) -> bool;
    fn limit(&self) -> i64;
}

impl ParameterUtil for HashMap<String, String> {
    fn start_time(&self) -> Option<i64> {
        self.get("start_time")
            .and_then(|v| v.parse::<i64>().ok())
            .map(|t| t * 1000)
    }

    fn end_time(&self) -> i64 {
        self.get("end_time")
            .and_then(|v| v.parse::<i64>().ok())
            .map(|t| t * 1000)
            .unwrap_or_else(|| {
                SystemTime::now()
                    .duration_since(UNIX_EPOCH)
                    .unwrap()
                    .as_millis() as i64
            })
    }

    fn volume_in_base(&self) -> bool {
        self.get("volume_in_base")
            .map(|v| v == "true")
            .unwrap_or_default()
    }

    fn limit(&self) -> i64 {
        self.get("limit")
            .and_then(|v| v.parse::<i64>().ok())
            .unwrap_or(1)
    }
}
```

**Imports pattern for each sub-module** (copy from `admin/routes.rs` lines 1–14 + `server.rs`
lines 1–49 for the full import list):
```rust
// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

use std::sync::Arc;

use axum::{
    extract::{Path, Query, State},
    routing::get,
    Json, Router,
};

use crate::error::DeepBookError;
use crate::server::AppState;
```

---

### `crates/server/src/routes/pools.rs` (route handler, request-response)

**Analog:** `crates/server/src/server.rs` lines 533–594 (`get_pools`, `historical_volume`,
`historical_volume_with_pools`, `all_historical_volume`)

**Router function to produce:**
```rust
pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route(GET_POOLS_PATH, get(get_pools))
        .route(HISTORICAL_VOLUME_PATH, get(historical_volume))
        .route(ALL_HISTORICAL_VOLUME_PATH, get(all_historical_volume))
        .route(
            GET_HISTORICAL_VOLUME_BY_BALANCE_MANAGER_ID_WITH_INTERVAL,
            get(get_historical_volume_by_balance_manager_id_with_interval),
        )
        .route(
            GET_HISTORICAL_VOLUME_BY_BALANCE_MANAGER_ID,
            get(get_historical_volume_by_balance_manager_id),
        )
        .route(TICKER_PATH, get(ticker))
        .route(ASSETS_PATH, get(assets))
        .route(POOL_CREATED_PATH, get(pool_created))
        .route(BOOK_PARAMS_UPDATED_PATH, get(book_params_updated))
        .route(SUMMARY_PATH, get(summary))
}
```

**Simple handler pattern** (from `server.rs` lines 532–534):
```rust
// crates/server/src/server.rs lines 532-534
async fn get_pools(State(state): State<Arc<AppState>>) -> Result<Json<Vec<Pools>>, DeepBookError> {
    Ok(Json(state.reader.get_pools().await?))
}
```

**Handler with Path + Query params** (from `server.rs` lines 537–543):
```rust
// crates/server/src/server.rs lines 537-543
async fn historical_volume(
    Path(pool_names): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<HashMap<String, u64>>, DeepBookError> {
    let pools = state.reader.get_pools().await?;
    historical_volume_with_pools(&pool_names, &params, &state, &pools).await
}
```

**Private helper that stays with its domain** (from `server.rs` lines 546–594):
```rust
// crates/server/src/server.rs lines 546-594
async fn historical_volume_with_pools(
    pool_names: &str,
    params: &HashMap<String, String>,
    state: &Arc<AppState>,
    pools: &[Pools],
) -> Result<Json<HashMap<String, u64>>, DeepBookError> {
    let pool_name_to_id: HashMap<String, String> = pools
        .iter()
        .map(|pool| (pool.pool_name.clone(), pool.pool_id.clone()))
        .collect();
    // ...
}
```

**PERF-05 cache pattern to apply to `get_pools` after SCALE-01:** (see moka section below)

**Path constants:** All `pub const *_PATH` values stay in `server.rs` (lines 66–124) and are
imported via `use crate::server::{GET_POOLS_PATH, ...}` in each routes sub-module. Alternatively,
move them to `routes/mod.rs` — the planner should choose one location and use it consistently.

---

### `crates/server/src/routes/orders.rs` (route handler, request-response)

**Analog:** `crates/server/src/server.rs` lines 1172–1432

**Handler with complex query building and tuple destructuring** (from `server.rs` lines 1256–1430):
```rust
// crates/server/src/server.rs lines 1256-1293 (trades handler signature + param parsing)
async fn trades(
    Path(pool_name): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<HashMap<String, Value>>>, DeepBookError> {
    let (pool_id, base_decimals, quote_decimals) =
        state.reader.get_pool_decimals(&pool_name).await?;
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    // ...
}
```

**Tuple destructure in map closure** (from `server.rs` lines 1304–1430) — this is the 17-tuple
pattern targeted by SCALE-02. After SCALE-02, this map closure changes from positional tuple
destructuring to named field access:
```rust
// BEFORE (server.rs lines 1304-1323): positional 17-tuple
let trade_data = trades
    .into_iter()
    .map(|(
        event_digest,
        digest,
        maker_order_id,
        taker_order_id,
        maker_client_order_id,
        taker_client_order_id,
        price,
        base_quantity,
        quote_quantity,
        timestamp,
        taker_is_bid,
        maker_balance_manager_id,
        taker_balance_manager_id,
        taker_fee_is_deep,
        maker_fee_is_deep,
        taker_fee,
        maker_fee,
    )| { /* ... */ })

// AFTER (SCALE-02): named struct fields
let trade_data = trades
    .into_iter()
    .map(|fill: OrderFill| {
        let trade_id = calculate_trade_id(&fill.maker_order_id, &fill.taker_order_id)
            .unwrap_or(0);
        // access fill.event_digest, fill.price, etc.
    })
```

**Handler with two-segment Path** (from `server.rs` lines 1172–1175):
```rust
// crates/server/src/server.rs lines 1172-1175
async fn orders(
    Path((pool_name, balance_manager_id)): Path<(String, String)>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<HashMap<String, Value>>>, DeepBookError> {
```

**DX-03 pagination params struct** (new pattern — replaces raw `HashMap` limit parsing at
`server.rs` lines 1182–1185). See DX-03 section below.

---

### `crates/server/src/routes/portfolio.rs` (route handler, request-response)

**Analog:** `crates/server/src/server.rs` lines 2851–2857

**Handler pattern** (from `server.rs` lines 2851–2857):
```rust
// crates/server/src/server.rs lines 2851-2857
async fn portfolio(
    Path(wallet_address): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<PortfolioQueryResult>, DeepBookError> {
    let result = state.reader.get_portfolio(&wallet_address).await?;
    Ok(Json(result))
}
```

**DX-03 wallet extractor** replaces the raw `Path(wallet_address)` here. After DX-03, the
signature becomes:
```rust
async fn portfolio(
    ValidatedWalletAddress(wallet_address): ValidatedWalletAddress,
    State(state): State<Arc<AppState>>,
) -> Result<Json<PortfolioQueryResult>, DeepBookError> {
    let result = state.reader.get_portfolio(&wallet_address).await?;
    Ok(Json(result))
}
```

The wallet validation logic to move from `reader.rs` to the extractor (from `reader.rs`
lines 1451–1459):
```rust
// crates/server/src/reader.rs lines 1451-1459 (logic to lift to extractor)
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

### `crates/server/src/routes/margin.rs` (route handler, request-response)

**Analog:** `crates/server/src/server.rs` lines 2159–2856 (~700 lines of margin handlers)

**Uniform margin event handler pattern** (from `server.rs` lines 2180–2204):
```rust
// crates/server/src/server.rs lines 2180-2204 — canonical margin handler shape
async fn loan_borrowed(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<LoanBorrowed>>, DeepBookError> {
    let end_time = params.end_time();
    let start_time = params
        .start_time()
        .unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    let margin_manager_id_filter = params.get("margin_manager_id").cloned().unwrap_or_default();
    let margin_pool_id_filter = params.get("margin_pool_id").cloned().unwrap_or_default();

    let results = state
        .reader
        .get_loan_borrowed(
            start_time,
            end_time,
            limit,
            margin_manager_id_filter,
            margin_pool_id_filter,
        )
        .await?;

    Ok(Json(results))
}
```

All 20+ margin event handlers follow this identical shape. Copy it exactly for each one —
only the function name, return type `Vec<T>`, and reader method name differ.

**`margin_manager_created` variant with optional end_time** (from `server.rs` lines 2159–2178):
```rust
// crates/server/src/server.rs lines 2159-2178 — variant with Option<end_time>
async fn margin_manager_created(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<MarginManagerCreated>>, DeepBookError> {
    let start_time = params.start_time();
    let end_time = params
        .get("end_time")
        .and_then(|v| v.parse::<i64>().ok())
        .map(|t| t * 1000);
    let limit = params.limit();
    let owner_filter = params.get("owner").cloned();

    let results = state
        .reader
        .get_margin_manager_created(start_time, end_time, limit, owner_filter)
        .await?;

    Ok(Json(results))
}
```

**Router function** exposes all margin routes using path constants from `server.rs` lines 95–118.

---

### `crates/server/src/routes/points.rs` (route handler, request-response)

**Analog:** `crates/server/src/server.rs` — thin handler pattern (like `get_pools`)

**Single-endpoint router pattern** (analogous to `get_pools` at `server.rs` line 533):
```rust
pub fn router() -> Router<Arc<AppState>> {
    Router::new()
        .route(GET_POINTS_PATH, get(get_points))
}

async fn get_points(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<...>, DeepBookError> {
    // same param extraction pattern as loan_borrowed
    let end_time = params.end_time();
    let start_time = params.start_time().unwrap_or_else(|| end_time - 24 * 60 * 60 * 1000);
    let limit = params.limit();
    Ok(Json(state.reader.get_points(start_time, end_time, limit).await?))
}
```

---

### `crates/server/src/routes/health.rs` (route handler, request-response)

**Analog:** `crates/server/src/server.rs` lines 436–530

**Bare handler returning StatusCode** (from `server.rs` lines 436–438):
```rust
// crates/server/src/server.rs lines 436-438
async fn health_check() -> StatusCode {
    StatusCode::OK
}
```

**Handler with typed query-param struct + serde defaults** (from `server.rs` lines 239–255 and
441–530):
```rust
// crates/server/src/server.rs lines 239-255 — StatusQueryParams typed struct
#[derive(Debug, Deserialize)]
pub struct StatusQueryParams {
    #[serde(default = "default_max_checkpoint_lag")]
    pub max_checkpoint_lag: i64,
    #[serde(default = "default_max_time_lag_seconds")]
    pub max_time_lag_seconds: i64,
}

fn default_max_checkpoint_lag() -> i64 { 100 }
fn default_max_time_lag_seconds() -> i64 { 60 }

// crates/server/src/server.rs lines 441-444
async fn status(
    Query(params): Query<StatusQueryParams>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<serde_json::Value>, DeepBookError> {
```

This is the existing proof-of-concept for DX-03 typed params — `StatusQueryParams` already
uses `#[serde(default)]`. The `PaginationParams` struct (DX-03) follows exactly this pattern.

`health.rs` also contains `deep_supply`, `margin_supply`, and `fees` (RPC-calling handlers).
The `margin_supply` handler contains the inline `0x` normalization targeted by SCALE-03 —
see SCALE-03 section.

---

### `crates/server/src/utils.rs` (utility, transform)

**Analog:** `crates/server/src/reader.rs` lines 1291–1347 (inline normalization logic)

No existing `utils.rs` in the codebase. This is a new file. The logic to centralize comes
from two sources:

**Source 1 — strip prefix (from `reader.rs` lines 1291–1294):**
```rust
// crates/server/src/reader.rs lines 1291-1294
let cleaned_assets: Vec<String> = asset_ids
    .iter()
    .map(|a| a.strip_prefix("0x").unwrap_or(a).to_string())
    .collect();
```

**Source 2 — add prefix to result (from `reader.rs` lines 1344–1348):**
```rust
// crates/server/src/reader.rs lines 1344-1348
.map(|row| {
    let mut asset = row.asset;
    if !asset.starts_with("0x") {
        asset.insert_str(0, "0x");
    }
    (asset, row.net_amount)
})
```

**Source 3 — normalize for RPC call (from `server.rs` lines 1969–1975):**
```rust
// crates/server/src/server.rs lines 1969-1975
let normalized_asset_type = if asset_type.starts_with("0x") || asset_type.starts_with("0X")
{
    asset_type.clone()
} else {
    format!("0x{}", asset_type)
};
```

**Target utility functions** (new code — no existing exact analog):
```rust
// crates/server/src/utils.rs (new file)

/// Ensures a Sui object ID has a "0x" prefix.
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

Call sites to update after adding `utils.rs`:
- `reader.rs` line 1293 — `a.strip_prefix("0x").unwrap_or(a).to_string()` → `strip_asset_prefix(a).to_string()`
- `reader.rs` lines 1344–1347 — `if !asset.starts_with("0x") { asset.insert_str(0, "0x") }` → `normalize_asset_id(&asset)`
- `server.rs` (post-split: `routes/health.rs`) lines 1969–1975 — inline if/else → `normalize_asset_id(&asset_type)`

---

### `crates/server/src/reader.rs` (modified — SCALE-02 `OrderFill` struct)

**Analog for derive pattern:** `crates/server/src/reader.rs` lines 44–112 (existing `QueryableByName` structs)

**Existing `OhclvRow` pattern to copy** (from `reader.rs` lines 44–58):
```rust
// crates/server/src/reader.rs lines 44-58
#[derive(QueryableByName, Debug)]
struct OhclvRow {
    #[diesel(sql_type = BigInt)]
    timestamp_ms: i64,
    #[diesel(sql_type = Double)]
    open: f64,
    #[diesel(sql_type = Double)]
    high: f64,
    #[diesel(sql_type = Double)]
    low: f64,
    #[diesel(sql_type = Double)]
    close: f64,
    #[diesel(sql_type = Double)]
    base_volume: f64,
}
```

**`OrderFill` struct to define** (from RESEARCH.md Pattern 2, validated against the 17-tuple at
`reader.rs` lines 278–367). Column order matches the `.select((col1, col2, ...))` at
`reader.rs` lines 329–347:
```rust
// New struct in crates/server/src/reader.rs (add after existing QueryableByName structs ~line 112)
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

**Query change in `get_orders`** (from `reader.rs` lines 348–366):
```rust
// BEFORE: reader.rs lines 348-366
.load::<(
    String, String, String, String,
    i64, i64, i64, i64, i64, i64,
    bool, String, String, bool, bool, i64, i64,
)>(&mut connection)

// AFTER: change the query to sql_query to use QueryableByName
// Replace the DSL query block with diesel::sql_query:
let res = diesel::sql_query(
    "SELECT event_digest, digest, maker_order_id, taker_order_id, \
     maker_client_order_id, taker_client_order_id, price, base_quantity, \
     quote_quantity, checkpoint_timestamp_ms, taker_is_bid, \
     maker_balance_manager_id, taker_balance_manager_id, \
     taker_fee_is_deep, maker_fee_is_deep, taker_fee, maker_fee \
     FROM order_fills \
     WHERE pool_id = $1 \
     AND checkpoint_timestamp_ms BETWEEN $2 AND $3 \
     ORDER BY checkpoint_timestamp_ms DESC \
     LIMIT $4"
)
.bind::<diesel::sql_types::Text, _>(&pool_id)
.bind::<diesel::sql_types::BigInt, _>(start_time)
.bind::<diesel::sql_types::BigInt, _>(end_time)
.bind::<diesel::sql_types::BigInt, _>(limit)
.load::<OrderFill>(&mut connection)
.await
```

**NOTE for planner:** The REQUIREMENTS.md demands `#[derive(QueryableByName)]`. The current
`get_orders` uses a DSL `.select()` query, not `diesel::sql_query`. To satisfy the requirement
exactly, either (a) rewrite `get_orders` to use `diesel::sql_query` (consistent with `OhclvRow`
pattern already in file), or (b) use `#[derive(Queryable, Serialize)]` and keep DSL. Option (a)
is recommended to match the requirement and existing codebase pattern. The optional filters
(maker/taker/balance_manager) need to be moved to the WHERE clause when converting — see
`reader.rs` lines 308–320 for the filter logic to convert.

---

### `crates/server/src/server.rs` (modified — PERF-05 AppState + make_router)

**Analog:** Self — `server.rs` lines 134–236 (`AppState` struct and `impl AppState`)

**`AppState` struct to extend** (from `server.rs` lines 134–146):
```rust
// crates/server/src/server.rs lines 134-146 — current struct (add two cache fields)
pub struct AppState {
    reader: Reader,
    writer: Writer,
    metrics: Arc<RpcMetrics>,
    rpc_url: Url,
    sui_client: Arc<OnceCell<sui_sdk::SuiClient>>,
    deepbook_package_id: String,
    deep_token_package_id: String,
    deep_treasury_id: String,
    admin_tokens: Vec<Secret<String>>,
    admin_auth_limiter: Arc<AdminRateLimiter>,
    margin_package_id: Option<String>,
    // ADD THESE TWO:
    pools_cache: moka::future::Cache<(), Vec<Pools>>,
    ticker_cache: moka::future::Cache<(), serde_json::Value>,
}
```

**Cache construction to add in `AppState::new`** (after `server.rs` line 190, before `Ok(Self { ... })`):
```rust
// Add after line 190 in AppState::new:
let pools_cache = moka::future::Cache::builder()
    .max_capacity(1)
    .time_to_live(std::time::Duration::from_secs(60))
    .build();
let ticker_cache = moka::future::Cache::builder()
    .max_capacity(1)
    .time_to_live(std::time::Duration::from_secs(10))
    .build();
```

**Cache construction fields in `Ok(Self { ... })`** (from `server.rs` lines 191–204 — add two fields):
```rust
// server.rs lines 191-204: add pools_cache and ticker_cache to Ok(Self { ... })
Ok(Self {
    reader,
    writer,
    metrics,
    rpc_url,
    sui_client: Arc::new(OnceCell::new()),
    deepbook_package_id,
    deep_token_package_id,
    deep_treasury_id,
    admin_tokens,
    admin_auth_limiter,
    margin_package_id,
    pools_cache,   // ADD
    ticker_cache,  // ADD
})
```

**Cache usage in handler** (applied to `get_pools` at `server.rs` line 533, which moves to
`routes/pools.rs` under SCALE-01):
```rust
// Pattern from RESEARCH.md Pattern 3 — applied to get_pools
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

**`make_router` final shape after SCALE-01** (from `server.rs` lines 340–434 — replace the
flat route list with sub-router merges):
```rust
// crates/server/src/server.rs lines 340-434 — current make_router (replace body)
pub(crate) fn make_router(state: Arc<AppState>) -> Router {
    let cors = CorsLayer::new()
        .allow_methods(AllowMethods::list(vec![
            Method::GET, Method::POST, Method::PUT,
            Method::DELETE, Method::OPTIONS,
        ]))
        .allow_headers(Any)
        .allow_origin(Any);

    // REPLACE the db_routes + rpc_routes flat blocks with:
    crate::routes::pools::router()
        .merge(crate::routes::orders::router())
        .merge(crate::routes::portfolio::router())
        .merge(crate::routes::margin::router())
        .merge(crate::routes::points::router())
        .merge(crate::routes::health::router())
        .with_state(state.clone())
        .nest("/admin", admin_routes(state.clone()).with_state(state.clone()))
        .layer(cors)
        .layer(from_fn_with_state(state, track_metrics))
}
```

---

### `crates/server/Cargo.toml` (modified — add moka)

**Analog:** Existing `[dependencies]` block (`Cargo.toml` lines 9–38)

**Exact addition** (after the `thiserror` line, ~line 33):
```toml
# crates/server/Cargo.toml — add under [dependencies]
moka = { version = "0.12", features = ["future"] }
```

No other changes to Cargo.toml.

---

### `crates/server/src/lib.rs` (modified — add module declarations)

**Analog:** Existing declarations at `lib.rs` lines 1–9:
```rust
// crates/server/src/lib.rs — current state
pub mod admin;
pub mod error;
pub mod margin_metrics;
mod metrics;
mod reader;
pub mod server;
pub mod writer;
```

**Changes to make:**
```rust
// Add these two lines:
pub mod routes;   // new routes/ directory (SCALE-01)
pub mod utils;    // new utils.rs (SCALE-03)
```

---

## Shared Patterns

### Error Handling
**Source:** `crates/server/src/error.rs` (full file, 98 lines)
**Apply to:** All new route handler files
```rust
// crates/server/src/error.rs lines 31-57 — constructor methods to use in handlers
impl DeepBookError {
    pub fn not_found(resource: impl Into<String>) -> Self { ... }
    pub fn database(msg: impl Into<String>) -> Self { ... }
    pub fn bad_request(msg: impl Into<String>) -> Self { ... }
    pub fn rpc(msg: impl Into<String>) -> Self { ... }
    pub fn internal(msg: impl Into<String>) -> Self { ... }
}
```

All handlers return `Result<Json<T>, DeepBookError>`. Errors are returned with `?` or
constructed with the factory methods. `DeepBookError` implements `IntoResponse` — no manual
status mapping in handlers.

### State Access
**Source:** `crates/server/src/server.rs` lines 134–236
**Apply to:** All new route handler files

All handlers access state as `State(state): State<Arc<AppState>>` — never `State<AppState>`.
State fields accessed as `state.reader.*`, `state.writer().*`, `state.sui_client().await?`,
`state.metrics().*`, `state.margin_package_id.*`.

### ParameterUtil
**Source:** `crates/server/src/server.rs` lines 2071–2109 (to move to `routes/mod.rs`)
**Apply to:** All route sub-modules that parse `HashMap<String, String>` query params

All handlers using time-range or limit parameters call `params.start_time()`,
`params.end_time()`, `params.limit()`, `params.volume_in_base()` from the trait impl — never
inline `.get("limit").and_then(|v| v.parse::<i64>().ok()).unwrap_or(...)` directly.

### DX-03 Typed Params Struct
**Source:** `crates/server/src/server.rs` lines 239–255 (`StatusQueryParams` — proof-of-concept)
**Apply to:** `routes/orders.rs` (`orders`, `trades`), `routes/portfolio.rs` (`portfolio`)

New `PaginationParams` struct copies the `StatusQueryParams` serde defaults pattern:
```rust
// Pattern from server.rs lines 239-255 — applied to pagination
#[derive(Debug, serde::Deserialize)]
pub struct PaginationParams {
    #[serde(default = "default_limit")]
    pub limit: i64,
    pub start_time: Option<i64>,
    pub end_time: Option<i64>,
}
fn default_limit() -> i64 { 100 }
```

### DX-03 Wallet Extractor
**Source:** `crates/server/src/reader.rs` lines 1451–1459 (logic to lift)
**Apply to:** `routes/portfolio.rs` `portfolio` handler only (Phase 2 scope)

```rust
// Axum extractor pattern (new code) referencing axum 0.7 FromRequestParts
use axum::{async_trait, extract::{FromRequestParts, Path}, http::request::Parts};

pub struct ValidatedWalletAddress(pub String);

#[async_trait]
impl<S: Send + Sync> FromRequestParts<S> for ValidatedWalletAddress {
    type Rejection = DeepBookError;
    async fn from_request_parts(parts: &mut Parts, state: &S) -> Result<Self, Self::Rejection> {
        let Path(addr) = Path::<String>::from_request_parts(parts, state).await
            .map_err(|_| DeepBookError::bad_request("Missing wallet address"))?;
        // Exact logic from reader.rs lines 1451-1459:
        if !addr.starts_with("0x")
            || addr.len() != 66
            || !addr[2..].chars().all(|c| c.is_ascii_hexdigit())
        {
            return Err(DeepBookError::bad_request(
                "Invalid wallet address: expected 0x-prefixed 64-character hex string",
            ));
        }
        Ok(ValidatedWalletAddress(addr))
    }
}
```

Place this extractor in `routes/portfolio.rs` or a new `routes/extractors.rs` imported by
`routes/mod.rs`.

---

## No Analog Found

All files have close analogs in the codebase. No entries.

---

## Ordering Note for Planner

RESEARCH.md recommends: SCALE-01 first, then SCALE-02, SCALE-03, PERF-05, DX-03 in parallel
on top of the split structure. This avoids merge conflicts because the latter four all modify
code that moves to new files under SCALE-01.

---

## Metadata

**Analog search scope:** `crates/server/src/` (server.rs, reader.rs, admin/routes.rs,
admin/handlers.rs, error.rs, lib.rs) and `crates/server/Cargo.toml`
**Files scanned:** 8
**Pattern extraction date:** 2026-04-30
