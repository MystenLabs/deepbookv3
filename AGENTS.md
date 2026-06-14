# DeepBook V3 Agent Guide

This file is the repo-level entry point for coding agents working in `deepbookv3`.

## Start Here

- Read [`CLAUDE.md`](/Users/aslantashtanov/Desktop/Projects/deepbookv3/CLAUDE.md) first.
- Treat `.claude/rules/*.md` as the source of truth for file-type-specific guidance.
- Keep changes scoped. This repo mixes Move contracts, Rust services, and TypeScript scripts.

## Repo Layout

- `packages/` contains Sui Move packages:
  - `deepbook/` is the core protocol.
  - `predict/` is the prediction-market package built on top of DeepBook patterns.
  - `deepbook_margin/`, `margin_trading/`, `margin_liquidation/`, `token/`, `dbtc/`, `dusdc/` are supporting packages.
- `crates/` contains Rust services:
  - `server/`, `indexer/`, `schema/`
- `scripts/` contains TypeScript transaction and ops scripts.
- `.claude/rules/` contains repo-specific coding, testing, and review guidance.

## Context Routing

These are the context files to consult. Path-scoped files are normally loaded by the agent runtime based on touched files; manual-trigger files must be read when the request matches the trigger.

### Path-Scoped Rules

- `.claude/rules/move.md` for `packages/**/*.move`
- `.claude/rules/unit-tests.md` for `packages/**/tests/**`
- `.claude/rules/indexer.md` for `crates/server/**`, `crates/indexer/**`, `crates/schema/**`
- `.claude/rules/scripts.md` for `scripts/**`
- `.claude/rules/predict-simulations.md` for `packages/predict/simulations/**`

### Manual-Trigger Rules

- `.claude/rules/code-review.md` when the user asks for a code review or review of uncommitted changes.
- `.claude/rules/wrap-up.md` when the user says "wrap up".

## Common Commands

### Move

- Build all Move packages:
  - `sui move build`
- Build a specific package:
  - `sui move build --path packages/predict`
  - `sui move build --path packages/deepbook`
- Run all tests for a package:
  - `sui move test --path packages/predict --gas-limit 100000000000`
  - `sui move test --path packages/deepbook --gas-limit 100000000000`
- Format Move code:
  - `bunx prettier-move -c path/to/file.move --write`

### Rust

- Build server:
  - `cargo build -p deepbook-server`
- Test server:
  - `cargo test -p deepbook-server`

### JavaScript / TypeScript

- Lint:
  - `pnpm run lint`
- Format:
  - `pnpm run prettier:fix`

## Working Norms

- Prefer narrow tests over broad changes. Most bugs here are boundary-condition bugs.
- For Move work, run the smallest relevant package test suite before expanding scope.
- For protocol changes, add or update unit tests in the package you touched.
- For complex unit tests, follow the existing style in core DeepBook tests:
  - short scenario comments above the test
  - inline arithmetic comments when expected values are not obvious
- Do not assume generated fixtures are authoritative if the on-chain integer math differs; test the contract behavior directly when needed.

## Predict Package Notes

- Predict sources are organized by domain subsystem, not by visibility. See `.claude/rules/move.md` for the canonical layout rule.
- Predict tests mirror source domain folders except shared helpers and broad flow tests.
- If you change Predict pricing, pool/vault accounting, oracle math, or public protocol flows, rerun the full Predict suite:
  - `sui move test --path packages/predict --gas-limit 100000000000`

## Predict Rework — LANDED (oracle extraction + tick re-encode + async NAV/LP)

The three reworks are **consolidated on `at/predict-prune-supply-withdraw`**: the oracle
extracted to the standalone `propbook` feeds (`predict_math`→`fixed_math`), strikes
re-encoded as absolute integer ticks, and the pool/NAV/LP layer rebuilt async with a
privileged flush + exact `current_nav` mark. Source builds `--warnings-are-errors`
green; `sui move test --path packages/predict --gas-limit 100000000000` is green; docs
are current. The earlier build-phase directives (source-only / defer-tests / defer-docs)
are **retired** — the normal norms (tests + docs land with code) apply again.

**Settled design decisions (do not re-litigate — from the `wb0ts5lgb` audit + the finalize audit):**
- **Oracle is external (propbook), predict-unaware.** `PythFeed` (global spot) + `BlockScholesFeed` (per-expiry surface). `expiry_market` owns feed binding (`assert_feeds`) + liveness (`assert_active`); `pricing` owns surface freshness + SVI math. Propbook stores raw BS source fields; the pricing-safe envelope (`forward>0`, basis, `|rho|<=1`, sigma band) is enforced by the consumer in `predict::pricing`.
- **One canonical strike interpretation = absolute integer ticks, protocol-wide** (`raw = tick * tick_size`). `range_codec` owns packing/conversion/the settlement prefix; no centered grid, no boundary indices. No-spot market creation; price-tail saturation.
- **The flush is PRIVILEGED, cron-driven** — operator `AdminCap` or market-deployer `MarketLifecycleCap`, NOT permissionless. Closes the NAV-manipulation gate (audit L8).
- **L10 supply mark = the EXACT `current_nav`** (tree walk − leveraged correction), one mark for supply AND withdraw, **no conservative band** (landed; the band belonged to the deleted approximate-NAV world).
- **Gas (L7), pending-settlement liveness (L6), rebate reclaim (L9) are OFF-CHAIN** (cron retries; operator throttles deploys near the flush window). Assume ≤10 markets + the 100-request drain fit one tx.
- **Settlement is deferred to settlement-v2** (`is_settled()` always false, `settlement_price()` aborts; settled paths kept gated). **Flush-liveness precondition:** because no market settles, an expired market is never swept off the active set, so `value_expiry` → `current_nav` → `assert_active` bricks the whole flush once any active market crosses its expiry. There is no solvency-safe substitute mark (the single flush mark prices both supply and withdraw, so it must equal the settlement-dependent true value — contribute-0 dilutes incumbents, free-cash over-drains them). Until settlement-v2, the operator MUST NOT let an active market cross its expiry across a flush. Documented on `expiry_market::current_nav` / `plp::value_expiry`.

**Still out of scope (follow-up work):**
- The Rust `crates/predict-{schema,indexer,server}` need rewiring for the changed events: the new async-LP events (`SupplyRequested`/`WithdrawRequested`/`SupplyFilled`/`WithdrawFilled`/`SupplyRefunded`/`WithdrawRefunded`/`RequestCancelled`/`PoolValued`/`FlushExecuted`), M1 `ExpiryCashRebalanced`, `OrderMinted` gaining `range_key`, `MarketCreated` dropping `market_oracle_id`/min/max strike and gaining `pyth_feed_id`/`bs_feed_id`, the collapsed `PricingConfigUpdated`, and the deleted oracle events — plus indexing the propbook feeds.
- The simulation harness (`packages/predict/simulations`) is structurally rewired (tsc/py_compile/`bash -n` clean) but its economic parity + the `run.sh` localnet publish flow need a localnet `run.sh` run — see `packages/predict/simulations/SIM_STATUS.md`.
- Settlement-v2 (the deferred settlement path off the propbook minute history).

## Code Review Norms

- When the user asks for a review, read `.claude/rules/code-review.md` before producing findings and review the relevant diff in a code-review stance.
- For Move reviews, also read `.claude/rules/move.md` and `.claude/rules/unit-tests.md`.

## When Updating Repo Guidance

Update `CLAUDE.md` or `.claude/rules/*.md` when you learn something that should change future agent behavior, especially:

- newly discovered bug patterns
- test-writing rules
- package-specific gotchas
- build or tooling pitfalls
