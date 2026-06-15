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

**These rule files are NOT auto-loaded for you.** Codex auto-loads this `AGENTS.md`, but nothing loads `.claude/rules/*.md` by path — the `paths:` frontmatter on each is a map for a future hook, not a live mechanism. **Before editing a file under one of these globs, open and read the matching rule file.** Read manual-trigger files when the request matches.

### Path-Scoped Rules — read before editing files under the glob

- `.claude/rules/move.md` for `packages/**/*.move`
- `.claude/rules/unit-tests.md` for `packages/**/tests/**`
- `.claude/rules/predict-simulations.md` for `packages/predict/simulations/**`
- `.claude/rules/indexer.md` for the CORE crates `crates/{server,indexer,schema}/**`
- `.claude/rules/predict-indexer.md` for the PREDICT crates `crates/predict-{server,indexer,schema}/**` (also read `indexer.md` for shared operational gotchas)
- `.claude/rules/scripts.md` for `scripts/**`

### Manual-Trigger Rules — read when the request matches

- `.claude/rules/code-review.md` when the user asks for a code review or review of uncommitted changes (for a deep Predict protocol review it routes on to the `.claude/predict-review/` lenses + `rule-auditor.md`).
- Before proposing/changing any **Predict economics** (NAV/backing, rounding, oracle trust, liquidation, tick/order-id encoding, floor/leverage, supply/withdraw): grep `.claude/predict-design/DECISION_JOURNAL.md` + `HISTORY.md` for prior rulings; never re-open a `rejected` decision unless its `don't-revisit-unless` condition is met. (The current settled list is also inlined below.)
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
- **Oracle is external (propbook), predict-unaware.** `PythFeed` (global spot) + `BlockScholesFeed` (per-expiry surface). `expiry_market` stores the Propbook underlying and tick size; `pricing::load_live_pricer` owns the live pricing boundary: current Propbook canonical binding, pre-expiry live-pricing check, feed freshness, and SVI math. Propbook stores raw BS source fields; the pricing-safe envelope (`forward>0`, basis, `|rho|<=1`, sigma band) is enforced by the consumer in `predict::pricing`.
- **One canonical strike interpretation = absolute integer ticks, protocol-wide** (`raw = tick * tick_size`). `range_codec` owns packing/conversion/the settlement prefix; no centered grid, no boundary indices. No-spot market creation; price-tail saturation.
- **The flush is PRIVILEGED, cron-driven** — started only by a market-deployer `MarketLifecycleCap` (revocable; the root `AdminCap` flush path was removed, admin keeps break-glass by minting itself a lifecycle cap), NOT permissionless. Closes the NAV-manipulation gate (audit L8). `finish_flush` takes independent `supply_budget` / `withdraw_budget: Option<u64>` (None = drain that queue fully), operator-sized to the gas left after valuing the snapshot; independent budgets mean a supply backlog can't starve withdrawals.
- **L10 supply mark = the EXACT `current_nav`** (tree walk − leveraged correction), one mark for supply AND withdraw, **no conservative band** (landed; the band belonged to the deleted approximate-NAV world).
- **Protocol-reserve realization is deferred-and-carried (D033).** The materialized protocol cut is split from idle only up to available idle; any remainder (cash redeployed to fund other markets before settlement) is carried in `pending_protocol_profit` and realized on a later sweep. `lp_pool_value` subtracts the carried cut so LP pricing stays exact, and the settled sweep / flush can never brick on the split (ROUNDING_POLICY R1). Realization never preempts trader-payout funding.
- **Gas (L7), pending-settlement liveness (L6), rebate reclaim (L9) are OFF-CHAIN** (cron retries; operator throttles deploys near the flush window). Assume ≤10 markets + the operator-sized per-queue request drain fit one tx (the operator picks `supply_budget`/`withdraw_budget` so the flush stays under the gas ceiling, and carries the rest).
- **Settlement is passive off Propbook exact Pyth timestamp history.** There is no public settle-only entrypoint: `expiry_market::ensure_settled` is the package-level branch gate used by settled redeem and pool rebalance/valuation. It validates the current Propbook Pyth binding and records `normalized_spot_at(expiry)` if present. If exact data is missing after expiry, the market remains unsettled and live valuation aborts; do not substitute an approximate mark because the single flush mark prices both supply and withdraw.

**Still out of scope (follow-up work):**
- The Rust `crates/predict-{schema,indexer,server}` need rewiring for the changed events: the new async-LP events (`SupplyRequested`/`WithdrawRequested`/`SupplyFilled`/`WithdrawFilled`/`SupplyRefunded`/`WithdrawRefunded`/`RequestCancelled`/`PoolValued`/`FlushExecuted`), M1 `ExpiryCashRebalanced`, `OrderMinted` gaining `range_key`, `MarketCreated` dropping `market_oracle_id`/min/max strike/source oracle ids and carrying `propbook_underlying_id` + `tick_size`, the collapsed `PricingConfigUpdated`, and the deleted oracle events — plus indexing the propbook feeds.
- The simulation harness (`packages/predict/simulations`) is structurally rewired (tsc/py_compile/`bash -n` clean) but its economic parity + the `run.sh` localnet publish flow need a localnet `run.sh` run — see `packages/predict/simulations/SIM_STATUS.md`.

## Code Review Norms

- When the user asks for a review, read `.claude/rules/code-review.md` before producing findings and review the relevant diff in a code-review stance.
- For Move reviews, also read `.claude/rules/move.md` and `.claude/rules/unit-tests.md`.
- For a deep Predict pre-merge / pre-testnet protocol review, read `.claude/predict-review/00-primer.md` and the relevant lens (01-invariants, 02-audit, 03-oracle, 04-access-control, 05-surface-area, 06-assertions, 07-lifecycle). For a full rule audit of `packages/predict`, follow `rule-auditor.md` (12 read-only rule-family agents).

## When Updating Repo Guidance

Update `CLAUDE.md` or `.claude/rules/*.md` when you learn something that should change future agent behavior, especially:

- newly discovered bug patterns
- test-writing rules
- package-specific gotchas
- build or tooling pitfalls
