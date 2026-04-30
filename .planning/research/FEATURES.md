---
date: 2026-04-30
source: official docs + codebase analysis
---

# Features Research — DeepBook v3 DX/Perf Improvements

## Table Stakes (must have — users/integrators expect these)

### Database Performance
- **Missing indexes present** — `asset_supplied.sender`, `asset_withdrawn.sender` absent; causes sequential scans on LP queries
- **Normalized asset ID column** — `balances.asset` uses leading-wildcard LIKE; no B-tree coverage
- **Materialized view refresh out of request path** — currently blocks every `get_net_deposits` call
- **Connection reuse in compound queries** — `get_portfolio` acquires 3+ separate connections

### API Quality
- **Named return types** — `get_orders` returns a 17-tuple; every serious API has typed structs
- **OpenAPI/Swagger docs** — standard for any production REST API; currently absent
- **Consistent error responses** — need verification that all errors return machine-readable JSON
- **Input validation at route layer** — currently `wallet_address` validated in reader (wrong layer)

### Developer Tooling
- **TypeScript indexer HTTP client** — the official `@mysten/deepbook-v3` SDK covers on-chain ops but has NO typed client for the indexer REST API; integrators build raw `fetch()` calls
- **Test coverage for server API** — no confirmed integration test suite for the REST endpoints
- **Move test coverage for margin/predict** — complex financial packages with no confirmed tests

## Differentiators (competitive advantage)

### Performance
- **In-process caching layer** (moka) for pool metadata, ticker, OHLCV — reduces DB load at peak
- **`rust_decimal` / `Decimal` for financial display** — precision guarantee vs `f64` rounding
- **Asset ID normalization at ingestion time** — fixes at the write path rather than every query
- **Batch endpoint for multiple portfolio lookups** — currently only single wallet supported

### DX
- **Typed TS indexer API client** — auto-generated from OpenAPI spec or hand-crafted; enables ecosystem builders to query indexed data without reading source code
- **Handler macro / code-gen** — reduce 54+ boilerplate handler files to a declarative registry
- **SDK coverage for margin + predict** — currently missing from `@mysten/deepbook-v3`
- **`server.rs` module split** — currently ~1600 lines; split by domain (pools, orders, margin, portfolio, admin)

### Observability
- **Per-endpoint request latency histograms** — currently only DB latency tracked; need HTTP-level metrics
- **Structured tracing with span IDs** — correlate indexer lag with API response times
- **Indexer pipeline health dashboard** — expose per-pipeline watermark lag via `/status`; already partly there

## Anti-features (deliberately NOT build)

- **New financial products** — margin parameters, new pool types, liquidation changes: requires full audit
- **On-chain Move contract changes** — out of scope; all improvements are off-chain
- **Redis caching layer** — `moka` in-process is sufficient; Redis adds ops complexity for this workload
- **GraphQL API** — REST is established and working; GraphQL rewrite has no clear benefit here
- **Custom authentication for public endpoints** — public indexer data should remain openly accessible
- **Read replica setup** — premature; fix queries first before adding DB infrastructure

## Current Gaps vs Official Best Practice

| Gap | Official Guidance | Current State |
|-----|------------------|---------------|
| Indexer API typed client | Docs show HTTP endpoints but no TS client | Developers use raw fetch |
| SDK margin coverage | `@mysten/deepbook-v3` covers core only | No margin/predict SDK |
| API documentation | No OpenAPI spec published | Read source to understand API |
| Asset decimal handling | Docs specify exact decimals per asset | Code normalizes inconsistently |
| Timestamp units | Docs: params in seconds, responses in ms | Implementation matches but undocumented |
| Connection health | `/status` endpoint exists in design | Need to verify implementation |

## Feature Complexity Notes

| Feature | Complexity | Blocking dependencies |
|---------|-----------|----------------------|
| Add DB indexes (CONCURRENTLY) | Low | DB migration tooling |
| Fix materialized view refresh | Low | tokio background task |
| Normalize asset IDs at ingestion | Medium | Requires indexer migration + backfill |
| OpenAPI docs (utoipa) | Medium | Annotate ~50 handler routes |
| Named struct for get_orders | Low | Refactor + update all callers |
| TypeScript indexer HTTP client | Medium | OpenAPI spec first (or manual) |
| server.rs module split | Medium | Router refactor, test coverage first |
| Handler macro/code-gen | High | Deep Rust macro expertise needed |
| SDK margin/predict coverage | High | Requires understanding all contract ops |
| Integration test suite | Medium | Test DB setup, fixture generation |
