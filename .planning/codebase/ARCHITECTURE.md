---
date: 2026-04-29
focus: arch
---

# Architecture

## Pattern

**Event-sourced, multi-layer system:**

1. **On-chain layer** (Sui Move) — source of truth; emits events on every state change
2. **Indexer layer** (Rust) — stateless event processor; replays checkpoints into PostgreSQL
3. **API layer** (Rust/Axum) — stateless read server; queries PostgreSQL, exposes REST
4. **Script layer** (TypeScript) — operational tooling; submits PTBs to Sui RPC

The system is **append-only at the indexer** (events are never mutated, only accumulated). All write state lives on-chain.

## On-Chain Architecture

```
                    ┌─────────────────────────────────────────────┐
                    │              Sui Blockchain                  │
                    │                                             │
                    │  ┌──────────────┐   ┌───────────────────┐  │
                    │  │   deepbook   │   │  deepbook_margin  │  │
                    │  │  (core DEX)  │◄──│  (margin trading) │  │
                    │  └──────┬───────┘   └─────────┬─────────┘  │
                    │         │                     │             │
                    │  ┌──────▼──────────────────────▼─────────┐  │
                    │  │             token/DEEP                 │  │
                    │  └────────────────────────────────────────┘  │
                    │                                             │
                    │  ┌──────────────┐   ┌───────────────────┐  │
                    │  │   predict    │   │ margin_liquidation │  │
                    │  │  (pred mkt)  │   │   (liquidation)   │  │
                    │  └──────────────┘   └───────────────────┘  │
                    └─────────────────────────────────────────────┘
```

### Core DeepBook (`packages/deepbook`)

**Module hierarchy:**
```
pool.move            ← Public API entry point
├── book/
│   ├── book.move    ← Order book (bid/ask matching)
│   ├── order.move   ← Order struct + lifecycle
│   ├── order_info.move ← Order metadata
│   └── fill.move    ← Fill event logic
├── state/
│   ├── state.move   ← Pool state aggregate
│   ├── account.move ← Per-account position tracking
│   ├── balances.move← Asset balance management
│   ├── governance.move ← DEEP governance voting
│   ├── history.move ← Historical fee/rebate data
│   ├── trade_params.move ← Fee/trading parameters
│   └── ewma.move    ← EWMA volume/volatility tracking
├── vault/
│   ├── vault.move   ← Asset custody + flash loans
│   └── deep_price.move ← DEEP token price oracle
├── helper/
│   ├── big_vector.move ← Paginated on-chain vector
│   ├── math.move    ← Fixed-point arithmetic
│   ├── constants.move ← Protocol constants
│   └── utils.move
├── balance_manager.move ← Cross-pool balance management
├── order_query.move ← Open order queries
└── registry.move   ← Pool registry + admin caps
```

**Key on-chain data flows:**
- User → `pool::place_limit_order()` → `Book::insert()` → match → `Vault::settle_trade()` → emit `OrderFilled`
- User → `BalanceManager::deposit()` → emit `BalanceEvent`
- Governance → `State::propose_trade_params()` → votes → `State::set_trade_params()`

**Versioned pools:** `Pool<Base, Quote>` wraps `Versioned` (dynamic field) → `PoolInner`. Version checks prevent interaction with deprecated versions.

## Off-Chain Architecture

```
Sui Network
    │ checkpoint stream
    ▼
┌─────────────────────────────────┐
│         deepbook-indexer        │
│                                 │
│  sui-indexer-alt-framework      │
│  ┌──────────────────────────┐   │
│  │  HandlerX (per event)    │   │  54+ handlers
│  │  HandlerY                │   │  one per Move event type
│  │  ...                     │   │
│  └──────────┬───────────────┘   │
│             │ diesel-async       │
└─────────────┼───────────────────┘
              │ INSERT
              ▼
┌─────────────────────────────────┐
│           PostgreSQL            │
│                                 │
│  event tables (50+)             │
│  materialized views             │
│    - net_deposits_hourly        │
│    - ohclv_1m / ohclv_1d        │
│  stored functions               │
│    - get_ohclv()                │
└──────────────┬──────────────────┘
               │ SELECT (diesel-async)
               ▼
┌─────────────────────────────────┐
│         deepbook-server         │
│                                 │
│  axum Router                    │
│  ├── Reader (query layer)       │
│  ├── Writer (admin ops)         │
│  ├── admin/ (auth'd routes)     │
│  └── margin_metrics/            │
│       ├── poller (background)   │
│       └── rpc_client (Sui RPC)  │
└─────────────────────────────────┘
         │ HTTP REST
         ▼ clients
```

## Indexer Architecture (`crates/indexer`)

- Uses `sui-indexer-alt-framework` pipeline abstraction
- Each handler implements `MoveStruct` trait (matches event by package+module+name)
- Handlers run concurrently per checkpoint; each writes to its own table via `diesel-async`
- `traits.rs` — `MoveStruct` trait: `MODULE`, `NAME` constants; `matches_event_type()` for multi-version matching
- `lib.rs` — environment config: package addresses per Mainnet/Testnet, `ModuleType` routing (Core/Margin/Sui/Unknown)
- `models.rs` — Rust structs matching DB row types
- `sandbox.rs` — local testing/replay utility

## Server Architecture (`crates/server`)

- `main.rs` — parse config, build Axum router, start background tasks
- `server.rs` — route registration (too large to read fully; ~1600 lines implied)
- `reader.rs` — all SELECT queries via `Reader` struct; connection pool via `sui-pg-db`
- `writer.rs` — write operations (admin)
- `error.rs` — `DeepBookError` enum with HTTP status mapping
- `admin/` — `auth.rs` (constant-time key check), `handlers.rs`, `routes.rs`
- `metrics/` — `RpcMetrics`, Prometheus middleware
- `margin_metrics/` — background poller reads live on-chain state via Sui RPC; `metrics.rs`, `poller.rs`, `rpc_client.rs`

## Data Flow: Query Lifecycle

```
Client HTTP → Axum middleware (CORS, rate-limit, metrics)
           → Route handler (server.rs)
           → Reader method (reader.rs)
           → diesel-async query
           → PostgreSQL
           → JSON response via serde_json
```

## Abstractions

| Abstraction | Location | Purpose |
|------------|---------|---------|
| `MoveStruct` trait | `indexer/src/traits.rs` | Typed event matching across pkg versions |
| `Reader` struct | `server/src/reader.rs` | All DB reads, metric tracking |
| `Db` / `DbArgs` | `sui-pg-db` (external) | Connection pool management |
| `DeepBookError` | `server/src/error.rs` | Unified error → HTTP status |
| `BigVector<T>` | Move `helper/big_vector.move` | Paginated on-chain dynamic storage |
| `Versioned` pool inner | Move `pool.move` | Upgrade-safe pool storage |
