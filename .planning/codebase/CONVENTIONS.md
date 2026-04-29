---
date: 2026-04-29
focus: quality
---

# Conventions

## Move Code Style

**Module structure:**
```move
// License header (Apache-2.0)
module package::module_name;

// === Imports ===
use package::dep;
use sui::...;

// === Errors ===
const EErrorName: u64 = 1;

// === Structs ===
public struct Foo has key, store { ... }

// === Public Functions ===
public fun do_thing(...) { ... }

// === Package Functions ===
public(package) fun internal_thing(...) { ... }
```

**Naming:**
- Modules: `snake_case` — `balance_manager`, `deep_price`
- Structs: `PascalCase` — `Pool`, `OrderInfo`, `BigVector`
- Functions: `snake_case` — `place_limit_order`, `get_quantity`
- Error constants: `E` prefix + `PascalCase` — `EInvalidFee`, `ESameBaseAndQuote`
- Regular constants: `UPPER_SNAKE_CASE`

**Error codes:** Sequential integers starting at 1. Each module has its own error namespace.

**Versioning pattern:**
```move
public struct Pool<phantom BaseAsset, phantom QuoteAsset> has key {
    id: UID,
    inner: Versioned,  // dynamic field wrapper for upgradeable storage
}
```
All mutable operations check `allowed_versions` before proceeding.

**Generic phantoms:** Token types always parameterize pool structs (`Pool<BaseAsset, QuoteAsset>`) for type safety.

**`use fun` aliases:** Used for UID dynamic field ops:
```move
use fun df::add as UID.add;
use fun df::borrow as UID.borrow;
```

## Rust Code Style

**Error handling:**
- `anyhow::Error` at I/O boundaries (indexer pipeline, DB connections)
- `thiserror`-derived `DeepBookError` in server for typed HTTP error mapping
- Never `unwrap()` in production paths — use `?` or explicit `map_err`

**Async patterns:**
- All DB calls are `async` via `diesel-async`
- `tokio::spawn` for background tasks (margin metrics poller)
- `Arc<T>` for shared state (metrics, DB pool passed to handlers)

**Metrics pattern:**
```rust
let _guard = self.metrics.db_latency.start_timer();
let res = query.get_results(&mut conn).await;
if res.is_ok() {
    self.metrics.db_requests_succeeded.inc();
} else {
    self.metrics.db_requests_failed.inc();
}
```
This pattern repeats for every DB call in `reader.rs`. Timer drops on scope exit.

**Handler boilerplate (indexer):**
Each handler file follows the same pattern:
1. Define struct implementing `MoveStruct` with `MODULE` + `NAME` constants
2. Implement `From<EventStruct> for DbModel`
3. Write rows via `diesel-async` INSERT

**Query patterns (reader.rs):**
- Prefer `Selectable::as_select()` over manual column listing
- Use `to_pattern()` helper for wildcard-tolerant LIKE filters
- Dynamic filters via `.into_boxed()` + conditional `.filter()` chains
- Raw SQL via `diesel::sql_query()` for complex CTEs

**`to_pattern()` convention:**
```rust
fn to_pattern(s: &str) -> String {
    if s.is_empty() { "%".to_string() } else { s.to_string() }
}
```
Allows passing empty string to mean "all" without Option types.

**Financial data:** `i64` for raw on-chain amounts (fixed-point), `f64` for display/API values. `bigdecimal::BigDecimal` used in schema models but `f64` used in API response structs — conversions happen in reader queries.

## TypeScript Style

**ESLint config:** `@typescript-eslint`, `eslint-import-resolver-typescript`, `eslint-plugin-header` (license headers), `eslint-plugin-unused-imports`

**Import ordering:** Enforced by `@ianvs/prettier-plugin-sort-imports`

**License headers:** Apache-2.0 header required on all files (enforced by ESLint header plugin)

**Script pattern:** Each `scripts/transactions/*.ts` file is a standalone executable:
```typescript
// Execute directly: tsx scripts/transactions/createPool.ts
async function main() { ... }
main().catch(console.error);
```

## Git Conventions

**Commit messages:** Standard format observed (`docs:`, `fix:`, `feat:`, etc.)

**CLAUDE.md behavioral rules:**
- No speculative abstractions — solve exactly what's asked
- Surgical changes — don't touch adjacent code
- Verify assumptions before implementing
- When fixing bugs: write test reproducing issue first
- PR format: Summary bullets + Key decisions + Test plan checklist

## Documentation

**In-code docs:**
- Move: block comments `///` for public functions
- Rust: `///` doc comments on public types; inline `//` for non-obvious logic
- Notable: `reader.rs` has extensive inline SQL comments explaining performance gotchas (e.g., missing indexes, sequential scan risks from `LIKE '%...'`)

**Architecture docs:** `DBv3Architecture.png` (root), `docs/` directory
