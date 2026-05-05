# Phase 3: OpenAPI Docs - Pattern Map

**Mapped:** 2026-04-30
**Files analyzed:** 10 new/modified files
**Analogs found:** 10 / 10

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `crates/server/Cargo.toml` | config | — | `crates/schema/Cargo.toml` | exact (sibling Cargo.toml with optional feature pattern) |
| `crates/schema/Cargo.toml` | config | — | `crates/server/Cargo.toml` | exact (same workspace, additive dep) |
| `crates/server/src/server.rs` | route-assembler | request-response | `crates/server/src/admin/routes.rs` | role-match (Router assembly) |
| `crates/server/src/reader.rs` | model | transform | `crates/schema/src/models.rs` | role-match (typed response structs) |
| `crates/server/src/routes/pools.rs` | route-handler | request-response | `crates/server/src/server.rs` lines 532–544 | exact (get_pools handler pattern) |
| `crates/server/src/routes/orders.rs` | route-handler | request-response | `crates/server/src/server.rs` lines 1256–1402 | exact (trades handler with Path+Query) |
| `crates/server/src/routes/portfolio.rs` | route-handler | request-response | `crates/server/src/server.rs` lines 2851+ | exact (portfolio handler) |
| `crates/server/src/routes/margin.rs` | route-handler | request-response | `crates/server/src/server.rs` lines 2160–2180 | exact (margin event handlers) |
| `crates/server/src/routes/points.rs` | route-handler | request-response | `crates/server/src/server.rs` lines 2817–2849 | exact (get_points handler) |
| `crates/server/src/routes/health.rs` | route-handler | request-response | `crates/server/src/server.rs` lines 436–530 | exact (health_check + status) |
| `crates/server/src/routes/mod.rs` | module-index | — | `crates/server/src/admin/mod.rs` | role-match |

---

## Pattern Assignments

### `crates/server/Cargo.toml` (config — add utoipa deps)

**Analog:** `crates/server/Cargo.toml` (existing file, additive change only)

**What to add** — append after `thiserror` line:
```toml
utoipa = { version = "5", features = ["axum_extras", "chrono"] }
utoipa-swagger-ui = { version = "9", features = ["axum"] }
```

**Existing dep format** (lines 26–27 show version style in this file):
```toml
axum = { version = "0.7", features = ["json"] }
tower-http = { version = "0.5", features = ["cors"] }
```
Copy that exact style: `name = { version = "X", features = [...] }`.

---

### `crates/schema/Cargo.toml` (config — add optional utoipa feature)

**Analog:** `crates/schema/Cargo.toml` (existing file, additive change only)

**Existing structure** (lines 1–18 — the full file):
```toml
[package]
name = "deepbook-schema"
...

[dependencies]
...
bigdecimal = { version = "0.4", features = ["serde"] }
chrono = "0.4"
```

**What to add** — insert after `[dependencies]` block:
```toml
utoipa = { version = "5", features = ["chrono"], optional = true }

[features]
openapi = ["utoipa"]
```

The `features = ["chrono"]` on the utoipa dep is critical: it makes `chrono::NaiveDateTime`
implement `ToSchema` (maps to string in the spec). Without this feature, every `NaiveDateTime`
field in `MarginManagerState` and `MarginPoolSnapshot` will fail to compile with
`error[E0277]: the trait bound chrono::NaiveDateTime: utoipa::ToSchema is not satisfied`.

---

### `crates/server/src/server.rs` (route-assembler — add ApiDoc + SwaggerUi)

**Analog:** `crates/server/src/admin/routes.rs` (Router assembly pattern)

**Existing make_router signature and merge pattern** (lines 340–434):
```rust
pub(crate) fn make_router(state: Arc<AppState>) -> Router {
    let cors = CorsLayer::new()...;
    let db_routes = Router::new()
        .route(GET_POOLS_PATH, get(get_pools))
        // ... 40+ routes ...
        .with_state(state.clone());
    let rpc_routes = Router::new()
        .route(LEVEL2_PATH, get(orderbook))
        // ... 6 routes ...
        .with_state(state.clone());
    let admin = admin_routes(state.clone()).with_state(state.clone());

    db_routes
        .merge(rpc_routes)
        .nest("/admin", admin)
        .layer(cors)
        .layer(from_fn_with_state(state, track_metrics))
}
```

**What to add** — new imports at top of file:
```rust
use utoipa::OpenApi;
use utoipa_swagger_ui::SwaggerUi;
```

**ApiDoc struct to define in server.rs** (place after the `AppState` impl block, before `make_router`):
```rust
#[derive(OpenApi)]
#[openapi(
    info(title = "DeepBook v3 API", version = "1.0.0",
         description = "DeepBook v3 indexer REST API"),
    paths(
        crate::routes::health::health_check,
        crate::routes::health::status,
        // ... all pub handler fns listed here after Phase 2 split ...
    ),
    components(schemas(
        deepbook_schema::models::Pools,
        deepbook_schema::models::PoolCreated,
        // ... all ToSchema types ...
    )),
    tags(
        (name = "health",    description = "Server health and indexer status"),
        (name = "pools",     description = "Pool data and trading volume"),
        (name = "orders",    description = "Trades, order fills, and OHCLV"),
        (name = "portfolio", description = "Wallet portfolio and deposits"),
        (name = "margin",    description = "Margin trading event history"),
        (name = "points",    description = "Trading points"),
    )
)]
pub struct ApiDoc;
```

**SwaggerUi merge** — modify the terminal chain in `make_router` (lines 429–433):
```rust
// BEFORE:
db_routes
    .merge(rpc_routes)
    .nest("/admin", admin)
    .layer(cors)
    .layer(from_fn_with_state(state, track_metrics))

// AFTER (note: .with_state() must precede SwaggerUi merge — Pitfall 7):
db_routes
    .merge(rpc_routes)
    .nest("/admin", admin)
    .with_state(state.clone())
    .merge(SwaggerUi::new("/swagger-ui")
        .url("/api-docs/openapi.json", ApiDoc::openapi()))
    .layer(cors)
    .layer(from_fn_with_state(state, track_metrics))
```

**Critical:** `.with_state(state.clone())` must appear before `.merge(SwaggerUi::new(...))`.
`SwaggerUi` is a `Router<()>` (stateless). Merging it with a `Router<Arc<AppState>>` before
resolving state causes `error[E0308]: mismatched types`. This is the most common utoipa-axum
integration error in Axum 0.7.

---

### `crates/schema/src/models.rs` (model — add `#[derive(ToSchema)]` to schema structs)

**Analog:** `crates/schema/src/models.rs` itself — the existing `#[cfg_attr]` and `#[serde(...)]`
patterns already present on `MarginManagerState` (lines 869–905) show how to apply conditional
attributes and field-level serialization overrides.

**Existing conditional attribute pattern** (lines 881–896):
```rust
// Already in models.rs — MarginManagerState uses #[serde(...)] field overrides.
// Apply the same #[cfg_attr(feature = "openapi", ...)] style.
#[serde(serialize_with = "serialize_bigdecimal_option")]
pub risk_ratio: Option<BigDecimal>,
#[serde(serialize_with = "serialize_datetime")]
pub created_at: chrono::NaiveDateTime,
```

**Pattern for simple schema model structs** (all-String/i64/bool fields — e.g., `AssetSupplied`,
`LoanBorrowed`, `MarginManagerCreated`, `PoolCreated`, `BookParamsUpdated`, `ReferralFeeEvent`, etc.):
```rust
// Analog: PoolCreated (lines 264–281) — Serialize already present, just add ToSchema
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = pool_created, primary_key(event_digest))]
pub struct PoolCreated {
    pub event_digest: String,
    // ... all primitive fields — no overrides needed
}
```

**Pattern for BigDecimal fields** — `Liquidation` (lines 539–563), `CollateralEvent` (lines 944–966):
```rust
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = liquidation, primary_key(event_digest))]
pub struct Liquidation {
    pub event_digest: String,
    // ... String/i64/bool fields unchanged ...
    #[cfg_attr(feature = "openapi", schema(value_type = String))]
    pub remaining_base_asset: BigDecimal,
    #[cfg_attr(feature = "openapi", schema(value_type = String))]
    pub remaining_quote_asset: BigDecimal,
    #[cfg_attr(feature = "openapi", schema(value_type = String))]
    pub remaining_base_debt: BigDecimal,
    #[cfg_attr(feature = "openapi", schema(value_type = String))]
    pub remaining_quote_debt: BigDecimal,
    // ...
}
```

**Pattern for `serde_json::Value` fields** — `MarginPoolCreated` (lines 601–615),
`InterestParamsUpdated` (lines 633–646), `MarginPoolConfigUpdated` (lines 648–661),
`DeepbookPoolConfigUpdated` (lines 706–718), `DeepbookPoolRegistered` (lines 678–690):
```rust
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = margin_pool_created, primary_key(event_digest))]
pub struct MarginPoolCreated {
    pub event_digest: String,
    // ... String/i64 fields ...
    #[cfg_attr(feature = "openapi", schema(value_type = Object))]
    pub config_json: serde_json::Value,
    pub onchain_timestamp: i64,
}
```

**Pattern for `Option<serde_json::Value>` fields** — `DeepbookPoolRegistered` (line 688):
```rust
#[cfg_attr(feature = "openapi", schema(value_type = Option<Object>))]
pub config_json: Option<serde_json::Value>,
```

**Pattern for `BigDecimal` + `chrono::NaiveDateTime` fields** — `MarginManagerState`
(lines 869–905). With `utoipa = { features = ["chrono"] }` in schema Cargo.toml,
`NaiveDateTime` becomes a `String` schema automatically. `BigDecimal` still needs
`schema(value_type = String)` per-field:
```rust
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
#[derive(Queryable, Selectable, Identifiable, Debug, Serialize)]
#[diesel(table_name = margin_manager_state)]
pub struct MarginManagerState {
    pub margin_manager_id: String,
    // ...
    #[serde(serialize_with = "serialize_bigdecimal_option")]
    #[cfg_attr(feature = "openapi", schema(value_type = Option<String>))]
    pub risk_ratio: Option<BigDecimal>,
    // ... other BigDecimal fields — same pattern ...
    // chrono::NaiveDateTime — NO schema override needed with "chrono" feature:
    #[serde(serialize_with = "serialize_datetime")]
    pub created_at: chrono::NaiveDateTime,
    pub updated_at: chrono::NaiveDateTime,
}
```

**Full list of schema model structs needing `ToSchema`** (all in `crates/schema/src/models.rs`):

| Struct | Lines | Special fields | Override needed |
|--------|-------|----------------|-----------------|
| `Pools` | 461–477 | none | none |
| `PoolCreated` | 264–281 | none | none |
| `BookParamsUpdated` | 283–297 | none | none |
| `MarginManagerCreated` | 491–505 | none | none |
| `LoanBorrowed` | 507–521 | none | none |
| `LoanRepaid` | 523–537 | none | none |
| `Liquidation` | 539–563 | `BigDecimal` x4 | `schema(value_type = String)` x4 |
| `AssetSupplied` | 566–581 | none | none |
| `AssetWithdrawn` | 583–598 | none | none |
| `MarginPoolCreated` | 601–615 | `serde_json::Value` | `schema(value_type = Object)` |
| `DeepbookPoolUpdated` | 617–631 | none | none |
| `InterestParamsUpdated` | 633–646 | `serde_json::Value` | `schema(value_type = Object)` |
| `MarginPoolConfigUpdated` | 648–661 | `serde_json::Value` | `schema(value_type = Object)` |
| `MaintainerCapUpdated` | 663–676 | none | none |
| `DeepbookPoolRegistered` | 678–690 | `Option<serde_json::Value>` | `schema(value_type = Option<Object>)` |
| `DeepbookPoolUpdatedRegistry` | 692–704 | none | none |
| `DeepbookPoolConfigUpdated` | 706–718 | `serde_json::Value` | `schema(value_type = Object)` |
| `MaintainerFeesWithdrawn` | 720–734 | none | none |
| `ProtocolFeesWithdrawn` | 736–749 (approx) | none | none |
| `SupplierCapMinted` | (search) | none | none |
| `SupplyReferralMinted` | (search) | none | none |
| `PauseCapUpdated` | (search) | none | none |
| `ProtocolFeesIncreasedEvent` | (search) | none | none |
| `ReferralFeesClaimedEvent` | 852–866 | none | none |
| `ReferralFeeEvent` | 348–362 | none | none |
| `CollateralEvent` | 944–966 | `BigDecimal` x6+ | `schema(value_type = String/Option<String>)` |
| `MarginManagerState` | 869–905 | `BigDecimal` x8, `NaiveDateTime` x2 | `schema(value_type = Option<String>)` per BigDecimal |

---

### `crates/server/src/reader.rs` (model — add `ToSchema` to server-local types)

**Analog:** `crates/server/src/reader.rs` lines 1785–1833 — these are the existing
portfolio response structs. They already use `#[derive(Debug, serde::Serialize)]`.

**Existing server-local struct pattern** (lines 1785–1791):
```rust
#[derive(Debug, serde::Serialize)]
pub struct PortfolioQueryResult {
    pub margin_positions: Vec<PortfolioMarginPosition>,
    pub collateral_balances: Vec<PortfolioCollateralBalance>,
    pub lp_positions: Vec<PortfolioLpPosition>,
    pub summary: PortfolioSummary,
}
```

**What to add** — `utoipa::ToSchema` to each of these 5 structs. No feature gate needed
(server crate has unconditional utoipa dep):
```rust
#[derive(Debug, serde::Serialize, utoipa::ToSchema)]
pub struct PortfolioQueryResult { ... }

#[derive(Debug, serde::Serialize, utoipa::ToSchema)]
pub struct PortfolioMarginPosition { ... }

#[derive(Debug, serde::Serialize, utoipa::ToSchema)]
pub struct PortfolioCollateralBalance { ... }

#[derive(Debug, serde::Serialize, utoipa::ToSchema)]
pub struct PortfolioLpPosition { ... }

#[derive(Debug, serde::Serialize, utoipa::ToSchema)]
pub struct PortfolioSummary { ... }
```

**`PoolFees` struct** (server.rs lines 1779–1785) — add `ToSchema`:
```rust
#[derive(serde::Serialize, utoipa::ToSchema)]
struct PoolFees {
    pool_id: String,
    taker_fee: f64,
    maker_fee: f64,
    stake_required: f64,
}
```

**`BalanceManagerDepositedAssets` struct** (server.rs lines 2734–2738) — add `ToSchema`:
```rust
#[derive(serde::Serialize, utoipa::ToSchema)]
struct BalanceManagerDepositedAssets {
    balance_manager_id: String,
    assets: Vec<String>,
}
```

---

### New file: `crates/server/src/api_types.rs` (typed response structs for dynamic JSON handlers)

**Analog:** `crates/server/src/reader.rs` lines 1785–1833 — same pattern of `#[derive(Debug, Serialize)]`
structs defined in-server for response types.

**Base pattern for all new typed response structs** (no field-level overrides needed — all fields
are primitives, String, f64, i64, bool):
```rust
// crates/server/src/api_types.rs

use serde::Serialize;
use utoipa::ToSchema;

/// Response for /status endpoint
#[derive(Debug, Serialize, ToSchema)]
pub struct StatusResponse {
    pub status: String,
    pub latest_onchain_checkpoint: u64,
    pub current_time_ms: i64,
    pub earliest_checkpoint: i64,
    pub max_lag_pipeline: String,
    pub pipelines: Vec<serde_json::Value>,   // nested dynamic — use Object
    pub max_checkpoint_lag: i64,
    pub max_time_lag_seconds: i64,
}
```

Note on `pipelines` field above: it is a `Vec<serde_json::Value>`. Either use
`#[schema(value_type = Vec<Object>)]` or define a `PipelineStatus` substruct. The RESEARCH.md
recommends minimal new code — use `#[schema(value_type = Vec<Object>)]` for the pipelines
field if a sub-struct is too costly.

**Full list of new structs for `api_types.rs`**:

| Struct | Handler | Fields |
|--------|---------|--------|
| `TradeRecord` | `trades` | `event_digest`, `digest`, `trade_id: String`, `maker_order_id`, `taker_order_id`, `maker_client_order_id: i64`, `taker_client_order_id: i64`, `price: f64`, `base_quantity: f64`, `quote_quantity: f64`, `taker_is_bid: bool`, `timestamp: i64`, `maker_balance_manager_id`, `taker_balance_manager_id`, `taker_fee: f64`, `maker_fee: f64`, `taker_fee_is_deep: bool`, `maker_fee_is_deep: bool`, `type: String` |
| `OrderUpdateRecord` | `order_updates` | mirror of `OrderUpdate` model with formatted fields |
| `OrderRecord` | `orders` | mirror of `OrderStatus` model fields + derived fields |
| `OhclvResponse` | `ohclv` | `pool_name: String`, `candles: Vec<OhclvCandle>` |
| `OhclvCandle` | — | `timestamp_ms: i64`, `open: f64`, `high: f64`, `low: f64`, `close: f64`, `volume: f64` |
| `OrderbookResponse` | `orderbook` | `pool_name: String`, `bids: Vec<[f64; 2]>`, `asks: Vec<[f64; 2]>` |
| `TickerEntry` | `ticker` | pool-level ticker fields |
| `SummaryEntry` | `summary` | CoinMarketCap-style summary fields |
| `AssetEntry` | `assets` | asset config fields |
| `PointsEntry` | `get_points` | address-level points fields |
| `MarginManagerInfo` | `margin_managers_info` | manager info fields |

**Placement guidance from RESEARCH.md Open Question 1:** Define each struct in its route module
(e.g., `TradeRecord` in `routes/orders.rs`). Only create `api_types.rs` if 3+ route modules
share the same type. Given all structs are module-local, per-module definition is preferred.

---

### `crates/server/src/routes/health.rs` (route-handler, request-response)

**Analog:** `crates/server/src/server.rs` lines 436–530

**Existing handler patterns to copy** (lines 436–438 and 441–530):
```rust
// Simplest handler — no args:
async fn health_check() -> StatusCode {
    StatusCode::OK
}

// Handler with typed query params struct:
async fn status(
    Query(params): Query<StatusQueryParams>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<serde_json::Value>, DeepBookError> {
    // ...
    Ok(Json(serde_json::json!({ ... })))
}
```

**What to add — `#[utoipa::path]` annotations**:
```rust
// health_check — primitive return (no body schema):
#[utoipa::path(
    get,
    path = "/",
    tag = "health",
    responses(
        (status = 200, description = "Server is alive")
    )
)]
pub async fn health_check() -> StatusCode {
    StatusCode::OK
}

// status — typed query params + typed response:
#[utoipa::path(
    get,
    path = "/status",        // ← string literal, NOT the STATUS_PATH const (Pitfall 5)
    tag = "health",
    params(
        ("max_checkpoint_lag" = Option<i64>, Query, description = "Max acceptable checkpoint lag (default: 100)"),
        ("max_time_lag_seconds" = Option<i64>, Query, description = "Max acceptable time lag in seconds (default: 60)"),
    ),
    responses(
        (status = 200, description = "Indexer pipeline status", body = StatusResponse),
        (status = 500, description = "Internal server error")
    )
)]
pub async fn status(
    Query(params): Query<StatusQueryParams>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<serde_json::Value>, DeepBookError> { ... }
```

**Visibility change:** All handlers must be `pub` (Pitfall 4). Current handlers in server.rs
are `async fn` (private). After Phase 2 splits them into route modules, make them `pub async fn`.

---

### `crates/server/src/routes/pools.rs` (route-handler, request-response)

**Analog:** `crates/server/src/server.rs` lines 532–544

**Simplest handler** (lines 532–534):
```rust
async fn get_pools(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<Pools>>, DeepBookError> {
    Ok(Json(state.reader.get_pools().await?))
}
```

**What to add**:
```rust
#[utoipa::path(
    get,
    path = "/get_pools",
    tag = "pools",
    responses(
        (status = 200, description = "List of all registered pools", body = [Pools]),
        (status = 500, description = "Internal server error")
    )
)]
pub async fn get_pools(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<Pools>>, DeepBookError> {
    Ok(Json(state.reader.get_pools().await?))
}
```

**Handler with Path + Query params** (lines 537–544 — `historical_volume`):
```rust
async fn historical_volume(
    Path(pool_names): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<HashMap<String, u64>>, DeepBookError> { ... }
```

**Annotation pattern for HashMap query params** (Pitfall 6 — must use inline `params()`):
```rust
#[utoipa::path(
    get,
    path = "/historical_volume/{pool_names}",
    tag = "pools",
    params(
        ("pool_names" = String, Path, description = "Comma-separated pool names"),
        ("start_time" = Option<i64>, Query, description = "Start time ms since epoch"),
        ("end_time" = Option<i64>, Query, description = "End time ms since epoch"),
        ("volume_in_base" = Option<bool>, Query, description = "If true, return base volume; else quote volume"),
    ),
    responses(
        (status = 200, description = "Volume per pool in requested asset", body = inline(HashMap<String, u64>)),
    )
)]
pub async fn historical_volume(...) { ... }
```

---

### `crates/server/src/routes/orders.rs` (route-handler, request-response)

**Analog:** `crates/server/src/server.rs` lines 1256–1402 (`trades` handler)

**Existing complex handler signature** (lines 1256–1260):
```rust
async fn trades(
    Path(pool_name): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<HashMap<String, Value>>>, DeepBookError> { ... }
```

**Annotation pattern** (combines Path param + multiple optional Query params + typed body):
```rust
#[utoipa::path(
    get,
    path = "/trades/{pool_name}",
    tag = "orders",
    params(
        ("pool_name" = String, Path, description = "Pool name, e.g. DEEP_SUI"),
        ("start_time" = Option<i64>, Query, description = "Start time ms since epoch"),
        ("end_time" = Option<i64>, Query, description = "End time ms since epoch"),
        ("limit" = Option<i64>, Query, description = "Max records (default: 1)"),
        ("balance_manager_id" = Option<String>, Query, description = "Filter by balance manager ID"),
        ("maker_balance_manager_id" = Option<String>, Query, description = "Filter by maker balance manager ID"),
        ("taker_balance_manager_id" = Option<String>, Query, description = "Filter by taker balance manager ID"),
    ),
    responses(
        (status = 200, description = "Trade fill records", body = [TradeRecord]),
        (status = 404, description = "Pool not found"),
        (status = 500, description = "Internal server error")
    )
)]
pub async fn trades(
    Path(pool_name): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<HashMap<String, Value>>>, DeepBookError> { ... }
```

**Multi-segment path** (two Path segments — `orders` handler uses `Path((pool_name, balance_manager_id))`):
```rust
#[utoipa::path(
    get,
    path = "/orders/{pool_name}/{balance_manager_id}",
    tag = "orders",
    params(
        ("pool_name" = String, Path, description = "Pool name, e.g. DEEP_SUI"),
        ("balance_manager_id" = String, Path, description = "Balance manager object ID"),
        ("limit" = Option<i64>, Query, description = "Max results (default: 1000)"),
        ("start_time" = Option<i64>, Query, description = "Start time ms since epoch"),
        ("end_time" = Option<i64>, Query, description = "End time ms since epoch"),
        ("status" = Option<String>, Query, description = "Filter: placed,canceled,filled,partially_filled,expired"),
    ),
    responses(
        (status = 200, description = "Order records", body = [OrderRecord]),
    )
)]
pub async fn orders(
    Path((pool_name, balance_manager_id)): Path<(String, String)>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<HashMap<String, Value>>>, DeepBookError> { ... }
```

---

### `crates/server/src/routes/margin.rs` (route-handler, request-response)

**Analog:** `crates/server/src/server.rs` lines 2160–2178 (`margin_manager_created` handler)

**Existing minimal margin event handler** (lines 2159–2178):
```rust
async fn margin_manager_created(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<MarginManagerCreated>>, DeepBookError> {
    let start_time = params.start_time().unwrap_or(0);
    let end_time = params.end_time();
    let limit = params.limit();
    Ok(Json(
        state.reader.get_margin_manager_created(start_time, end_time, limit).await?,
    ))
}
```

**Annotation pattern** (all ~20 margin event handlers follow this same shape):
```rust
#[utoipa::path(
    get,
    path = "/margin_manager_created",
    tag = "margin",
    params(
        ("start_time" = Option<i64>, Query, description = "Start time ms since epoch"),
        ("end_time" = Option<i64>, Query, description = "End time ms since epoch"),
        ("limit" = Option<i64>, Query, description = "Max records (default: 100)"),
    ),
    responses(
        (status = 200, description = "Margin manager created events", body = [MarginManagerCreated]),
        (status = 500, description = "Internal server error")
    )
)]
pub async fn margin_manager_created(
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<MarginManagerCreated>>, DeepBookError> { ... }
```

All 23 margin handlers follow this same `Query<HashMap<String, String>>` + `State` + `Vec<SchemaType>`
return pattern. Just change: `path`, `description`, `body` type, and handler name.

**Exception — `margin_manager_states`** has additional Path-style query filters
(not a path segment but query params like `deepbook_pool_id`, `max_risk_ratio`, etc.):
```rust
#[utoipa::path(
    get,
    path = "/margin_manager_states",
    tag = "margin",
    params(
        ("max_risk_ratio" = Option<f64>, Query, description = "Filter by max risk ratio"),
        ("deepbook_pool_id" = Option<String>, Query, description = "Filter by DeepBook pool ID"),
        ("base_asset_symbol" = Option<String>, Query, description = "Filter by base asset symbol"),
        ("quote_asset_symbol" = Option<String>, Query, description = "Filter by quote asset symbol"),
    ),
    responses(
        (status = 200, description = "Margin manager state records", body = [MarginManagerState]),
    )
)]
```

---

### `crates/server/src/routes/portfolio.rs` (route-handler, request-response)

**Analog:** `crates/server/src/server.rs` lines 2851+ (`portfolio` handler)

**Existing handler** (lines 2851–2853):
```rust
async fn portfolio(
    Path(wallet_address): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<PortfolioQueryResult>, DeepBookError> { ... }
```

**Annotation pattern**:
```rust
#[utoipa::path(
    get,
    path = "/portfolio/{wallet_address}",
    tag = "portfolio",
    params(
        ("wallet_address" = String, Path, description = "Wallet address (Sui address)"),
    ),
    responses(
        (status = 200, description = "Portfolio summary including margin positions and LP positions",
         body = PortfolioQueryResult),
        (status = 404, description = "No portfolio data found for wallet"),
        (status = 500, description = "Internal server error")
    )
)]
pub async fn portfolio(
    Path(wallet_address): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<PortfolioQueryResult>, DeepBookError> { ... }
```

**`deposited_assets` handler** (lines 2740–2743):
```rust
#[utoipa::path(
    get,
    path = "/deposited_assets/{balance_manager_ids}",
    tag = "portfolio",
    params(
        ("balance_manager_ids" = String, Path, description = "Comma-separated balance manager IDs"),
    ),
    responses(
        (status = 200, description = "Deposited assets per balance manager", body = [BalanceManagerDepositedAssets]),
    )
)]
pub async fn deposited_assets(
    Path(balance_manager_ids): Path<String>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<BalanceManagerDepositedAssets>>, DeepBookError> { ... }
```

---

### `crates/server/src/routes/points.rs` (route-handler, request-response)

**Analog:** `crates/server/src/server.rs` lines 2812–2849 (`get_points` handler with typed query struct)

**Existing typed query struct pattern** (lines 2812–2819):
```rust
#[derive(Deserialize)]
struct GetPointsQuery {
    addresses: Option<String>,
}

async fn get_points(
    Query(params): Query<GetPointsQuery>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, DeepBookError> { ... }
```

**What to add** — `GetPointsQuery` uses a typed struct, not `HashMap`. Add `IntoParams`:
```rust
#[derive(Deserialize, utoipa::IntoParams)]
#[into_params(parameter_in = Query)]
struct GetPointsQuery {
    /// Comma-separated wallet addresses to filter by
    addresses: Option<String>,
}

#[utoipa::path(
    get,
    path = "/get_points",
    tag = "points",
    params(GetPointsQuery),
    responses(
        (status = 200, description = "Points per wallet address", body = [PointsEntry]),
        (status = 500, description = "Internal server error")
    )
)]
pub async fn get_points(
    Query(params): Query<GetPointsQuery>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<serde_json::Value>>, DeepBookError> { ... }
```

`GetPointsQuery` is the only handler in the codebase that already uses a typed query struct —
making it the natural showcase for the `IntoParams` derive path.

---

### `crates/server/src/routes/mod.rs` (module-index)

**Analog:** `crates/server/src/admin/mod.rs`

No direct analog exists for `IntoParams` impls. If Phase 2 DX-03 introduces `PaginationParams`
or `ValidatedWalletAddress`, this file would `pub use` those types and add `#[derive(IntoParams)]`
to them. Until Phase 2 completes, this file only re-exports the route modules.

**Pattern from admin/mod.rs** (if it follows module re-export convention):
```rust
pub mod auth;
pub mod handlers;
pub mod routes;
```

Apply same pattern for routes/mod.rs:
```rust
pub mod health;
pub mod orders;
pub mod pools;
pub mod portfolio;
pub mod margin;
pub mod points;
```

---

## Shared Patterns

### Error Handling
**Source:** `crates/server/src/error.rs` lines 59–72
**Apply to:** All handler files — error is already `IntoResponse`; `Result<Json<T>, DeepBookError>`
is the standard return type and requires no change for utoipa integration.
```rust
// Handlers already return this pattern — no change needed for utoipa:
) -> Result<Json<Vec<Pools>>, DeepBookError> {
    Ok(Json(state.reader.get_pools().await?))
}
// DeepBookError implements IntoResponse: maps to 404/400/500 status codes
```
utoipa annotation should list the relevant error responses:
```rust
responses(
    (status = 200, description = "...", body = [...]),
    (status = 404, description = "Resource not found"),      // DeepBookError::NotFound
    (status = 400, description = "Invalid request"),         // DeepBookError::BadRequest
    (status = 500, description = "Internal server error")    // all others
)
```

### Path Constant vs Literal String
**Source:** `crates/server/src/server.rs` lines 66–126 (all `pub const *_PATH` definitions)
**Apply to:** All `#[utoipa::path]` annotations
```rust
// The path constants exist for router .route() calls:
pub const TRADES_PATH: &str = "/trades/:pool_name";

// utoipa path attribute CANNOT use constants — must be string literals:
// WRONG:   path = TRADES_PATH
// CORRECT: path = "/trades/{pool_name}"
// Note: Axum uses :param, OpenAPI uses {param} — use {param} in utoipa annotations
```

### Handler Visibility
**Source:** `crates/server/src/server.rs` (all handlers currently private)
**Apply to:** All handler functions after Phase 2 split
```rust
// BEFORE (private — cannot be referenced in ApiDoc paths()):
async fn get_pools(State(state): State<Arc<AppState>>) -> ...

// AFTER (pub — required for ApiDoc to reference them):
pub async fn get_pools(State(state): State<Arc<AppState>>) -> ...
```

### Feature Gate on Schema Crate
**Source:** No existing analog (this is a new pattern for this codebase)
**Apply to:** All `#[derive(ToSchema)]` and `#[schema(...)]` attributes in `crates/schema/src/models.rs`
```rust
// Every ToSchema-related attribute must be wrapped in cfg_attr:
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
pub struct SomeModel { ... }

// Field-level schema override — also wrapped:
#[cfg_attr(feature = "openapi", schema(value_type = String))]
pub bigdecimal_field: BigDecimal,
```
The server crate activates the feature by depending on `deepbook-schema` with:
```toml
deepbook-schema = { path = "../schema", features = ["openapi"] }
```

### Axum State Extraction Pattern
**Source:** `crates/server/src/server.rs` lines 532–534 (repeated in every handler)
**Apply to:** All handlers (unchanged — no utoipa-specific modification needed)
```rust
// Standard extraction order (must be consistent across all handlers):
async fn handler_name(
    Path(...): Path<...>,           // 1. Path params (if any)
    Query(...): Query<...>,         // 2. Query params (if any)
    State(state): State<Arc<AppState>>, // 3. State (always last)
) -> Result<Json<T>, DeepBookError> { ... }
```

---

## No Analog Found

No files are completely without analog. All patterns map directly to existing code in the
server and schema crates.

| File | Role | Data Flow | Status |
|------|------|-----------|--------|
| `crates/server/src/api_types.rs` | model | transform | New file, but follows `reader.rs` portfolio struct pattern exactly |

The only "novel" code is the `#[derive(OpenApi)] struct ApiDoc` definition, for which the
RESEARCH.md provides a complete, verified code example from docs.rs.

---

## Metadata

**Analog search scope:** `crates/server/src/`, `crates/schema/src/`
**Files scanned:** 8 source files + 2 Cargo.toml files
**Pattern extraction date:** 2026-04-30
