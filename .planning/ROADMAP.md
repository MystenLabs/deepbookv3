# Roadmap — DeepBook v3 Performance, Scalability & DX

## Overview

5 phases | 16 v1 requirements | Additive improvements to a production Rust/Axum/PostgreSQL stack.
Phases are ordered by impact and dependency: database foundations first, server restructuring second, documentation third, TypeScript client fourth (depends on OpenAPI spec), DX/testing last.

## Phase Table

| # | Phase | Goal | Requirements | Plans |
|---|-------|------|-------------|-------|
| 1 | DB Performance | Eliminate database bottlenecks at the query layer | PERF-01, PERF-02, PERF-03, PERF-04 | 4 plans |
| 2 | Server Ergonomics | Restructure server code and fix in-process inefficiencies | SCALE-01, SCALE-02, SCALE-03, PERF-05, DX-03 | TBD |
| 3 | OpenAPI Docs | Generate and serve a complete OpenAPI 3.0 specification | DX-01 | TBD |
| 4 | TypeScript Client | Publish a typed HTTP client for the indexer REST API | DX-02 | TBD |
| 5 | DX & Testing | Add test coverage, indexer PoC macro, and update project docs | SCALE-04, DX-04, DX-05, DX-06 | TBD |

## Phase Details

### Phase 1: DB Performance
**Goal:** Eliminate sequential scans and per-request blocking operations so that LP, portfolio, and net-deposit queries execute in milliseconds under load.
**Depends on:** Nothing (first phase)
**Requirements:** PERF-01, PERF-02, PERF-03, PERF-04
**Success Criteria:**
1. `EXPLAIN ANALYZE` on `asset_supplied` and `asset_withdrawn` LP queries shows index scan (not seq scan) for sender-filtered lookups.
2. Portfolio queries on `balances` use the new `asset_normalized` B-tree index — no leading-wildcard LIKE visible in query plans.
3. `get_net_deposits` endpoint responds without triggering `REFRESH MATERIALIZED VIEW` in the request path; a background `tokio::time::interval` task owns all refreshes.
4. `get_portfolio` acquires a single `AsyncPgConnection` for its 3 sub-queries — connection pool checkout count drops from 3 to 1 per request.
**Plans:** 4 plans
Plans:
- [ ] 01-01-PLAN.md — LP sender indexes: CREATE INDEX on asset_supplied(sender) and asset_withdrawn(sender)
- [ ] 01-02-PLAN.md — Background MV refresh: move REFRESH out of request path into tokio::spawn loop
- [ ] 01-03-PLAN.md — Asset normalization: add asset_normalized column + B-tree index + collateral query rewrite
- [ ] 01-04-PLAN.md — Portfolio connection audit: verify/fix get_portfolio uses single AsyncPgConnection
**UI hint:** no
**Parallelizable plans:** yes

---

### Phase 2: Server Ergonomics
**Goal:** Restructure the server module for maintainability and close in-process performance gaps (caching, named structs, input validation, asset normalization).
**Depends on:** Phase 1
**Requirements:** SCALE-01, SCALE-02, SCALE-03, PERF-05, DX-03
**Success Criteria:**
1. `crates/server/src/server.rs` no longer exists as a monolith; routes live under `crates/server/src/routes/{pools,orders,portfolio,margin,points,health}.rs`, each exporting a `router(state: AppState) -> Router` function.
2. `get_orders` returns an `OrderFill` named struct — the 17-tuple is gone from all call sites and the Diesel query.
3. Pool metadata and ticker responses are served from the `moka` in-process cache on repeat requests; TTLs are 60s and 10s respectively.
4. Invalid wallet addresses, out-of-range timestamps, and over-limit pagination values are rejected at the Axum extractor layer before reaching `reader.rs`.
**Plans:** TBD
**UI hint:** no
**Parallelizable plans:** yes

---

### Phase 3: OpenAPI Docs
**Goal:** Every public REST endpoint is described in a machine-readable OpenAPI 3.0 spec served live from the running server.
**Depends on:** Phase 2
**Requirements:** DX-01
**Success Criteria:**
1. `GET /swagger-ui/` returns a rendered Swagger UI page listing all public endpoints.
2. Each endpoint entry includes request parameter types, example values, and response schema — no undocumented fields.
3. The OpenAPI JSON can be fetched at `/api-docs/openapi.json` and validates against the OpenAPI 3.0 schema without errors.
**Plans:** TBD
**UI hint:** no
**Parallelizable plans:** no

---

### Phase 4: TypeScript Client
**Goal:** External TypeScript developers can import a fully-typed HTTP client and call the 15 core indexer endpoints without writing raw fetch calls.
**Depends on:** Phase 3
**Requirements:** DX-02
**Success Criteria:**
1. A typed TypeScript client (in `scripts/` or as a package) covers all 15 specified endpoints with correct parameter and response types.
2. Each client method has a usage example in inline JSDoc — a developer can call any endpoint correctly from IDE type hints alone.
3. The client compiles with `tsc --strict` with zero errors.
**Plans:** TBD
**UI hint:** no
**Parallelizable plans:** no

---

### Phase 5: DX & Testing
**Goal:** The codebase has meaningful test coverage at the Rust API, Move contract, and indexer layers, and project documentation reflects the new structure.
**Depends on:** Phase 2
**Requirements:** SCALE-04, DX-04, DX-05, DX-06
**Success Criteria:**
1. Integration tests for the 5 highest-traffic endpoints (`/get_pools`, `/trades/:pool_name`, `/orderbook/:pool_name`, `/portfolio/:wallet_address`, `/status`) pass against a test PostgreSQL instance via `cargo test`.
2. `packages/deepbook_margin` Move unit tests cover: margin manager creation, deposit/withdraw collateral, borrow/repay loan, and liquidation trigger — `sui move test` reports all passing.
3. At least one indexer handler is refactored using the declarative macro proof-of-concept; the macro generates `MoveStruct` impl and DB write from a compact declaration.
4. `CLAUDE.md` accurately describes the post-Phase-2 module structure, how to run tests, and any new build commands introduced during this initiative.
**Plans:** TBD
**UI hint:** no
**Parallelizable plans:** yes

---

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. DB Performance | 0/4 | Planned | - |
| 2. Server Ergonomics | 0/? | Not started | - |
| 3. OpenAPI Docs | 0/? | Not started | - |
| 4. TypeScript Client | 0/? | Not started | - |
| 5. DX & Testing | 0/? | Not started | - |

## Coverage

| Req ID | Phase |
|--------|-------|
| PERF-01 | Phase 1 |
| PERF-02 | Phase 1 |
| PERF-03 | Phase 1 |
| PERF-04 | Phase 1 |
| PERF-05 | Phase 2 |
| SCALE-01 | Phase 2 |
| SCALE-02 | Phase 2 |
| SCALE-03 | Phase 2 |
| DX-03 | Phase 2 |
| DX-01 | Phase 3 |
| DX-02 | Phase 4 |
| SCALE-04 | Phase 5 |
| DX-04 | Phase 5 |
| DX-05 | Phase 5 |
| DX-06 | Phase 5 |

**Mapped: 15/15 v1 requirements**

> Note: REQUIREMENTS.md lists 16 requirement IDs in its traceability table but the body defines 15 distinct v1 requirements (PERF-01–05, SCALE-01–04, DX-01–06). The coverage table above accounts for all 15 defined requirements.
