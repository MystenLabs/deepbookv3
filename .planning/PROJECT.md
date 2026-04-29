---
name: DeepBook v3 — Performance, Scalability & DX Improvements
code: DBV3
---

# DeepBook v3 — Performance, Scalability & DX Improvements

## What This Is

A comprehensive improvement initiative across the entire DeepBook v3 stack targeting three dimensions:

1. **Performance** — eliminate known bottlenecks in the REST API and database layer (sequential scans, missing indexes, synchronous view refreshes)
2. **Scalability** — improve the indexer's ability to handle growing event volume; refactor monolithic files before they become a ceiling
3. **Developer Experience** — make the codebase easier to extend (typed SDK, API docs, reduced boilerplate, improved test coverage)

DeepBook v3 is a decentralized order book on Sui blockchain. The stack spans: Sui Move smart contracts (core DEX + margin trading + prediction markets), a Rust event-driven indexer (54+ handlers → PostgreSQL), a Rust Axum REST API server, and TypeScript operational scripts.

## Core Value

A fast, well-documented, developer-friendly infrastructure that scales with DeepBook's growth — enabling external integrators to build on it confidently and the internal team to ship safely.

## Context

- **Repository:** MystenLabs/deepbookv3 (cloned fresh)
- **Codebase state:** Production code in active use on Sui mainnet/testnet
- **Known issues:** Documented in `.planning/codebase/CONCERNS.md` — sequential scans, missing DB indexes, materialized view refreshed per-request, 17-tuple return type, missing test coverage, no API docs
- **Stack:** Sui Move, Rust (Tokio + Axum + Diesel + PostgreSQL), TypeScript

## Requirements

### Validated

- ✓ Core orderbook (pool, book, orders, balance manager, vault, governance) — existing
- ✓ Margin trading extension (margin pools, oracle, liquidation) — existing
- ✓ Prediction markets (predict package) — existing
- ✓ Event-driven indexer (54+ handlers, checkpoint streaming) — existing
- ✓ REST API server (Axum, PostgreSQL reads) — existing
- ✓ Prometheus metrics (DB latency, request counts) — existing
- ✓ Rate limiting (governor crate) — existing
- ✓ Admin API (constant-time auth) — existing
- ✓ Move unit tests for core deepbook package — existing

### Active

**Performance:**
- [ ] **PERF-01**: Missing indexes added for `asset_supplied.sender` and `asset_withdrawn.sender` to prevent sequential scans on LP queries
- [ ] **PERF-02**: Leading-wildcard LIKE pattern on `balances.asset` replaced with normalized asset column + functional index
- [ ] **PERF-03**: Materialized view refresh moved out of request path to background job
- [ ] **PERF-04**: `get_portfolio` connection acquisition reduced (single connection for 3 sub-queries)
- [ ] **PERF-05**: OHLCV query performance audited and indexed appropriately

**Scalability:**
- [ ] **SCALE-01**: `server.rs` monolith split into feature-based route modules
- [ ] **SCALE-02**: Indexer handler boilerplate reduced via macro or code-gen
- [ ] **SCALE-03**: `get_orders` 17-tuple replaced with named struct
- [ ] **SCALE-04**: Asset ID `0x` prefix normalization centralized (single utility)
- [ ] **SCALE-05**: `f64` financial values audited; critical paths migrated to `Decimal`/`i64` where needed

**Developer Experience:**
- [ ] **DX-01**: TypeScript DeepBook client SDK generated or hand-crafted covering core pool operations
- [ ] **DX-02**: OpenAPI schema generated for REST API (via `utoipa` or `aide`)
- [ ] **DX-03**: Integration test suite for Rust server API endpoints
- [ ] **DX-04**: Margin + predict Move packages get basic test coverage
- [ ] **DX-05**: TypeScript scripts test harness added (vitest or similar)
- [ ] **DX-06**: CLAUDE.md / AGENTS.md updated with current project context and workflow patterns

### Out of Scope

- New financial features (new pool types, new margin parameters) — pure DX/perf initiative
- On-chain Move contract logic changes — too risky without full audit context
- `margin_pool_snapshots` population (blocked on data pipeline work, tracked separately)
- Deployment/infrastructure changes (Kubernetes, load balancing) — ops team scope

## Key Decisions

| Decision | Rationale | Outcome |
|----------|-----------|---------|
| Keep Move contracts unchanged | Financial contract changes require full security audit; perf/DX gains are on off-chain layer | Move packages are read-only in this initiative |
| Use `utoipa` for OpenAPI | Zero-runtime overhead, derive-macro based, well-maintained for Axum | — Pending |
| Normalize asset IDs at ingestion | Fix at indexer write time rather than query time | — Pending |
| Background refresh via tokio::interval | Already have tokio runtime; avoids external scheduler dependency | — Pending |

## Evolution

This document evolves at phase transitions and milestone boundaries.

**After each phase transition** (via `/gsd-transition`):
1. Requirements invalidated? → Move to Out of Scope with reason
2. Requirements validated? → Move to Validated with phase reference
3. New requirements emerged? → Add to Active
4. Decisions to log? → Add to Key Decisions
5. "What This Is" still accurate? → Update if drifted

**After each milestone** (via `/gsd-complete-milestone`):
1. Full review of all sections
2. Core Value check — still the right priority?
3. Audit Out of Scope — reasons still valid?
4. Update Context with current state

---
*Last updated: 2026-04-29 after initialization*
