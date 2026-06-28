# Predict audit — shared primer

Neutral, binding orientation for every audit lens. Read this in full before your lens file. It contains
NO risk opinions — only the protocol, scope, the **current** module map, the glossary, the empirical
toolbox, the discipline, and the report format. If you cannot read this file, stop and ask for it.

> This map reflects the **post-split** code (oracle extracted to `propbook` + `block_scholes_oracle`,
> math to `fixed_math`, custody to `account`). The older `.claude/predict-review/` files predate this
> rework — do not trust their module names. Trust the tree below; verify against current HEAD.

---

## What it is
A trader opens **leveraged binary (cash-or-nothing range digital) positions** on whether an oracle price
lands in a strike range at a fixed expiry. Positions are minted/redeemed in DUSDC against a per-expiry
`ExpiryMarket`; a strike-exposure engine tracks payout liability and NAV; an LP vault (PLP) funds the
backing and is priced against a full-pool NAV. Prices come from Pyth Lazer (signed spot) plus
operator-pushed Block-Scholes spot/forward/SVI surface data — both now served by the standalone
`propbook` package, which `predict` consumes but does not own.

## Scope (read-only)
- Audit the Move **source** of four packages: `packages/{predict,propbook,block_scholes_oracle,account}/sources/**`. Scope is FIXED to these four — do NOT broaden to deepbook core or other repo packages. Upgrade / object-layout migration correctness is out of scope (pre-deploy).
- IGNORE every `packages/*/build/**` (generated copies). Treat `tests/**` as reference (and as coverage
  evidence) unless your lens says otherwise.
- Never modify source. You may read dependency source (`deepbook`, `dusdc`, `pyth_lazer`, `fixed_math`)
  to understand cross-package trust, but every finding must be about the four in-scope packages.

## Actors / roles
- **Trader** — acts through `predict_account` (wraps an `account::Account` for DUSDC custody); authorizes
  either directly as owner (`account::Auth`) or via the account package's app-auth (`Permit<PredictApp>` +
  registry authorization → `generate_auth_as_app`). The old predict-side manager cap/proof model
  (`PredictTradeCap`/`DepositCap`/`WithdrawCap`/`PredictTradeProof`) was removed when custody moved to `account`.
- **LP** — supplies/withdraws DUSDC to the PLP vault (async request → privileged flush); may stake DEEP.
- **Keeper** — permissionless: triggers budgeted passive liquidation and pool syncs.
- **Builder** — earns attributed add-on fees via a `BuilderCode`.
- **Oracle operator** — pushes Block-Scholes spot/forward/SVI updates into the `propbook` feeds; settlement
  is **passive** (no operator settle entrypoint).
- **Admin** — holds `AdminCap`; tunes config, creates markets/sources, manages versions; can mint itself a
  `MarketLifecycleCap` for break-glass.
- **Market-lifecycle operator** — holds `MarketLifecycleCap` (revocable); starts the **privileged** cron flush.
- **Pause operator** — holds `PauseCap`; pauses trading/minting, disables versions.
- **Account admin** — holds `account::AccountAdminCap`; authorizes/deauthorizes apps (e.g. `PredictApp`) on the custody layer.

## Assets
DUSDC (settlement/custody for all trading + payouts), DEEP (staked for fee discounts / loss rebates; also a
donatable incentive), SUI (donatable incentive), PLP (LP vault share token).

## Module map (CURRENT)

### `predict` (31 modules — the protocol core)
- `registry/registry.move` — protocol root: version set, Pyth-feed/incentive indexes, object creation, pause-cap & lifecycle-cap allowlists, `create_expiry_market`.
- `registry/market_manager.move` — cadence-driven market deployment: per-underlying watermarks, cadence config, `next_deployable_market`, higher-rank slot reservation.
- `predict_account.move` — per-user account; DUSDC custody via an inner `account::Account`; positions, per-expiry summaries, DEEP stake mirror; authorization via `account::Auth` (owner) / app-auth (`Permit<PredictApp>` via `generate_auth_as_app`), not predict-side caps.
- `builder_code.move` — fee-attribution object; accrues + claims builder fees.
- `order.move` — packs immutable position terms (absolute boundary ticks, quantity, floor_shares, sequence) into a u256 order id; validates shape.
- `expiry_market.move` — per-expiry risk engine; mint / live redeem / settled redeem / passive liquidation / settlement / compaction state machine; routes DUSDC; produces per-expiry `current_nav`.
- `expiry_cash.move` — raw DUSDC custody arithmetic; enforces `cash_balance >= payout_liability + rebate_reserve`.
- `ewma.move` — gas-congestion surcharge ("EWMA penalty") added to trade fees.
- `constants.move` — upgrade-only constants/sentinels (version, scalings, `pos_inf_tick`, resolution period).
- `pricing/pricing.move` — the live pricing boundary: binds the market's underlying to current propbook feeds, pre-expiry live-pricing check, feed freshness, the pricing-safe surface envelope (forward>0, basis, |rho|<=1, sigma band), SVI variance + normal-CDF binary pricing; settlement read.
- `config/` — `protocol_config.move` (global admin knobs + trading-pause + valuation lock + per-expiry rows), `config_constants.move` (defaults + hard bounds + `assert_*` validators), and per-subsystem snapshot configs: `pricing_config`, `ewma_config`, `stake_config`, `expiry_cash_config`, `strike_exposure_config`.
- `capabilities/` — `admin.move` (singleton `AdminCap`), `market_lifecycle_cap.move` (revocable flush gate), `pause_cap.move` (versioned pause / per-pool mint pause).
- `plp/plp.move` — LP vault: idle DUSDC, PLP treasury, staked DEEP, per-expiry rebalancing, incentive streams, full-pool valuation (`PoolValuation` hot potato), the privileged flush.
- `plp/pool_accounting.move` — durable per-expiry sent/received flows, profit basis, loss watermarks, funding caps, `pending_protocol_profit` (D033 deferred-carry).
- `plp/lp_book.move` — async supply/withdraw request queues + FIFO drain at the frozen mark.
- `strike_exposure/strike_exposure.move` — exposure accounting engine for one strike grid (mint insert / partial-close / remove / settlement recompute; `strike_payout_tree::payout_terms` is the canonical bit-equal term evaluator).
- `strike_exposure/range_codec.move` — absolute-tick ⟷ raw conversion, settlement prefix, sentinels (`raw = tick * tick_size`; no centered grid, no boundary indices).
- `strike_exposure/index/strike_payout_tree.move` — payout-liability + max-live-backing index (treap; `walk_linear`).
- `strike_exposure/index/liquidation_book.move` — paged, priority-sorted liquidation candidate index + passive-watermark scan.
- `events/` — `order_events`, `vault_events`, `builder_code_events`, `config_events` (structs only).

### `propbook` (7 modules — the extracted oracle)
- `registry.move` — `OracleRegistry`: source/feed creation (`create_and_share_pyth_feed`, `create_and_share_block_scholes_{spot,forward,svi}_feed`), per-underlying/per-expiry feed binding + typed lookups.
- `feeds/pyth_feed.move` — Pyth Lazer spot ingestion (normalize, stale/future/zero gating) + exact-timestamp minute history used for **settlement**.
- `feeds/block_scholes_spot_feed.move`, `feeds/block_scholes_forward_feed.move`, `feeds/block_scholes_svi_feed.move` — the three split BS surface feeds (one object per (source, expiry) for forward/svi; spot is per-source). Store raw BS source fields; the pricing-safe envelope is enforced by the consumer in `predict::pricing`.
- `oracle_lane/oracle_lane.move` — generic per-lane observation store (latest + exact-timestamp inserts) shared by the feeds.
- `constants.move` — propbook constants/sentinels.

### `block_scholes_oracle` (1 module — the BS update payload)
- `update.move` — the Block-Scholes update struct family (`SpotUpdate`/`ForwardUpdate`/`SVIUpdate`, `SVIParams`) and constructors. **NOTE: a stub — values are operator-supplied, not signature-verified** (see settled D031 trust model; lens 03/08 trace what gates it).

### `account` (3 modules — extracted custody)
- `account.move` — `Account` object + `Auth` (owner/app kinds); stored-balance deposit/withdraw; `settle` at the wrapper address; app-auth via `Permit`.
- `account_registry.move` — `AccountRegistry` + `AccountAdminCap`; `authorize_app`/`deauthorize_app`; `generate_auth_as_app`.
- `account_events.move` — account event structs.

## Lifecycle (per expiry market)
`market_manager` cadence config → `create_expiry_market` (reads no live spot; absolute ticks snapshotted from cadence) → seed propbook Pyth + BS data for the emitted expiry → `mint` → live trade/redeem (partial or full close) → permissionless passive liquidation (budgeted, folded into mint/redeem/supply/withdraw) → **passive settlement** (terminal spot = the exact post-expiry Pyth print from propbook minute history; if absent, the market stays unsettled and live valuation aborts) → settled redeem → compaction (free storage). Full-pool valuation: a transaction-local `PoolValuation` snapshots active expiries, values each once under the valuation lock; the **privileged** flush prices PLP supply AND withdraw at one exact `current_nav` mark.

## Glossary (neutral)
absolute tick = strike unit; `raw = tick * tick_size`. `pos_inf_tick`/`neg_inf` = open-ended-range sentinels. floor_shares = the **static** deterministic floor `F` of a leveraged position (the LP-funded leverage portion); winner payout = `Q − F`. terminal vs live (backing) payout: under the static floor the winner's `Q - F` is exact at settlement, and the only pre-settlement conservatism is the aggregate disjoint-backing λ buffer (D030). payout_liability / settled_payout_liability = cash the market must back. rebate_reserve = reserve from collected-but-unresolved trading fees for loss rebates. EWMA penalty = gas-congestion fee surcharge. basis = forward/spot from BS pushes. SVI = volatility-surface parameterization for the binary tail. NAV = pool value pricing PLP shares; the flush mark is the **exact** `current_nav` (tree `walk_linear` − leveraged `correction_value`, floored), no conservative band. float_scaling = 1e9 fixed-point.

## Prior-awareness (mandatory)
Before raising anything, consult the settled-decision ledger and respect it:
- `.claude/predict-design/DECISION_JOURNAL.md` (D000–latest) and `HISTORY.md` — accepted/rejected; rejected entries carry don't-revisit conditions.
- `AGENTS.md` "Predict Rework — LANDED" + "Settled design decisions".
- `.claude/predict-design/ROUNDING_POLICY.md` — R1 liveness (dust never aborts; reserve ≥ payout by construction), R2 dust-to-protocol (user outflows round DOWN, reserves round UP/equal), R3 document direction.
A candidate matching a settled decision (e.g. D025 redeem-bound asymmetry, D026 u64 strike_quantity overflow ACCEPT, D030 backing floor+λ, D031 oracle guards REMOVED by design, D033 deferred-carry protocol reserve, exact `current_nav` no-band, privileged cron flush) is tagged with its D-id and downranked to Info — not raised as new.

## Empirical toolbox (lens 09 owns it; any lens may use Python)
`packages/predict/simulations/` is a real localnet + Python economic harness:
- `bash run.sh` — fresh **localnet**: runs the generated scenario against localnet AND a Python mirror, checks economic parity. **Localnet runs ONLY in the main loop** (heavy/long → trips the subagent watchdog).
- `bash run.sh --python-only` — long **Python** replay: exact-time economics, settlement, charts. Python is fast and **safe to run inside a subagent**.
- `python_indexes/` mirrors the Move `strike_payout_tree` + `liquidation_book`; `python_replay.py` mirrors mint admission / pricing / NAV. Reuse these to write **new adversarial scenarios** and property/fuzz checks (randomized mint/redeem/liquidate/supply/withdraw sequences asserting solvency, NAV supply/withdraw symmetry, rounding direction, no-underflow). The existing harness is a *parity* harness (one vault/market/manager, happy-path rows) — to find bugs you must author new stress scenarios, not just rerun it.
Write all temp sims/scripts to the session scratchpad, never into the package.

## Method — use your full toolset
Deep, long-running review. Do NOT do a single linear read-through.
- **Navigate exhaustively** with Grep/Glob: every call site, caller, constant use, cross-module/cross-package data flow before judging a function.
- **Fan out + adversarially verify.** A finding survives only if an independent check cannot refute it. (The orchestrator does this for you; a solo lens session should still self-refute.)
- **Use the compiler/sims as an oracle** — but only in the main loop (see Hard rules). A "this aborts" claim should be backed by a test or sim, not just prose.
- **Look things up** (web) when correctness depends on an external spec (SVI total variance, normal-CDF bounds, Pyth Lazer semantics, Sui object/PTB rules). Verify, don't guess.
- **Track your work** so a long session doesn't drop threads and your Coverage section is accurate.

## Report format (use verbatim so reports merge)
```
### [SEVERITY] Short title
- Location: file.move:line(s)
- Claim: the property violated / the issue
- Scenario: concrete who-does-what-in-what-order that triggers it
- Impact: fund-loss | liveness-brick | griefing-dos | correctness | cleanup-only
- Confidence: high | medium | low
- Settled-ref: D-id if this matches a settled decision, else none
- Recommendation: concrete fix direction
- Evidence: test/sim/grep/git fact that backs the claim (esp. for High/Critical)
```
Severity scale: Critical / High / Medium / Low / Info. End every report with (1) **Coverage** — what you
examined and what you did NOT; (2) **Top 3** — the three things to fix first.
