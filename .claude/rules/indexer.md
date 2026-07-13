---
paths:
  - "crates/server/**"
  - "crates/schema/**"
  - "crates/indexer/**"
---

# Core Indexer Rules (thin stub)

Deliberately minimal after the 2026-07-06 rules cleanup: this file covers only the core DeepBook Rust crates that remain in this repo (`crates/{server,indexer,schema}`), and retires entirely when those crates migrate out. Full retired guidance is recoverable at `git show 9439529a~1:.claude/rules/indexer.md`.

- `/ticker` (and `/summary`, which calls it) is the 504 hotspot: `fetch_historical_volume()` runs twice over 24h of `order_fills` plus a DISTINCT ON last-price query, with no pagination or caching — treat `crates/server/src/server.rs` changes there as performance-critical.
- The composite indexes for those query shapes already exist via migration `2026-02-03-000000-0000_add_ticker_performance_indexes` — do not re-add them.
- Diesel migrations run inside a transaction: `CREATE INDEX CONCURRENTLY` cannot be used in them; use `IF NOT EXISTS` for idempotency. For zero-downtime index creation on production, run `CREATE INDEX CONCURRENTLY` manually via psql first, then the `IF NOT EXISTS` migration is a no-op.
- PostgreSQL function matching needs exact parameter types: `to_timestamp()` returns `TIMESTAMPTZ`; cast `to_timestamp($3)::timestamp` when the function expects `TIMESTAMP`.
- `ParameterUtil` defaults `limit=1` when no limit is passed — it silently truncates ~24 list endpoints; don't mistake one-row responses for missing data.
- `/margin_manager_states` returns ALL rows (no pagination) — memory/timeout risk against large tables.
- The server creates 3 separate connection pools (reader / writer / margin poller) against the same Postgres — monitor total connections when diagnosing pool exhaustion.
- Pre-push: `cargo fmt -p deepbook-server` (CI fails on formatting) and `cargo build -p deepbook-server`.

## Full-node reads are gRPC, not JSON-RPC

Sui deactivated JSON-RPC on 2026-07-31. The server reads the chain over `sui.rpc.v2` gRPC (`sui-rpc` crate); `crates/server/src/grpc.rs` owns every call. The indexer never talked to a node — it ingests checkpoints from the remote store — so it was never affected. Three gotchas, each of which fails *silently or misleadingly*:

- **`read_mask` defaults are lossy.** `GetObject` defaults to `object_id,version,digest`, so `owner` comes back **empty unless you ask for it** — and `owner` is the only reason we fetch the object (it carries `initial_shared_version`). Likewise `SimulateTransaction` only populates `command_outputs` when the mask requests it. A forgotten mask reads as "not a shared object" / "no results", not as an error.
- **`checks: DISABLED` does NOT skip gas-object resolution.** The node still tries to load the gas coin, so a placeholder like `ObjectInput::owned(Address::ZERO, ..)` fails with `Could not find the referenced object 0x0`. `TransactionBuilder::try_build()` *requires* a gas coin, so build with one and then `transaction.gas_payment.objects.clear()` before simulating. That empty-gas-list posture is what actually reproduces `dev_inspect`.
- **`Owner.version` is overloaded** — `initial_shared_version` when `kind == SHARED`, `start_version` when `CONSENSUS_ADDRESS`. Check the kind before trusting it.

`sui-sdk-types` 0.3.x made `StructTag`'s fields private: use `StructTag::new(..)` and the `.address()` / `.module()` / `.name()` accessors.

## Running the indexer snapshot tests locally

They spin up a temporary Postgres, which needs the **server** binary — `libpq` alone is not enough, and `initdb` fails with `program "postgres" is needed by initdb but was not found`. All 35 tests then fail for a reason that has nothing to do with your change. Fix:

```
brew install postgresql@16
export PATH="/opt/homebrew/opt/postgresql@16/bin:$PATH"
cargo test -p deepbook-indexer
```

These snapshot tests are the real regression net for `traits.rs` event-type matching — every handler decodes real checkpoint events through it, so run them after touching event matching or the `sui-sdk-types` pin.
