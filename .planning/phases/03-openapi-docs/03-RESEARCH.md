# Phase 3: OpenAPI Docs - Research

**Researched:** 2026-04-30
**Domain:** Rust / utoipa 5 / utoipa-swagger-ui 9 / Axum 0.7 / OpenAPI 3.0
**Confidence:** HIGH

---

## Summary

Phase 3 adds a machine-readable OpenAPI 3.0 specification and a live Swagger UI to the
DeepBook v3 server. The server has 50 registered route calls (confirmed by counting `.route(`
invocations in `make_router`) covering approximately 48 distinct URL patterns across 6 domain
modules (pools, orders, portfolio, margin, points, health) — after Phase 2 completes the
server split into `routes/` sub-modules.

The work divides naturally into two concerns. First, wire utoipa's crates into the project:
add `utoipa`, `utoipa-swagger-ui`, and `utoipa-axum` to `Cargo.toml`, define the top-level
`#[derive(OpenApi)]` struct, and mount the Swagger UI and JSON spec routes. Second, annotate
every handler with `#[utoipa::path(...)]` and add `#[derive(ToSchema)]` to the response types
those handlers return.

The major challenge is that roughly half the handlers return `HashMap<String, Value>` or
`Vec<HashMap<String, Value>>` — dynamically-constructed untyped JSON objects. These cannot
derive `ToSchema` directly. For these endpoints, the plan must either define dedicated typed
response structs or use `utoipa`'s `Object` schema type to produce a partial `object`-typed
schema. For DX-01 to be fully compliant ("no undocumented fields"), the correct approach is
to define typed response structs for the 12 untyped-JSON endpoints and add `ToSchema` to them.

The 20+ margin event endpoints that return directly-serialized Diesel model structs (e.g.,
`Vec<LoanBorrowed>`, `Vec<AssetSupplied>`) are simpler: just add `#[derive(ToSchema)]` to
those schema-crate structs. The complication is that `deepbook-schema` is a separate crate,
so adding `utoipa` as an optional/feature-gated dependency to `deepbook-schema` is the clean
path — or alternatively, define wrapper `ToSchema` impls in `crates/server` using newtype
patterns.

**Primary recommendation:** Use `utoipa = "5"`, `utoipa-swagger-ui = { version = "9", features = ["axum"] }`,
and optional `utoipa-axum = "0.2"`. Add `utoipa` as a dependency to `deepbook-schema` with a
`openapi` Cargo feature so schema models can opt-in to `ToSchema` without forcing a non-optional
utoipa dep on the schema crate for unrelated consumers.

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| DX-01 | OpenAPI 3.0 spec generated via `utoipa` served at `/swagger-ui/` — covers all public REST endpoints with request params and response schemas | Route inventory complete (48 endpoints across 6 modules); utoipa 5 + utoipa-swagger-ui 9 confirmed compatible with Axum 0.7; all response types identified; ToSchema strategy documented |
</phase_requirements>

---

## Project Constraints (from CLAUDE.md)

- **Simplicity first:** Minimum code that solves the problem. No speculative abstractions.
- **Surgical changes:** Only touch what the requirement demands. Do not refactor adjacent code.
- **Build verification:** Run `cargo fmt -p deepbook-server` and `cargo build -p deepbook-server` before every commit.
- **No hand-rolling solved problems:** Use utoipa for OpenAPI generation — no manual spec writing.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| OpenAPI spec generation | API / Backend | — | utoipa derives from Rust types at compile time; output is served by the running server process |
| Swagger UI HTML/JS serving | API / Backend | CDN / Static | utoipa-swagger-ui embeds the UI assets in the binary; no CDN needed |
| `#[utoipa::path]` annotations | API / Backend | — | Annotations live on route handler functions in the server crate |
| `#[derive(ToSchema)]` on models | Database / Storage | API / Backend | Schema models are in `deepbook-schema` crate; ToSchema is a presentation concern but lives on the same type |
| Swagger UI route (`/swagger-ui/`) | API / Backend | — | Axum router merge, same as other routes |
| OpenAPI JSON route (`/api-docs/openapi.json`) | API / Backend | — | Axum router merge, same as other routes |

---

## Standard Stack

### Core

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| utoipa | 5.4.0 | Derive-macro OpenAPI spec generation | Zero runtime overhead, compile-time, code-first; STATE.md locked decision [VERIFIED: docs.rs/utoipa/latest] |
| utoipa-swagger-ui | 9.0.2 | Embedded Swagger UI served via Axum | Official utoipa companion; supports Axum >= 0.7 [VERIFIED: docs.rs/utoipa-swagger-ui/latest] |
| utoipa-axum | 0.2.0 | Optional: unified handler registration + spec generation | Eliminates boilerplate of registering paths in OpenApi struct separately from router; OPTIONAL not REQUIRED [VERIFIED: docs.rs/utoipa-axum/latest] |

### Supporting

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| utoipa `macros` feature | included | Required for `#[utoipa::path]` attribute macro | Always needed when annotating handlers |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| utoipa 5 | aide / okapi | utoipa is the STATE.md locked choice; no alternative needed |
| utoipa-axum | Manual `#[openapi(paths(...))]` list | utoipa-axum saves boilerplate but is optional; planner can choose based on scope |

**Installation (add to `crates/server/Cargo.toml`):**
```toml
utoipa = { version = "5", features = ["axum_extras"] }
utoipa-swagger-ui = { version = "9", features = ["axum"] }
# Optional: utoipa-axum = "0.2"
```

**Add to `crates/schema/Cargo.toml` (for ToSchema on model types):**
```toml
[features]
openapi = ["utoipa"]

[dependencies]
utoipa = { version = "5", optional = true }
```

**Version verification:** utoipa 5.4.0 and utoipa-swagger-ui 9.0.2 confirmed from docs.rs.
[VERIFIED: docs.rs/utoipa/latest, docs.rs/utoipa-swagger-ui/latest]

---

## Architecture Patterns

### System Architecture Diagram

```
HTTP Request
     │
     ▼
make_router() [server.rs]
  ├─ routes::pools::router()    ─┐
  ├─ routes::orders::router()    │  each handler annotated
  ├─ routes::portfolio::router() ├─► with #[utoipa::path(...)]
  ├─ routes::margin::router()    │
  ├─ routes::points::router()    │
  ├─ routes::health::router()   ─┘
  │
  ├─ SwaggerUi::new("/swagger-ui")     ← serves HTML/JS UI
  │    .url("/api-docs/openapi.json", ApiDoc::openapi())
  │
  └─ ApiDoc::openapi() [compile-time]
       │
       ▼
    #[derive(OpenApi)]
    struct ApiDoc {
      paths(handler1, handler2, ...),  ← 48 handler fns
      components(schemas(Pools, OrderStatus, ...))  ← ToSchema types
    }
```

### Recommended Project Structure (additions only)

```
crates/server/src/
├── server.rs        — add SwaggerUi merge to make_router; define ApiDoc struct
├── routes/
│   ├── pools.rs     — add #[utoipa::path] to each handler + typed response structs
│   ├── orders.rs    — same
│   ├── portfolio.rs — same
│   ├── margin.rs    — same
│   ├── points.rs    — same
│   └── health.rs    — same

crates/schema/src/
└── models.rs        — add #[derive(ToSchema)] to structs used as response bodies
```

### Pattern 1: Mounting Swagger UI in make_router

**What:** Merge `SwaggerUi` into the existing Axum router. Called once in `make_router`.
**When to use:** Once, in the router assembly function.
**Example:**

```rust
// Source: [CITED: docs.rs/utoipa-swagger-ui/latest/utoipa_swagger_ui/]
// crates/server/src/server.rs — inside make_router()

use utoipa::OpenApi;
use utoipa_swagger_ui::SwaggerUi;

#[derive(OpenApi)]
#[openapi(
    paths(
        crate::routes::health::health_check,
        crate::routes::health::status,
        crate::routes::pools::get_pools,
        // ... all 48 handler fns
    ),
    components(
        schemas(
            Pools, OrderStatus, PortfolioQueryResult,
            // ... all ToSchema types
        )
    ),
    info(title = "DeepBook v3 API", version = "1.0.0")
)]
pub struct ApiDoc;

pub(crate) fn make_router(state: Arc<AppState>) -> Router {
    // ... existing cors, db_routes, rpc_routes, admin ...

    db_routes
        .merge(rpc_routes)
        .nest("/admin", admin)
        .merge(SwaggerUi::new("/swagger-ui")
            .url("/api-docs/openapi.json", ApiDoc::openapi()))
        .layer(cors)
        .layer(from_fn_with_state(state, track_metrics))
}
```

[VERIFIED: docs.rs/utoipa-swagger-ui/latest — `Router::merge(SwaggerUi::new(...).url(...))`]

### Pattern 2: Annotating a Simple Handler (typed response)

**What:** `#[utoipa::path]` above each handler function.
**When to use:** On every public handler after Phase 2 splits them into route modules.

```rust
// Source: [CITED: docs.rs/utoipa/latest/utoipa/attr.path.html]
// crates/server/src/routes/pools.rs

#[utoipa::path(
    get,
    path = "/get_pools",
    tag = "pools",
    responses(
        (status = 200, description = "List of all registered pools", body = [Pools]),
        (status = 500, description = "Internal server error")
    )
)]
async fn get_pools(
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<Pools>>, DeepBookError> {
    Ok(Json(state.reader.get_pools().await?))
}
```

### Pattern 3: Documenting Query Parameters (typed struct with IntoParams)

**What:** Replace `Query<HashMap<String, String>>` documentation with a typed struct
implementing `IntoParams`. The *handler signature* can stay as `HashMap<String, String>` in
pre-Phase-2 code; after Phase 2 introduces typed params structs (DX-03), utoipa `IntoParams`
is used instead.

For handlers that remain `HashMap<String, String>`, use inline `params()` declaration:

```rust
// Source: [CITED: docs.rs/utoipa/latest/utoipa/attr.path.html]
#[utoipa::path(
    get,
    path = "/trades/{pool_name}",
    tag = "orders",
    params(
        ("pool_name" = String, Path, description = "Pool name, e.g. DEEP_SUI"),
        ("start_time" = Option<i64>, Query, description = "Start time in seconds since epoch"),
        ("end_time" = Option<i64>, Query, description = "End time in seconds since epoch"),
        ("limit" = Option<i64>, Query, description = "Max records to return (default: 1)"),
        ("balance_manager_id" = Option<String>, Query, description = "Filter by balance manager ID"),
        ("maker_balance_manager_id" = Option<String>, Query, description = "Filter by maker balance manager ID"),
        ("taker_balance_manager_id" = Option<String>, Query, description = "Filter by taker balance manager ID"),
    ),
    responses(
        (status = 200, description = "Trade records", body = [TradeRecord]),
        (status = 404, description = "Pool not found")
    )
)]
async fn trades(
    Path(pool_name): Path<String>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<HashMap<String, Value>>>, DeepBookError> { ... }
```

For handlers converted by DX-03 to typed structs, use `#[derive(Deserialize, IntoParams)]`:

```rust
// Source: [CITED: docs.rs/utoipa/latest/utoipa/derive.IntoParams.html]
#[derive(Deserialize, IntoParams)]
#[into_params(parameter_in = Query)]
struct TradeQueryParams {
    #[param(default = json!(null))]
    start_time: Option<i64>,
    #[param(default = json!(null))]
    end_time: Option<i64>,
    #[param(default = json!(1))]
    limit: Option<i64>,
}

#[utoipa::path(
    get,
    path = "/trades/{pool_name}",
    params(("pool_name" = String, Path), TradeQueryParams),
    responses((status = 200, body = [TradeRecord]))
)]
```

### Pattern 4: ToSchema on Existing Schema Crate Types

**What:** Add `#[derive(ToSchema)]` to structs in `deepbook-schema` that are returned as JSON
from server handlers. Requires adding `utoipa` as an optional dependency to `deepbook-schema`.

```rust
// Source: [CITED: docs.rs/utoipa/latest/utoipa/derive.ToSchema.html]
// crates/schema/src/models.rs — with utoipa feature gate

#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = pools, primary_key(pool_id))]
pub struct Pools {
    pub pool_id: String,
    pub pool_name: String,
    // ...
}
```

**Alternative (no schema crate changes):** Define `ToSchema` in the server crate using `utoipa`'s
`schema_with` feature or newtype wrappers. This is more verbose but avoids touching the
schema crate. For 20+ model types this becomes unwieldy — the feature-gated approach above
is preferred.

[VERIFIED: utoipa 5 supports `#[cfg_attr]` for conditional derives]

### Pattern 5: Typed Response Structs for Dynamic JSON Endpoints

**What:** For handlers currently returning `Vec<HashMap<String, Value>>` or
`HashMap<String, Value>`, define a named response struct and use it in both the handler
return type and the utoipa `body = TypedResponse` annotation.

**Which endpoints need this** (identified from server.rs return types):

| Handler | Current Return | New Struct Needed |
|---------|---------------|-------------------|
| `status` | `Json<serde_json::Value>` | `StatusResponse` |
| `ticker` | `Json<HashMap<String, HashMap<String, Value>>>` | `HashMap<String, TickerEntry>` + `TickerEntry` |
| `summary` | `Json<Vec<HashMap<String, Value>>>` | `SummaryEntry` |
| `order_updates` | `Json<Vec<HashMap<String, Value>>>` | `OrderUpdateRecord` |
| `orders` | `Json<Vec<HashMap<String, Value>>>` | `OrderRecord` |
| `trades` | `Json<Vec<HashMap<String, Value>>>` | `TradeRecord` |
| `get_historical_volume_by_balance_manager_id` | `Json<HashMap<String, Vec<i64>>>` | primitive, no struct needed |
| `get_historical_volume_by_balance_manager_id_with_interval` | `Json<HashMap<String, HashMap<String, Vec<i64>>>>` | primitive, no struct needed |
| `assets` | `Json<HashMap<String, HashMap<String, Value>>>` | `AssetEntry` |
| `orderbook` | `Json<HashMap<String, Value>>` | `OrderbookResponse` |
| `ohclv` | `Json<HashMap<String, Value>>` with `candles` array | `OhclvResponse` |
| `get_points` | `Json<Vec<serde_json::Value>>` | `PointsEntry` |
| `margin_managers_info` | `Json<Vec<HashMap<String, Value>>>` (likely) | `MarginManagerInfo` |
| `margin_manager_states` | `Json<Vec<MarginManagerState>>` | already typed, just add `ToSchema` |

**Strategy:** Define these in `crates/server/src/api_types.rs` (a new file), add
`#[derive(Serialize, ToSchema)]`, and change handler return types from `HashMap<String, Value>`
to the typed struct. The `serde` serialization must produce the same JSON shape as before.

**Example:**
```rust
// crates/server/src/api_types.rs
use utoipa::ToSchema;
use serde::Serialize;

/// Single trade record from /trades/:pool_name
#[derive(Debug, Serialize, ToSchema)]
pub struct TradeRecord {
    pub trade_id: String,
    pub price: f64,
    pub base_quantity: f64,
    pub quote_quantity: f64,
    pub taker_is_bid: bool,
    pub timestamp: i64,
    pub maker_balance_manager_id: String,
    pub taker_balance_manager_id: String,
    pub taker_fee: f64,
    pub maker_fee: f64,
    pub taker_fee_is_deep: bool,
    pub maker_fee_is_deep: bool,
}
```

When the handler is modified to return `Vec<TradeRecord>`, the `.into_iter().map(...)` logic
currently building the `HashMap` translates directly to building the struct.

**Scope note:** Phase 2's DX-03 is already converting some handlers to typed output. The
typed response structs introduced here for utoipa may overlap with or replace some of that
work. The planner should verify if Phase 2 execution already introduced any typed response
types before creating new ones.

### Anti-Patterns to Avoid

- **Writing the OpenAPI spec manually in YAML/JSON:** utoipa generates it from code. Never
  manually create or maintain a spec file.
- **Adding `ToSchema` to all Diesel model fields including internal ones:** Only structs
  that are returned in `Json<...>` responses need `ToSchema`. Internal DB models not exposed
  in responses should not be annotated.
- **Putting `ApiDoc` in a sub-module and struggling with path references:** Keep `ApiDoc` in
  `server.rs` where it has access to all route module paths via `crate::routes::*`.
- **Using `#[cfg_attr(feature = "openapi", ...)]` inconsistently:** If any `ToSchema` type
  depends on another `ToSchema` type, both must be under the same feature gate or the compiler
  will complain about missing trait impls when the feature is active.

---

## Endpoint Inventory

**Total routes in `make_router`:** 50 `.route()` calls (counted from server.rs).
**Distinct URL patterns:** 48 (the `/` health check + `STATUS_PATH` are separate routes both
going to the `db_routes`/`rpc_routes` grouping, respectively).

### Endpoint Classification by Return Type

| Module | Handler | Return Type | Category |
|--------|---------|-------------|----------|
| **health** | `health_check` | `StatusCode` | primitive |
| **health** | `status` | `Json<serde_json::Value>` | dynamic JSON → `StatusResponse` |
| **health** | `deep_supply` | `Json<u64>` | primitive |
| **health** | `margin_supply` | `Json<HashMap<String, u64>>` | primitive (string key, u64 val) |
| **health** | `fees` | `Json<HashMap<String, PoolFees>>` | typed struct `PoolFees` (already in server.rs) |
| **pools** | `get_pools` | `Json<Vec<Pools>>` | schema model — add `ToSchema` |
| **pools** | `historical_volume` | `Json<HashMap<String, u64>>` | primitive |
| **pools** | `all_historical_volume` | `Json<HashMap<String, u64>>` | primitive |
| **pools** | `get_historical_volume_by_balance_manager_id` | `Json<HashMap<String, Vec<i64>>>` | primitive |
| **pools** | `get_historical_volume_by_balance_manager_id_with_interval` | `Json<HashMap<String, HashMap<String, Vec<i64>>>>` | primitive |
| **pools** | `ticker` | `Json<HashMap<String, HashMap<String, Value>>>` | dynamic JSON → `TickerEntry` |
| **pools** | `summary` | `Json<Vec<HashMap<String, Value>>>` | dynamic JSON → `SummaryEntry` |
| **pools** | `assets` | `Json<HashMap<String, HashMap<String, Value>>>` | dynamic JSON → `AssetEntry` |
| **pools** | `pool_created` | `Json<Vec<PoolCreated>>` | schema model — add `ToSchema` |
| **pools** | `book_params_updated` | `Json<Option<BookParamsUpdated>>` | schema model — add `ToSchema` |
| **orders** | `trade_count` | `Json<i64>` | primitive |
| **orders** | `trades` | `Json<Vec<HashMap<String, Value>>>` | dynamic JSON → `TradeRecord` |
| **orders** | `order_updates` | `Json<Vec<HashMap<String, Value>>>` | dynamic JSON → `OrderUpdateRecord` |
| **orders** | `orders` | `Json<Vec<HashMap<String, Value>>>` | dynamic JSON → `OrderRecord` |
| **orders** | `ohclv` | `Json<HashMap<String, Value>>` | dynamic JSON → `OhclvResponse` |
| **orders** | `orderbook` | `Json<HashMap<String, Value>>` | dynamic JSON → `OrderbookResponse` |
| **portfolio** | `portfolio` | `Json<PortfolioQueryResult>` | server type — add `ToSchema` |
| **portfolio** | `get_net_deposits` | `Json<HashMap<String, i64>>` | primitive |
| **portfolio** | `deposited_assets` | `Json<Vec<BalanceManagerDepositedAssets>>` | server type — add `ToSchema` |
| **points** | `get_points` | `Json<Vec<serde_json::Value>>` | dynamic JSON → `PointsEntry` |
| **margin** | `margin_manager_created` | `Json<Vec<MarginManagerCreated>>` | schema model — add `ToSchema` |
| **margin** | `loan_borrowed` | `Json<Vec<LoanBorrowed>>` | schema model — add `ToSchema` |
| **margin** | `loan_repaid` | `Json<Vec<LoanRepaid>>` | schema model — add `ToSchema` |
| **margin** | `liquidation` | `Json<Vec<Liquidation>>` | schema model — add `ToSchema` (has `BigDecimal` fields — see pitfall) |
| **margin** | `asset_supplied` | `Json<Vec<AssetSupplied>>` | schema model — add `ToSchema` |
| **margin** | `asset_withdrawn` | `Json<Vec<AssetWithdrawn>>` | schema model — add `ToSchema` |
| **margin** | `margin_pool_created` | `Json<Vec<MarginPoolCreated>>` | schema model — add `ToSchema` (has `serde_json::Value` field) |
| **margin** | `deepbook_pool_updated` | `Json<Vec<DeepbookPoolUpdated>>` | schema model — add `ToSchema` |
| **margin** | `interest_params_updated` | `Json<Vec<InterestParamsUpdated>>` | schema model — add `ToSchema` (has `serde_json::Value` field) |
| **margin** | `margin_pool_config_updated` | `Json<Vec<MarginPoolConfigUpdated>>` | schema model — add `ToSchema` (has `serde_json::Value` field) |
| **margin** | `maintainer_cap_updated` | `Json<Vec<MaintainerCapUpdated>>` | schema model — add `ToSchema` |
| **margin** | `maintainer_fees_withdrawn` | `Json<Vec<MaintainerFeesWithdrawn>>` | schema model — add `ToSchema` |
| **margin** | `protocol_fees_withdrawn` | `Json<Vec<ProtocolFeesWithdrawn>>` | schema model — add `ToSchema` |
| **margin** | `supplier_cap_minted` | `Json<Vec<SupplierCapMinted>>` | schema model — add `ToSchema` |
| **margin** | `supply_referral_minted` | `Json<Vec<SupplyReferralMinted>>` | schema model — add `ToSchema` |
| **margin** | `pause_cap_updated` | `Json<Vec<PauseCapUpdated>>` | schema model — add `ToSchema` |
| **margin** | `protocol_fees_increased` | `Json<Vec<ProtocolFeesIncreasedEvent>>` | schema model — add `ToSchema` |
| **margin** | `referral_fees_claimed` | `Json<Vec<ReferralFeesClaimedEvent>>` | schema model — add `ToSchema` |
| **margin** | `referral_fee_events` | `Json<Vec<ReferralFeeEvent>>` | schema model — add `ToSchema` |
| **margin** | `deepbook_pool_registered` | `Json<Vec<DeepbookPoolRegistered>>` | schema model — add `ToSchema` |
| **margin** | `deepbook_pool_updated_registry` | `Json<Vec<DeepbookPoolUpdatedRegistry>>` | schema model — add `ToSchema` |
| **margin** | `deepbook_pool_config_updated` | `Json<Vec<DeepbookPoolConfigUpdated>>` | schema model — add `ToSchema` |
| **margin** | `collateral_events` | `Json<Vec<CollateralEvent>>` | schema model — add `ToSchema` (has `BigDecimal` fields) |
| **margin** | `margin_managers_info` | `Json<Vec<HashMap<String, Value>>>` (inferred) | dynamic JSON → `MarginManagerInfo` |
| **margin** | `margin_manager_states` | `Json<Vec<MarginManagerState>>` | schema model — add `ToSchema` (has `BigDecimal`, `NaiveDateTime` fields) |

**Summary:**
- Schema model types needing `ToSchema` (in `deepbook-schema`): ~20 types
- Server-local types needing `ToSchema` (in `deepbook-server`): 5 types (`PortfolioQueryResult`, `PortfolioMarginPosition`, `PortfolioCollateralBalance`, `PortfolioLpPosition`, `PortfolioSummary`, `BalanceManagerDepositedAssets`, `PoolFees`)
- New typed response structs needed (replacing dynamic JSON): ~10 types (`StatusResponse`, `TickerEntry`, `SummaryEntry`, `TradeRecord`, `OrderUpdateRecord`, `OrderRecord`, `OhclvResponse`, `OrderbookResponse`, `AssetEntry`, `PointsEntry`, `MarginManagerInfo`)

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| OpenAPI spec generation | Manual JSON/YAML spec files | `utoipa` derive macros | Spec would drift from code immediately; zero-runtime overhead of derive macros |
| Swagger UI HTML/CSS/JS | Custom UI implementation | `utoipa-swagger-ui` | Pre-built, versioned, embedded in binary |
| JSON schema from Rust types | Custom reflection code | `#[derive(ToSchema)]` | utoipa handles all primitive mappings, Option, Vec, nested types |
| OpenAPI validation | Custom validator | `openapi-specification` crate or external validator | Not needed in-binary; use external validator in CI if required |

---

## Common Pitfalls

### Pitfall 1: `BigDecimal` Does Not Implement `ToSchema`

**What goes wrong:** `#[derive(ToSchema)]` fails to compile for structs containing
`bigdecimal::BigDecimal` fields (e.g., `Liquidation`, `CollateralEvent`, `MarginManagerState`).
**Why it happens:** `bigdecimal` crate does not implement `utoipa::ToSchema`. utoipa knows
about `String`, `i64`, `f64`, `bool`, etc., but not third-party numeric types.
**How to avoid:** Use `#[schema(value_type = String)]` attribute on the field to tell utoipa
to represent it as a string in the schema (matches the existing `serialize_bigdecimal_option`
custom serializer that converts to string anyway):
```rust
#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
pub struct Liquidation {
    // ...
    #[cfg_attr(feature = "openapi", schema(value_type = String))]
    pub remaining_base_asset: BigDecimal,
}
```
**Warning signs:** `error[E0277]: the trait bound bigdecimal::BigDecimal: utoipa::ToSchema is not satisfied`

### Pitfall 2: `serde_json::Value` Fields Require `schema(value_type = Object)`

**What goes wrong:** Structs with `pub config_json: serde_json::Value` fail `ToSchema` derivation.
**Why it happens:** `serde_json::Value` is not directly `ToSchema`.
**How to avoid:** Use `#[schema(value_type = Object)]` on those fields:
```rust
#[cfg_attr(feature = "openapi", schema(value_type = Object))]
pub config_json: serde_json::Value,
```
**Warning signs:** `error[E0277]: the trait bound serde_json::Value: utoipa::ToSchema is not satisfied`

### Pitfall 3: `chrono::NaiveDateTime` Not in `ToSchema`

**What goes wrong:** `MarginManagerState` has `pub created_at: chrono::NaiveDateTime` — fails
`ToSchema` unless annotated.
**Why it happens:** `chrono` types are not `ToSchema` by default unless utoipa's `chrono`
feature is enabled.
**How to avoid:** Enable `utoipa = { version = "5", features = ["chrono"] }` in the schema
crate. With this feature, `chrono::NaiveDateTime` becomes `String` in the schema (ISO 8601).
[ASSUMED — verify utoipa 5 has `chrono` feature; based on training knowledge that utoipa
supports common type features]
**Warning signs:** `error[E0277]: the trait bound chrono::NaiveDateTime: utoipa::ToSchema is not satisfied`

### Pitfall 4: Handler Functions Must Be `pub` for `#[derive(OpenApi)]` Path References

**What goes wrong:** `#[derive(OpenApi)] #[openapi(paths(routes::health::health_check))]`
fails because `health_check` is `async fn health_check` (private).
**Why it happens:** utoipa's `paths()` list refers to the function symbol; private functions
are not accessible from the module where `ApiDoc` is defined.
**How to avoid:** Make handler functions `pub` in each route module:
```rust
// routes/health.rs
pub async fn health_check() -> StatusCode { ... }
```
After Phase 2, all handlers are in sub-modules; making them `pub` is already required for
`make_router` to reference them.
**Warning signs:** `error[E0603]: function 'health_check' is private`

### Pitfall 5: Path Constants (`pub const`) vs Literal Strings in `#[utoipa::path]`

**What goes wrong:** `#[utoipa::path(get, path = STATUS_PATH)]` does not work — utoipa
`path` attribute requires a string literal, not a const reference.
**Why it happens:** Proc macros evaluate at compile time but cannot resolve runtime `const`
value expressions in attribute parameters.
**How to avoid:** Duplicate the path as a string literal in `#[utoipa::path(path = "/status")]`.
The `pub const STATUS_PATH` remains useful for the router `.route()` calls; the utoipa
annotation uses the literal directly.
**Warning signs:** `error: expected string literal` in the `#[utoipa::path]` macro expansion.

### Pitfall 6: `HashMap<String, String>` Query Parameters Need Inline `params()`

**What goes wrong:** utoipa cannot infer query parameter names from `Query<HashMap<String, String>>` — it produces no query parameter documentation at all.
**Why it happens:** `HashMap` has no named fields for utoipa to introspect.
**How to avoid:** Always provide explicit `params((...))` declarations in `#[utoipa::path]` for
handlers using `HashMap` query params. After Phase 2 DX-03 replaces them with typed structs,
switch to `#[derive(IntoParams)]` on those structs.
**Warning signs:** Swagger UI shows the endpoint with no query parameters listed.

### Pitfall 7: `SwaggerUi` Merge Must Happen After `.with_state()`

**What goes wrong:** `SwaggerUi::new("/swagger-ui").url(...)` returns a `Router<()>` (no
state). If merged before `.with_state(state)`, type inference errors occur.
**Why it happens:** `SwaggerUi` is stateless; merging it with a `Router<Arc<AppState>>`
before `.with_state()` creates a type mismatch because `Router<Arc<AppState>>` and
`Router<()>` are different types.
**How to avoid:** Merge `SwaggerUi` AFTER calling `.with_state(state)` on the main router:
```rust
db_routes
    .merge(rpc_routes)
    .nest("/admin", admin)
    .with_state(state.clone())       // resolves state type to Router<()>
    .merge(SwaggerUi::new("/swagger-ui")
        .url("/api-docs/openapi.json", ApiDoc::openapi()))
    .layer(cors)
    .layer(from_fn_with_state(state, track_metrics))
```
**Warning signs:** `error[E0308]: mismatched types` on `.merge(SwaggerUi::new(...))`.

---

## Task Breakdown Recommendation

Given 48 endpoints across 6 domain modules and the need for ~30 `ToSchema` annotations plus
~10 new typed response structs, the work is best split into **3 sequential plans**:

**Plan 03-01: Infrastructure** (Wave 1 — prerequisite for all other plans)
- Add utoipa, utoipa-swagger-ui to Cargo.toml
- Add optional utoipa feature to deepbook-schema Cargo.toml
- Define `ApiDoc` struct (empty `paths()` list initially)
- Mount `SwaggerUi` in `make_router`
- Verify `GET /swagger-ui/` returns HTML and `GET /api-docs/openapi.json` returns valid JSON
- `cargo build -p deepbook-server` passes

**Plan 03-02: Schema Types** (Wave 2 — can run after 03-01)
- Add `#[derive(ToSchema)]` (feature-gated) to all 20+ model types in `deepbook-schema`
- Handle `BigDecimal`, `serde_json::Value`, `chrono::NaiveDateTime` field overrides
- Add `ToSchema` to server-local types: `PortfolioQueryResult` and its nested types, `BalanceManagerDepositedAssets`, `PoolFees`
- Add new `api_types.rs` with ~10 typed response structs replacing dynamic JSON
- `cargo build -p deepbook-server` passes

**Plan 03-03: Handler Annotations** (Wave 3 — can run after 03-02)
- Annotate all 48 handlers with `#[utoipa::path(...)]` including:
  - Correct HTTP method, path string literal, tag (matches module name)
  - All path and query params documented via inline `params()` 
  - Response `body` referencing the typed schema structs
- Make handler functions `pub` in route modules
- Add all schemas to `ApiDoc::openapi(paths(...), components(schemas(...)))`
- Verify Swagger UI displays all 48 endpoints with parameters and schemas
- Validate `/api-docs/openapi.json` against OpenAPI 3.0 schema

**Why not parallelizable:** Each plan depends on the prior one. 03-01 must run first
(no schema types means no compile). 03-02 provides types needed by 03-03 annotations.

**Note on Roadmap:** The ROADMAP.md marks Phase 3 as `"Parallelizable plans: no"` —
this is consistent with the sequential Wave structure above.

---

## Code Examples

### Wire-up: make_router with SwaggerUi

```rust
// Source: [CITED: docs.rs/utoipa-swagger-ui/latest — Axum integration]
use utoipa::OpenApi;
use utoipa_swagger_ui::SwaggerUi;

pub(crate) fn make_router(state: Arc<AppState>) -> Router {
    let cors = /* ... existing ... */;
    let db_routes = /* ... existing ... */;
    let rpc_routes = /* ... existing ... */;
    let admin = /* ... existing ... */;

    db_routes
        .merge(rpc_routes)
        .nest("/admin", admin)
        .with_state(state.clone())
        .merge(SwaggerUi::new("/swagger-ui")
            .url("/api-docs/openapi.json", ApiDoc::openapi()))
        .layer(cors)
        .layer(from_fn_with_state(state, track_metrics))
}
```

### Minimal ApiDoc skeleton

```rust
// Source: [CITED: docs.rs/utoipa/latest/utoipa/derive.OpenApi.html]
use utoipa::OpenApi;

#[derive(OpenApi)]
#[openapi(
    info(title = "DeepBook v3 API", version = "1.0.0",
         description = "DeepBook v3 indexer REST API"),
    paths(
        crate::routes::health::health_check,
        crate::routes::health::status,
        // ... all pub handlers
    ),
    components(schemas(
        deepbook_schema::models::Pools,
        deepbook_schema::models::OrderStatus,
        // ... all ToSchema types
    )),
    tags(
        (name = "health", description = "Server health and indexer status"),
        (name = "pools", description = "Pool data and trading volume"),
        (name = "orders", description = "Trades, order fills, and OHCLV"),
        (name = "portfolio", description = "Wallet portfolio and deposits"),
        (name = "margin", description = "Margin trading event history"),
        (name = "points", description = "Trading points"),
    )
)]
pub struct ApiDoc;
```

### ToSchema with field overrides for BigDecimal and serde_json::Value

```rust
// Source: [CITED: docs.rs/utoipa/latest/utoipa/derive.ToSchema.html#field-attributes]
// crates/schema/src/models.rs (inside #[cfg_attr(feature = "openapi", ...)] gate)

#[cfg_attr(feature = "openapi", derive(utoipa::ToSchema))]
#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = liquidation, primary_key(event_digest))]
pub struct Liquidation {
    pub event_digest: String,
    // ... other String/i64/bool fields ...
    #[cfg_attr(feature = "openapi", schema(value_type = String))]
    pub remaining_base_asset: BigDecimal,
    #[cfg_attr(feature = "openapi", schema(value_type = String))]
    pub remaining_quote_asset: BigDecimal,
    // ...
}

// For serde_json::Value fields (e.g., MarginPoolCreated):
#[cfg_attr(feature = "openapi", schema(value_type = Object))]
pub config_json: serde_json::Value,
```

### Handler annotation for path + query params

```rust
// Source: [CITED: docs.rs/utoipa/latest/utoipa/attr.path.html]
#[utoipa::path(
    get,
    path = "/orders/{pool_name}/{balance_manager_id}",
    tag = "orders",
    params(
        ("pool_name" = String, Path, description = "Pool name, e.g. DEEP_SUI"),
        ("balance_manager_id" = String, Path, description = "Balance manager ID"),
        ("limit" = Option<i64>, Query, description = "Max results (default: 1000)"),
        ("start_time" = Option<i64>, Query, description = "Start time in seconds since epoch"),
        ("end_time" = Option<i64>, Query, description = "End time in seconds since epoch"),
        ("status" = Option<String>, Query, description = "Filter by status: placed,canceled,filled,partially_filled,expired"),
    ),
    responses(
        (status = 200, description = "Order records", body = [OrderRecord]),
        (status = 404, description = "Pool not found")
    )
)]
pub async fn orders(
    Path((pool_name, balance_manager_id)): Path<(String, String)>,
    Query(params): Query<HashMap<String, String>>,
    State(state): State<Arc<AppState>>,
) -> Result<Json<Vec<HashMap<String, Value>>>, DeepBookError> { ... }
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| utoipa 3.x with separate `utoipa-swagger-ui 3.x` | utoipa 5.x + utoipa-swagger-ui 9.x | utoipa 4→5 (2024) | `paths!` macro removed; use `paths(fn, fn, ...)` in `#[openapi]` attribute directly |
| `utoipa-swagger-ui` axum feature required separate `axum` dep | axum feature bundles all needed deps | utoipa-swagger-ui 5+ | Simpler Cargo.toml |
| `OpenApi::openapi()` called per route | Single `ApiDoc::openapi()` at server startup | utoipa 4+ | No per-request overhead |
| Manual schema registration with `schema!` macro | `#[derive(ToSchema)]` + `components(schemas(...))` | utoipa 4+ | Compile-time checked |

**Deprecated/outdated:**
- `utoipa-swagger-ui < 5.0`: only supported Axum 0.6 or earlier — use 9.x
- `paths!()` macro from utoipa 3: removed in utoipa 4; use `paths(fn, fn, ...)` attribute syntax
- `utoipa::path` `operation_id` auto-generation: still works but verify uniqueness across all 48 endpoints

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Rust / cargo | All changes | confirmed (project builds) | edition 2021 | — |
| utoipa | OpenAPI generation | Not in Cargo.toml | — | Add to Cargo.toml (no blocker) |
| utoipa-swagger-ui | Swagger UI serving | Not in Cargo.toml | — | Add to Cargo.toml (no blocker) |
| utoipa-axum | Optional ergonomics | Not in Cargo.toml | — | Optional — planner may skip |

**Missing dependencies with no fallback:** None — all are additive Cargo.toml additions.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Rust built-in `#[test]` + `cargo test` |
| Config file | none (standard cargo test discovery) |
| Quick run command | `cargo build -p deepbook-server` |
| Full suite command | `cargo build -p deepbook-server && cargo test -p deepbook-server` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| DX-01 | `/swagger-ui/` returns HTML with status 200 | smoke (integration) | `curl -s -o /dev/null -w "%{http_code}" http://localhost:8080/swagger-ui/` | ❌ Wave 0 (manual) |
| DX-01 | `/api-docs/openapi.json` returns valid JSON | smoke (integration) | `curl -s http://localhost:8080/api-docs/openapi.json \| python3 -m json.tool` | ❌ Wave 0 (manual) |
| DX-01 | `ApiDoc::openapi().to_json()` compiles without error | unit (compile) | `cargo build -p deepbook-server` | ❌ Wave 0 |
| DX-01 | OpenAPI JSON validates against OpenAPI 3.0 schema | lint/external | `npx @stoplight/spectral-cli lint /api-docs/openapi.json` (or similar) | ❌ Wave 0 (manual) |
| DX-01 | All 48 endpoint paths appear in spec | unit | `cargo test -p deepbook-server -- openapi_paths` | ❌ Wave 0 |

### Sampling Rate

- **Per task commit:** `cargo build -p deepbook-server` (compile check confirms no ToSchema/path errors)
- **Per wave merge:** `cargo build -p deepbook-server && cargo test -p deepbook-server`
- **Phase gate:** Manual verification of Swagger UI + JSON validation before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] No existing Swagger UI test; manual curl verification suffices for this phase
- [ ] Optional: add `tests/openapi_spec.rs` with a test that calls `ApiDoc::openapi()` and asserts specific paths are present: `cargo test -p deepbook-server openapi_paths`
- [ ] `utoipa`, `utoipa-swagger-ui` not yet in Cargo.toml — must be added in Wave 1

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | utoipa 5 has a `chrono` feature that makes `NaiveDateTime` implement `ToSchema` as a string | Pitfall 3, Standard Stack | If wrong, use `#[schema(value_type = String)]` on `NaiveDateTime` fields — same fix as BigDecimal |
| A2 | `SwaggerUi` must be merged after `.with_state()` to avoid type mismatch | Pitfall 7, Code Examples | If wrong (ordering irrelevant), the code still works; at worst a minor reorder |
| A3 | utoipa-axum 0.2 is optional — the `paths(fn, fn, ...)` style in `#[derive(OpenApi)]` is sufficient for all 48 handlers without utoipa-axum | Standard Stack | If utoipa-axum is required for some feature, add it; it's a non-breaking additive dep |
| A4 | `margin_managers_info` and `margin_manager_states` return types are typed structs (MarginManagerState from schema), not dynamic JSON | Endpoint Inventory | If margin_managers_info returns `HashMap<String, Value>`, add it to the dynamic JSON list needing a typed response struct |

**Low-risk assumptions** (A2, A3): These affect code style, not correctness.
**Medium-risk assumptions** (A1, A4): If wrong, the fix is mechanical (add `#[schema(value_type = ...)]` or define one additional typed struct).

---

## Open Questions

1. **Should typed response structs (TradeRecord, OrderRecord, etc.) be defined in `api_types.rs` or inline in each route module?**
   - What we know: CLAUDE.md says "simplicity first" and "no abstractions for single-use code."
   - What's unclear: Whether a shared `api_types.rs` is simpler than per-module types.
   - Recommendation: Define each response type in its route module (e.g., `TradeRecord` in `routes/orders.rs`). Only create `api_types.rs` if 3+ route modules share the same type. This avoids unnecessary cross-module coupling.

2. **Does Phase 2 (DX-03) introduce typed param structs that should also implement `IntoParams`?**
   - What we know: Phase 2 is supposed to add `ValidatedWalletAddress` and `PaginationParams`. If those exist at Phase 3 execution time, they should derive `IntoParams` instead of using inline `params()` declarations.
   - Recommendation: Planner should check if Phase 2 is complete before writing Phase 3 plans. If DX-03 typed structs exist, derive `IntoParams` on them; if not, use inline `params()`.

3. **Should the OpenAPI spec include admin endpoints (`/admin/*`)?**
   - What we know: Admin endpoints are behind bearer token auth. The `admin_routes()` function assembles them separately.
   - Recommendation: Exclude admin endpoints from the `ApiDoc` — they are internal tooling, not public API. The DX-01 requirement says "all public REST endpoints." Admin routes are not public.

---

## Security Domain

Phase 3 is purely additive documentation. Security notes:
- The Swagger UI endpoint (`/swagger-ui/`) is public and serves static assets. No credentials
  or sensitive data appear in the spec.
- Admin endpoints should NOT be included in the public spec (see Open Question 3).
- The OpenAPI JSON at `/api-docs/openapi.json` discloses all public endpoint paths and
  parameter names — this is intentional and acceptable for a public indexer API.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | Swagger UI is public; admin endpoints excluded from spec |
| V3 Session Management | no | stateless REST API |
| V4 Access Control | no | no new access control changes |
| V5 Input Validation | no | no new input handling; documentation only |
| V6 Cryptography | no | no crypto changes |

---

## Sources

### Primary (HIGH confidence)
- `crates/server/src/server.rs` — complete route inventory (50 `.route()` calls), all handler signatures and return types [VERIFIED: direct read]
- `crates/schema/src/models.rs` — all schema model types, their derives, BigDecimal/serde_json::Value fields [VERIFIED: direct read]
- `crates/server/src/reader.rs` — `PortfolioQueryResult` and related types, server-local types [VERIFIED: direct read]
- `crates/server/Cargo.toml` — confirms utoipa not yet a dependency [VERIFIED: direct read]
- `crates/schema/Cargo.toml` — confirms utoipa not yet a dependency [VERIFIED: direct read]
- [docs.rs/utoipa/latest](https://docs.rs/utoipa/latest/utoipa/) — version 5.4.0, `#[utoipa::path]` syntax, `ToSchema`, `IntoParams` [CITED]
- [docs.rs/utoipa-swagger-ui/latest](https://docs.rs/utoipa-swagger-ui/latest/utoipa_swagger_ui/) — version 9.0.2, Axum >= 0.7 support, router merge pattern [CITED]
- [docs.rs/utoipa-axum/latest](https://docs.rs/utoipa-axum/latest/utoipa_axum/) — version 0.2.0, optional ergonomics layer [CITED]

### Secondary (MEDIUM confidence)
- [juhaku/utoipa GitHub README](https://github.com/juhaku/utoipa) — usage examples, `paths(fn, fn)` syntax, `#[derive(OpenApi)]` pattern [CITED]
- Phase 2 RESEARCH.md (`02-RESEARCH.md`) — confirmed post-Phase-2 structure: routes/ modules, handler grouping by domain [VERIFIED: direct read]

### Tertiary (LOW confidence)
- utoipa `chrono` feature availability (A1 in assumptions) — based on training knowledge that utoipa supports common Rust type features; not verified via direct docs lookup this session

---

## Metadata

**Confidence breakdown:**
- Standard stack (utoipa versions + Axum compatibility): HIGH — verified from docs.rs
- Endpoint inventory (48 handlers, types): HIGH — read directly from server.rs and models.rs
- `ToSchema` strategy: HIGH — verified utoipa 5 supports `#[schema(value_type = ...)]` field overrides
- Pitfalls (BigDecimal, HashMap, path literals, pub visibility): HIGH — based on direct codebase read + docs
- chrono feature in utoipa: LOW — not verified this session (marked A1 in assumptions)

**Research date:** 2026-04-30
**Valid until:** 2026-05-30 (utoipa 5.x is stable; no breaking changes expected in 30 days)
