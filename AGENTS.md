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
  - `server/`, `indexer/`, `schema/` — the core DeepBook indexer stack
- `scripts/` contains TypeScript transaction and ops scripts.
- `.claude/rules/` contains repo-specific coding, testing, and review guidance.

## Context Routing

**Do not assume the rule files are in your context.** Codex auto-loads this `AGENTS.md` but nothing loads `.claude/rules/*.md` for you (recent Claude Code versions inject them by path via the `paths:` frontmatter; Codex and other agents get no injection). **Before editing a file under one of these globs, open and read the matching rule file.** Read manual-trigger files when the request matches.

### Path-Scoped Rules — read before editing files under the glob

- `.claude/rules/move.md` for `packages/**/*.move`
- `.claude/rules/predict-contracts.md` for the Predict-cluster packages `packages/{predict,propbook,block_scholes_oracle,account}/**/*.move` (also read `move.md`)
- `.claude/rules/unit-tests.md` for `packages/**/tests/**`
- `.claude/rules/predict-harness.md` for `packages/predict/harness/**`
- `.claude/rules/indexer.md` for the CORE crates `crates/{server,indexer,schema}/**` (thin stub)
- `.claude/rules/scripts.md` for `scripts/**`

### Manual-Trigger Rules — read when the request matches

- `.claude/rules/code-review.md` when the user asks for a code review or review of uncommitted changes (for a deep Predict smart-contract audit, invoke the `predict-audit` skill at `.claude/skills/predict-audit/` — `rule-sweep.workflow.js` is the per-rule mechanical sweep, `ownership-walk.workflow.js` the per-module ownership conformance).
- Before proposing/changing any **Predict economics** (NAV/backing, rounding, oracle trust, liquidation, tick/order-id encoding, floor/leverage, supply/withdraw): read `packages/predict/predeploy/README.md` (the system map + authority order), then `open-items.md`, `response-policies.md` (incl. its Rounding policy R1–R3 section), and the settled + rejected lists below. `.claude/predict-design/` and `.redesign/` are personal scratch only — nothing load-bearing lives there; verify any old claim against current HEAD before relying on it.
- `.claude/rules/harness-strategy.md` when the user wants to add or build a Predict harness trading strategy or test a scenario in the harness (also read `.claude/rules/predict-harness.md`).
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

- Predict sources are organized by domain subsystem, not by visibility. See `.claude/rules/predict-contracts.md` for the canonical layout rule.
- Predict tests mirror source domain folders except shared helpers and broad flow tests.
- If you change Predict pricing, pool/vault accounting, oracle math, or public protocol flows, rerun the full Predict suite:
  - `sui move test --path packages/predict --gas-limit 100000000000`

## Predict Rework — LANDED (oracle extraction + tick re-encode + async NAV/LP)

The three reworks are **landed on `main`**: the oracle
extracted to the standalone `propbook` feeds (`predict_math`→`fixed_math`), strikes
re-encoded as absolute integer ticks, and the pool/NAV/LP layer rebuilt async with a
privileged flush + exact `current_nav` mark. Source builds `--warnings-are-errors`
green; `sui move test --path packages/predict --gas-limit 100000000000` is green; docs
are current. The earlier build-phase directives (source-only / defer-tests / defer-docs)
are **retired** — the normal norms (tests + docs land with code) apply again.

**Canonical design-decision record:** `packages/predict/docs/design/decisions.md` is the source of
truth for Predict design decisions (chosen shape, rationale, rejected alternatives + revisit
conditions); tail-state response decisions live in `packages/predict/predeploy/response-policies.md`.
Record NEW design decisions there, not here. The list below is a dev quick-reference — do not
re-litigate a settled decision or reintroduce a rejected direction without meeting its stated revisit
condition. (Retiring this quick-reference to a pure pointer, once `decisions.md` is confirmed a
superset, is a deferred follow-up.)

**Settled design decisions (do not re-litigate — from the `wb0ts5lgb` audit + the finalize audit):**
- **Oracle is external (propbook), predict-unaware.** `PythFeed` (global spot) + split Block Scholes feeds (`BlockScholesSpotFeed`, `BlockScholesForwardFeed`, `BlockScholesSVIFeed`). `expiry_market` stores the Propbook underlying and tick size; `pricing::load_live_pricer` owns the live pricing boundary: current Propbook canonical binding, pre-expiry live-pricing check, feed freshness, and SVI math. Propbook stores raw BS source fields; the pricing-safe envelope (`forward>0`, basis, `|rho|<=1`, sigma band) is enforced by the consumer in `predict::pricing`.
- **One canonical strike interpretation = absolute integer ticks, protocol-wide** (`raw = tick * tick_size`). `range_codec` owns packing/conversion/the settlement prefix; no centered grid, no boundary indices. No-spot market creation; price-tail saturation.
- **The flush is PRIVILEGED, cron-driven** — started only by a market-deployer `MarketLifecycleCap` (revocable; the root `AdminCap` flush path was removed, admin keeps break-glass by minting itself a lifecycle cap), NOT permissionless. Closes the NAV-manipulation gate (audit L8). `finish_flush` takes independent `supply_budget` / `withdraw_budget: Option<u64>` (None = drain that queue fully), operator-sized to the gas left after valuing the snapshot; independent budgets mean a supply backlog can't starve withdrawals.
- **L10 supply mark = the EXACT `current_nav`** (tree walk − leveraged correction), one mark for supply AND withdraw, **no conservative band** (landed; the band belonged to the deleted approximate-NAV world).
- **Protocol-reserve realization is deferred-and-carried (D033).** The materialized protocol cut is split from idle only up to available idle; any remainder (cash redeployed to fund other markets before settlement) is carried in `pending_protocol_profit` and realized on a later sweep. `lp_pool_value` subtracts the carried cut so LP pricing stays exact, and the settled sweep / flush can never brick on the split (ROUNDING_POLICY R1). Realization never preempts trader-payout funding.
- **Gas (L7), pending-settlement liveness (L6), rebate reclaim (L9) are OFF-CHAIN** (cron retries; operator throttles deploys near the flush window). Assume ≤10 markets + the operator-sized per-queue request drain fit one tx (the operator picks `supply_budget`/`withdraw_budget` so the flush stays under the gas ceiling, and carries the rest).
- **Settlement is passive off Propbook exact Pyth timestamp history.** There is no public settle-only entrypoint: `expiry_market::ensure_settled` is the package-level branch gate used by settled redeem and pool rebalance/valuation. It validates the current Propbook Pyth binding and records `normalized_spot_at(expiry)` if present. If exact data is missing after expiry, the market remains unsettled and live valuation aborts; do not substitute an approximate mark because the single flush mark prices both supply and withdraw.
- **Account app-auth is intentionally full-account, package-level authority.** An app authorized through `account::AccountRegistry` can mutably load any `AccountWrapper` it is handed and can use the normal `Account` balance/data APIs. Do not add per-user/per-coin app scoping unless a future account-margining design introduces dependency-aware user app grants (for example, preventing app revocation while open margin obligations require cross-app liquidation).

**Settled decisions — later additions (static-floor knockout era + promoted journal decisions):**
- **Static-floor knockout leverage (landed).** `floor_shares` is a static `F` frozen at mint; a winner redeems `quantity - floor_shares`; an order knocks out when its gross value reaches `floor_amount / liquidation_ltv`. No rising floor, no `floor_index`/`terminal_floor_index`, no clock-dependent backing term; NAV is the exact per-expiry recoverable value. Any doc describing a rising/time-varying floor is stale. Full invariants: `.claude/rules/move.md` "Predict Economics".
- **D025 — redeem deliberately has NO ask-price bound.** The mint-side probability bound is admission policy (the protocol declines to become counterparty in tail price regions); once a contract is live, redeeming at the live mark is the holder's right, and a redeem clamp would systematically underpay legitimate deep-ITM winners near expiry. The oracle-compromise exposure this leaves is the accepted trust model tracked by deploy gate S-4 / D031. Don't re-add exit-path price gates unless the oracle trust model changes.
- **D026 — strike-quantity math stays u64.** A u128 widening was tried and deliberately reverted: the u64 mul ceiling is accepted because the failure mode is a graceful per-tx mint abort at extreme strike×quantity, never a brick, and inline u128 casts duplicated `fixed_math` semantics inside a core module. Don't reintroduce the widening.
- **Pause/valuation gate exemptions (decided 2026-07-02).** `rebalance_expiry_cash`'s grow direction (`top_up_live_expiry_cash`) is intentionally NOT trading-pause-gated: pause blocks risk creation at the mint gate itself, while top-up only positions cash backing existing exposure and keeps exits fundable (gating it could starve redeems mid-emergency). `plp::lock_capital` intentionally carries no valuation-lock gate: it is only legal at `total_supply == 0`, and both LP request entrypoints abort `ENotBootstrapped` until supply > 0, so no queue entry or PLP holder the lock protects can exist when it runs.
- **Audit dispositions promoted from the 2026-07-02 cleanup pass (the audit skill's cross-run adjudication carry was removed — durable dispositions live here).** `plp::stake_deep`/`unstake_deep` intentionally carry no valuation-lock gate: staked DEEP is excluded from `lp_pool_value`, so neither can move the flush mark. The raw-ID key-anchoring rule targets constructors/mutators; public read-only ID lookups (e.g. `predict_account::has_position`) are conformant as-is. The `CadenceConfig` getter surface on `market_manager` is deliberately retained observability/PTB read surface (e644181c). `predict_account`'s `EInsufficientPosition` guard protects a structurally-unreachable count underflow — defense-in-depth, documented here rather than given a contrived bypass test (unit-tests Rule 12).
- **D031 — no oracle deviation/basis guards, deliberately (057f9565).** Per-push spot/basis deviation checks and the absolute basis band were removed: within the pricing-safe envelope, a compromised or buggy source prices live flows without bounds. Accepted and disclosed; the production mitigation is the signature verifier / cap-gating tracked by deploy gate S-4 (`packages/predict/predeploy/open-items.md`).
- **Launch parameters: the contract defaults ARE the genesis values (AUD-002, 2026-06-10).** No separate launch checklist; `config_constants` defaults (`backing_buffer_lambda` 0.25, caps, budgets) ship as-is unless an open item changes one.
- **Degenerate/tail-state behavior decisions live in `packages/predict/predeploy/response-policies.md`** (chosen response, reasoning, risk profile, pinning tests). Check it before adding, removing, or weakening any guard.

**Rejected directions (extracted from the design-era journals; do NOT re-litigate unless the stated condition is met):**
- **Treap-only mark-to-market index** (one dynamic field per node) — per-node storage dominated gas (#949). Revisit only if per-node cost stops dominating AND one structure can serve additive NAV + running-max payout cheaply.
- **Single combined matrix for NAV + payout** — the two indexes have different algebra and rounding (#1015). Revisit only if the NAV and payout reads collapse to the same algebra and rounding direction.
- **Two-level liquidation skip-tree** (slack skip certificates) — bounded keeper scan chosen instead. Revisit only if bounded-scan keeper gas or the missed-liquidation rate proves unacceptable at scale.
- **Borrow-index / debt-overlay leverage** — built, then superseded by the floor model, then static-floor knockout. Revisit only if leverage must become a separately tradeable/fungible position.
- **Residual-paying liquidation** — knockout chosen; paying residuals adds a second claim liability. Revisit only if UX requires returning value to liquidated holders.
- **Inventory-aware mid shift** — aggregate drifts when the SVI surface moves + i64 overflow risk (#995, fully reverted #998). Revisit only if drift + overflow are solved AND skew is shown to help LPs.
- **Unpacking the order id** into a u64 sequence + `Table<u64, Order>` — the packed u256 id is the single self-authenticating term store and doubles as the liquidation sort key. Revisit only if the id cannot hold required terms.
- **Entry price (`entry_probability`/`leverage_rank`) in the order id** — `floor_shares` reconstructs everything needed. Revisit only if a flow needs the lossless entry price on-chain.
- **Folding `admin`/`AdminCap` into `registry`** — creates a Move import cycle (`registry → protocol_config → admin`); `admin` is deliberately a dependency-leaf capability module.
- **v1 scope exclusions:** double-sided range leverage, a fungible "2x beta" token, and utilization-based financing rates — excluded because exact strike-level liquidation indexing requires monotonic single-sided payoffs and history-independent floors.

**Follow-up state (verified 2026-07-02):**
- The old in-repo Rust Predict/oracle indexer crates were removed by #1098 because they were non-deployed parallel copies. Future Predict/propbook event decode work should start from the current Move event definitions; this repo no longer contains those service crates.
- Simulation-harness deploy-readiness (full localnet `run.sh` parity) is tracked in `packages/predict/predeploy/open-items.md`; the Python-only path runs green.

## Code Review Norms

- When the user asks for a review, read `.claude/rules/code-review.md` before producing findings and review the relevant diff in a code-review stance.
- For Move reviews, also read `.claude/rules/move.md` and `.claude/rules/unit-tests.md`.
- For a deep Predict smart-contract audit (predict + propbook + block_scholes_oracle + account), invoke the **`predict-audit`** skill (`.claude/skills/predict-audit/`): read its `primer.md` + the relevant `lenses/NN-*.md`, or launch `orchestrator.workflow.js` (lens fan-out), `ownership-walk.workflow.js` (per-module ownership/boundary/policy conformance, R1–R7), or `rule-sweep.workflow.js` (per-rule mechanical sweep).

## When Updating Repo Guidance

Update `CLAUDE.md` or `.claude/rules/*.md` when you learn something that should change future agent behavior, especially:

- newly discovered bug patterns
- test-writing rules
- package-specific gotchas
- build or tooling pitfalls
