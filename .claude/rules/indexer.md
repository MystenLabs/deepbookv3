---
paths:
  - "crates/server/**"
  - "crates/schema/**"
  - "crates/indexer/**"
---

# Core Indexer Rules (thin stub)

Deliberately minimal after the 2026-07-06 rules cleanup: the shared Postgres/diesel gotchas live in `.claude/rules/predict-indexer.md`; this stub retires entirely when the core crates migrate out of this repo. Full retired guidance is recoverable at `git show 9439529a~1:.claude/rules/indexer.md`.

- `/ticker` (and `/summary`, which calls it) is the 504 hotspot: `fetch_historical_volume()` runs twice over 24h of `order_fills` plus a DISTINCT ON last-price query, with no pagination or caching — treat `crates/server/src/server.rs` changes there as performance-critical.
- The composite indexes for those query shapes already exist via migration `2026-02-03-000000-0000_add_ticker_performance_indexes` — do not re-add them.
- `ParameterUtil` defaults `limit=1` when no limit is passed — it silently truncates ~24 list endpoints; don't mistake one-row responses for missing data.
- `/margin_manager_states` returns ALL rows (no pagination) — memory/timeout risk against large tables.
- Pre-push: `cargo fmt -p deepbook-server` (CI fails on formatting) and `cargo build -p deepbook-server`.
