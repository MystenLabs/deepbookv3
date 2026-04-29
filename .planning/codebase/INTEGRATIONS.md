---
date: 2026-04-29
focus: tech
---

# Integrations

## Blockchain (Sui Network)

**Sui fullnode / checkpoint stream:**
- The indexer (`crates/indexer`) connects to Sui via `sui-indexer-alt-framework`
- Streams checkpoints in order, processes Move events emitted by DeepBook Move packages
- Supports multiple environments: Mainnet, Testnet (detected via package address maps in `crates/indexer/src/lib.rs`)

**Package versions:**
- The `MoveStruct` trait and `get_module_type()` / `get_core_package_addresses()` / `get_margin_package_addresses()` functions in `crates/indexer/src/traits.rs` and `lib.rs` handle multi-version package matching
- Events are matched across all historically deployed package addresses

## RPC / Oracle

**Sui JSON-RPC** (`sui-sdk` + `sui-json-rpc-types`):
- Used in `crates/server/src/margin_metrics/rpc_client.rs` to poll live on-chain margin state
- The margin metrics poller (`margin_metrics/poller.rs`) runs as a background task in the server

**Pyth / Lazer oracle (on-chain):**
- `packages/deepbook_margin/sources/helper/oracle.move` — price feed integration for margin trading
- `packages/predict/sources/helper/lazer_helper.move` — Lazer oracle for prediction markets
- Oracle data flows on-chain; server does not directly call oracle APIs

## Database (PostgreSQL)

**Direct connection:**
- Both `deepbook-indexer` and `deepbook-server` connect to the same PostgreSQL instance
- Indexer writes; server reads
- Connection pools managed via `sui-pg-db` (`Db::for_read` / `Db::for_write`)
- Materialized views (`net_deposits_hourly`, `ohclv_1m`, `ohclv_1d`) pre-aggregate data

**Watermarks table:**
- Tracks per-pipeline checkpoint progress for the indexer
- Exposed by server via `GET /watermarks` endpoint

## HTTP API (Server → Clients)

**Axum REST API** on configurable port:
- All endpoints are read-only except admin routes
- CORS enabled via `tower-http`
- Rate limiting via `governor` crate (token bucket per IP)
- Prometheus metrics endpoint for scraping

**Admin endpoints** (`crates/server/src/admin/`):
- Protected by constant-time API key check (`subtle` crate)
- Handlers for write operations (exact routes in `admin/routes.rs`)

## Prometheus / Metrics

- `prometheus` crate with a shared `Registry`
- `RpcMetrics` in `crates/server/src/metrics/` tracks: DB latency histogram, `db_requests_succeeded`, `db_requests_failed`
- `sui-indexer-alt-metrics` provides `DbConnectionStatsCollector` registered on startup
- Metrics endpoint exposed by Axum router

## Docker

- `docker/` directory contains deployment configuration
- Likely docker-compose for local dev with PostgreSQL + indexer + server
- Exact contents not read but standard Mysten Labs deployment pattern

## External Services (Scripts)

- TypeScript scripts in `scripts/transactions/` call Sui RPC to submit PTBs (Programmable Transaction Blocks)
- Config in `scripts/config/` — likely points to mainnet/testnet RPC URLs and wallet keys
- No external HTTP APIs called from scripts beyond Sui RPC
