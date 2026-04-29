---
date: 2026-04-29
focus: arch
---

# Structure

## Top-Level Directory Layout

```
deepbookv3/
├── packages/              # Sui Move smart contracts
│   ├── deepbook/          # Core DEX orderbook package
│   ├── deepbook_margin/   # Margin trading extension
│   ├── predict/           # Prediction markets
│   ├── token/             # DEEP governance token
│   ├── dbtc/              # Wrapped BTC
│   ├── dusdc/             # Wrapped USDC
│   └── margin_liquidation/ # Liquidation logic
├── crates/                # Rust off-chain services
│   ├── bench/             # Benchmarking
│   ├── indexer/           # Checkpoint event processor
│   ├── schema/            # Diesel schema + shared models
│   └── server/            # Axum REST API
├── scripts/               # TypeScript transaction scripts
│   ├── config/            # Environment configuration
│   ├── transactions/      # PTB scripts (~40+ files)
│   ├── tx/                # Lower-level tx builders
│   └── utils/             # Shared utilities
├── docker/                # Deployment configuration
├── docs/                  # Documentation
├── Cargo.toml             # Rust workspace root
├── Cargo.lock             # Pinned Rust deps
├── package.json           # Node.js workspace root
├── pnpm-lock.yaml         # Pinned Node deps
├── CLAUDE.md              # AI assistant instructions
└── AGENTS.md              # Agent behavior rules
```

## Move Package Layout (uniform per package)

```
packages/deepbook/
├── Move.toml              # Package manifest (name, edition, deps)
├── sources/               # Production Move code
│   ├── pool.move          # Public API entry point
│   ├── book/              # Order book modules
│   ├── state/             # State management modules
│   ├── vault/             # Asset custody modules
│   └── helper/            # Shared utilities (math, constants)
└── tests/                 # Move unit tests (mirror of sources/)
    ├── balance_manager_tests.move
    ├── pool_tests.move
    ├── master_tests.move  # Integration-style tests
    └── ...
```

```
packages/deepbook_margin/
├── Move.toml
├── sources/
│   ├── margin_manager.move
│   ├── margin_pool/
│   ├── helper/            # oracle.move, margin_constants.move
│   └── ...
└── tests/
```

## Rust Crate Layout

```
crates/indexer/src/
├── main.rs                # Binary entry point (CLI setup, pipeline start)
├── lib.rs                 # Environment config, package addresses, ModuleType
├── traits.rs              # MoveStruct trait + event matching
├── models.rs              # Shared Rust structs for event data
├── sandbox.rs             # Local replay/testing utility
└── handlers/              # One file per Move event type (54+ files)
    ├── mod.rs             # Re-exports all handlers
    ├── order_fill_handler.rs
    ├── order_update_handler.rs
    ├── pool_created_handler.rs
    └── ...                # Asset, margin, referral, governance handlers
```

```
crates/server/src/
├── main.rs                # Binary entry point
├── lib.rs                 # (likely re-exports)
├── server.rs              # Axum router + all route handlers (~1600+ lines)
├── reader.rs              # All PostgreSQL SELECT queries
├── writer.rs              # Admin write operations
├── error.rs               # DeepBookError → HTTP status
├── admin/
│   ├── mod.rs
│   ├── auth.rs            # Constant-time API key auth
│   ├── handlers.rs        # Admin endpoint handlers
│   └── routes.rs          # Admin route registration
├── metrics/
│   ├── mod.rs             # RpcMetrics struct + Prometheus registration
│   └── middleware.rs      # Axum middleware for request metrics
└── margin_metrics/
    ├── mod.rs
    ├── metrics.rs         # Margin-specific metrics
    ├── poller.rs          # Background task: poll on-chain state
    └── rpc_client.rs      # Sui RPC calls for live margin data
```

```
crates/schema/src/
├── lib.rs                 # Diesel schema include + re-exports
├── models.rs              # ~100 Diesel model structs (one per table)
└── schema.rs              # Auto-generated Diesel schema (50+ tables)
```

```
crates/bench/src/
├── main.rs                # Benchmark entry point
├── api.rs                 # API benchmark utilities
├── config.rs              # Bench configuration
├── metrics.rs             # Measurement collection
├── queue.rs               # Request queue
├── runner.rs              # Benchmark execution
└── store.rs               # Result storage
```

## Script Layout

```
scripts/
├── config/                # Network configs (mainnet, testnet addresses)
├── transactions/          # Individual PTB scripts
│   ├── createPool.ts      # Pool creation
│   ├── enableVersion.ts   # Package version management
│   ├── addStablecoin.ts   # Stablecoin registration
│   ├── deepbookMarketMaker.ts
│   └── ...
├── tx/                    # Reusable transaction block builders
└── utils/                 # Helpers (key parsing, env loading, etc.)
```

## Key File Locations

| What you're looking for | File |
|------------------------|------|
| On-chain pool logic | `packages/deepbook/sources/pool.move` |
| Order book matching | `packages/deepbook/sources/book/book.move` |
| Order data structure | `packages/deepbook/sources/book/order.move` |
| Balance manager (cross-pool) | `packages/deepbook/sources/balance_manager.move` |
| Margin pool logic | `packages/deepbook_margin/sources/margin_pool/` |
| Oracle integration | `packages/deepbook_margin/sources/helper/oracle.move` |
| Indexer event handler example | `crates/indexer/src/handlers/order_fill_handler.rs` |
| Multi-version event matching | `crates/indexer/src/traits.rs` |
| Environment / package addresses | `crates/indexer/src/lib.rs` |
| All DB query methods | `crates/server/src/reader.rs` |
| REST route definitions | `crates/server/src/server.rs` |
| DB table definitions | `crates/schema/src/schema.rs` |
| DB model structs | `crates/schema/src/models.rs` |
| Prometheus metrics | `crates/server/src/metrics/mod.rs` |
| Admin auth | `crates/server/src/admin/auth.rs` |

## Naming Conventions

**Move:** `snake_case` modules, `PascalCase` structs, `UPPER_SNAKE_CASE` constants, `E` prefix for error codes (e.g., `EInvalidFee`)

**Rust:** Standard Rust conventions; handler files named `{event_name}_handler.rs`; model structs match DB table name in PascalCase

**TypeScript:** `camelCase` variables, PascalCase types, script files are `camelCase` action descriptions (`createPool.ts`, `enableVersion.ts`)
