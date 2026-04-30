---
date: 2026-04-30
---

# Research Summary — DeepBook v3 Improvements

## Key Findings

**Stack:** Existing Rust/Axum/Diesel/PostgreSQL stack is sound. Additive improvements only: `utoipa` for OpenAPI, `moka` for caching, `tokio::time::interval` for background refresh. No framework replacements needed.

**Official SDK:** `@mysten/deepbook-v3` (npm) covers core DeepBook operations (orders, balance manager, swaps, referrals, staking). Does NOT cover margin trading or prediction markets. No official TypeScript HTTP client for the indexer REST API exists — this is a clear gap for ecosystem builders.

**Indexer API:** 30+ documented REST endpoints at `deepbook-indexer.mainnet.mystenlabs.com`. No OpenAPI spec published. Timestamps: params in Unix seconds, responses in milliseconds.

**Table Stakes:**
1. DB indexes (`asset_supplied.sender`, `asset_withdrawn.sender`) — currently missing, causes sequential scans
2. Asset ID normalization — leading-wildcard LIKE prevents index use on `balances.asset`
3. Materialized view refresh out of request path — currently blocks `get_net_deposits`
4. Named struct for `get_orders` 17-tuple — baseline API quality

**Watch Out For:**
1. `CREATE INDEX CONCURRENTLY` cannot run inside Diesel transaction-wrapped migrations — must run separately
2. `REFRESH MATERIALIZED VIEW CONCURRENTLY` requires a unique index on the view — verify before moving to background
3. `f64` → `Decimal` migration: use existing `bigdecimal` dep, not a new `rust_decimal` dep
4. Axum state extraction pattern must be unified (migrate to `State<AppState>`) before splitting `server.rs`

## Recommended Phase Order

1. **DB Performance** — indexes + MV refresh (highest impact, lowest risk, no API changes)
2. **Server Ergonomics** — named structs, `server.rs` split, asset normalization
3. **OpenAPI Docs** — `utoipa` integration, spec generation
4. **TypeScript Indexer Client** — generated from OpenAPI spec
5. **Indexer DX** — handler macro, integration tests, Move test coverage

## Files

- `STACK.md` — Technology choices, library recommendations with versions
- `FEATURES.md` — Table stakes vs differentiators vs anti-features
- `ARCHITECTURE.md` — Refactoring patterns, build order, DB partitioning
- `PITFALLS.md` — 11 specific pitfalls with phase mapping and warning signs
