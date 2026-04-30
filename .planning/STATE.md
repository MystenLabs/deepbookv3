# Project State

**Project:** DeepBook v3 Improvements
**Current Phase:** 1 — DB Performance
**Status:** Ready to execute
**Last Updated:** 2026-04-30

---

## Current Position

| Field | Value |
|-------|-------|
| Active Phase | 1 — DB Performance |
| Active Plan | — (not started) |
| Phase Status | Planned — 4 plans, ready to execute |
| Overall Progress | 0 / 5 phases |

```
Progress: [P] [ ] [ ] [ ] [ ]
           P1  P2  P3  P4  P5
```
(P = Planned)

---

## Phase Registry

| Phase | Name | Requirements | Status |
|-------|------|-------------|--------|
| 1 | DB Performance | PERF-01, PERF-02, PERF-03, PERF-04 | Planned (4 plans) |
| 2 | Server Ergonomics | SCALE-01, SCALE-02, SCALE-03, PERF-05, DX-03 | Not started |
| 3 | OpenAPI Docs | DX-01 | Not started |
| 4 | TypeScript Client | DX-02 | Not started |
| 5 | DX & Testing | SCALE-04, DX-04, DX-05, DX-06 | Not started |

---

## Accumulated Context

### Key Decisions Logged
- Move contracts are read-only for this initiative (financial contract changes require security audit)
- Use `utoipa` for OpenAPI (zero-runtime overhead, derive-macro, Axum compatible)
- Normalize asset IDs at indexer ingestion time (fix at write time, not query time)
- Background MV refresh via `tokio::time::interval` (already on tokio runtime)
- In-process `moka` cache — no Redis dependency

### Known Constraints
- `CREATE INDEX CONCURRENTLY` cannot run inside a Diesel transaction-wrapped migration — must run as a separate migration step
- `REFRESH MATERIALIZED VIEW CONCURRENTLY` requires a unique index on the view — verify before moving to background
- `f64` → `Decimal` migration: use existing `bigdecimal` dep, not a new `rust_decimal` dep
- Axum state extraction must be unified (`State<AppState>`) before splitting `server.rs`

### Blockers
- None at initialization

### Open Questions
- None at initialization

---

## Session Continuity

**Last session:** 2026-04-30
**Stopped at:** Phase 1 planning complete — 4 plans verified, ready to execute.

**Next action:** `/gsd-execute-phase 1` — execute Phase 1 (DB Performance)
