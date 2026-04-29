---
date: 2026-04-29
focus: quality
---

# Testing

## Move Tests

**Framework:** Sui Move test framework (built-in)

**Location:** `packages/*/tests/` — mirrors `sources/` structure

**Run command:**
```bash
sui move test --gas-limit 100000000000
```

**Coverage (deepbook core):**
```
packages/deepbook/tests/
├── balance_manager_tests.move    # BalanceManager deposit/withdraw/transfer
├── big_vector_tests.move         # BigVector CRUD + pagination
├── master_tests.move             # Integration: full order lifecycle
├── order_query_tests.move        # Open order querying
├── pool_tests.move               # Pool creation + parameter validation
├── book/
│   ├── order_info_tests.move     # OrderInfo construction/validation
│   └── order_tests.move         # Order struct tests
└── state/
    ├── account_tests.move        # Account position tracking
    ├── ewma_tests.move           # EWMA algorithm correctness
    ├── governance_tests.move     # Voting + proposal lifecycle
    ├── history_tests.move        # Fee/rebate history
    ├── state_tests.move          # Pool state aggregate
    └── trade_params_tests.move   # Fee parameter validation
    └── vault/
        └── vault_tests.move      # Asset custody + flash loans
```

**Test style:**
- Pure unit tests — each test sets up its own mock `Clock`, `Coin`, etc.
- Integration-style via `master_tests.move` — exercises full order placement → fill → settlement flow
- Tests use `#[test]` attribute with optional `#[expected_failure(abort_code = EXxx)]`

**No test coverage observed for:**
- `packages/deepbook_margin/` — no tests directory confirmed
- `packages/predict/` — tests directory not confirmed
- Multi-package integration tests

## Rust Tests

**Framework:** Rust built-in `#[test]` + `insta` for snapshot testing

**Indexer tests (`crates/indexer`):**
```toml
[dev-dependencies]
insta = { version = "1.43.1", features = ["json"] }
serde_json = "1.0.140"
sqlx = { version = "0.8.3", features = ["runtime-tokio", "postgres", "chrono", "bigdecimal"] }
fastcrypto = { ... }
chrono = "0.4.39"
```
- Uses `sqlx` in tests (separate from Diesel in production) — integration tests hit real DB
- `insta` used for JSON snapshot assertions on handler outputs
- `sui-storage` available for test checkpoint creation

**Server tests:**
- No dedicated test dev-dependencies observed in `crates/server/Cargo.toml`
- Likely relies on integration testing via the bench crate or manual testing

**Run commands:**
```bash
cargo test -p deepbook-server   # Server tests
cargo test -p deepbook-indexer  # Indexer tests (requires PostgreSQL)
```

**Sandbox (`crates/indexer/src/sandbox.rs`):**
- Local checkpoint replay for development/debugging
- Not CI tests — operational tool

## Benchmarks

**Crate:** `crates/bench/`
- `runner.rs` — benchmark execution engine
- `api.rs` — HTTP API load testing utilities
- `queue.rs` — request queue for concurrent load
- `metrics.rs` + `store.rs` — measurement collection

Used for performance regression testing of the REST API.

## TypeScript Tests

**Status:** No test framework configured.
```json
// package.json
"test": "echo \"Error: no test specified\" && exit 1"
```
Scripts have no automated tests. Manual verification only.

## CI / Linting

**Move formatting:**
```bash
bunx prettier-move -c *.move --write
```

**TypeScript linting:**
```bash
pnpm run lint        # eslint + prettier check
pnpm run lint:fix    # auto-fix
```

**No CI configuration observed** (no `.github/workflows/` confirmed) — may exist but not read.

## Test Gaps (Summary)

| Area | Coverage | Gap |
|------|---------|-----|
| DeepBook Move contracts | Good — unit + integration | Margin + predict packages undertested |
| Rust indexer handlers | Snapshot tests via insta | No confirmed per-handler test coverage |
| Rust server API | Unknown — likely manual | No unit/integration test suite observed |
| TypeScript scripts | None | All scripts are untested |
| End-to-end | None confirmed | No E2E test suite |
