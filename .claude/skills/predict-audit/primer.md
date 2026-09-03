# Predict audit — shared primer

Neutral, binding orientation for every audit lens. Read this in full before your lens file. It contains
NO risk opinions — only the protocol, scope, the **current** module map, the glossary, the empirical
toolbox, the discipline, and the report format. If you cannot read this file, stop and ask for it.

> This map reflects the **post-split** code (oracle extracted to `propbook`, math to `fixed_math`,
> custody to `account`; Block Scholes data is signature-verified by the external `bs_oracle` package).
> The older `.claude/predict-review/` files predate this rework — do not trust their module names.
> Trust the tree below; verify against current HEAD.

---

## What it is
A trader opens **binary (cash-or-nothing range digital) positions** on whether an oracle price
lands in a strike range at a fixed expiry. Positions are minted/redeemed in DUSDC against a per-expiry
`ExpiryMarket`; a strike-exposure engine tracks payout liability and NAV; an LP vault (PLP) funds the
backing and is priced against a full-pool NAV. Prices come from Pyth Lazer (signed spot) plus
provider-signed Block Scholes spot/forward/SVI surface data — both now served by the standalone
`propbook` package, which `predict` consumes but does not own.

## Scope (read-only)
- Follow the fixed package scope and external trust-boundary treatment in [SKILL.md](./SKILL.md#packages-in-scope-all-move-source-read-only).
- Ignore every `packages/*/build/**` generated copy. Treat `tests/**` as reference and coverage evidence unless the lens says otherwise.
- Never modify source. Read dependency source only to understand an in-scope trust boundary, and report findings only against the skill's owned scope.

## Actors / roles
- **Trader** — acts through `predict_account` (wraps an `account::Account` for DUSDC custody); authorizes
  either directly as owner (`account::Auth`) or via the account package's app-auth (`Permit<PredictApp>` +
  registry authorization → `generate_auth_as_app`). The old predict-side manager cap/proof model
  (`PredictTradeCap`/`DepositCap`/`WithdrawCap`/`PredictTradeProof`) was removed when custody moved to `account`.
- **LP** — supplies/withdraws DUSDC to the PLP vault (async request → privileged flush).
- **Keeper** — permissionless: triggers settlement and pool syncs.
- **Builder** — earns attributed add-on fees via a `BuilderCode`.
- **Oracle operator** — pushes Block-Scholes spot/forward/SVI updates into the `propbook` feeds; settlement
  is **passive** (no operator settle entrypoint).
- **Admin** — holds `AdminCap`; tunes config, creates markets/sources, manages versions; can mint itself a
  `PoolValuationCap` for break-glass.
- **Market-lifecycle operator** — holds `MarketLifecycleCap` (revocable); creates expiry markets.
- **Pool-valuation operator** — holds `PoolValuationCap` (revocable); starts the **privileged** cron flush.
- **Pause operator** — holds `PauseCap`; pauses trading/minting, disables versions.
- **Account admin** — holds `account::AccountAdminCap`; authorizes/deauthorizes apps (e.g. `PredictApp`) on the custody layer.

## Assets
DUSDC (settlement/custody for all trading + payouts, and the sponsored fee-incentive donation), PLP (LP vault share token).

## Module map (CURRENT)

### `predict` (31 modules — the protocol core)
- `registry/registry.move` — protocol root: version set, Pyth-feed/incentive indexes, object creation, pause-cap, lifecycle-cap & pool-valuation-cap allowlists, `create_and_share_expiry_market`.
- `registry/market_manager.move` — cadence-driven market deployment: per-underlying watermarks, cadence config, `next_deployable_market`, higher-rank slot reservation.
- `predict_account.move` — per-user account; DUSDC custody via an inner `account::Account`; positions and builder-code attribution; authorization via `account::Auth` (owner) / app-auth (`Permit<PredictApp>` via `generate_auth_as_app`), not predict-side caps.
- `builder_code.move` — fee-attribution object; accrues + claims builder fees.
- `order.move` — packs immutable position terms (absolute boundary ticks, quantity, sequence) into a u256 order id (132 dense bits); validates shape.
- `expiry_market.move` — per-expiry risk engine; mint / live redeem / settled redeem / settlement / compaction state machine; routes DUSDC; produces per-expiry `current_nav`.
- `expiry_cash.move` — raw DUSDC custody arithmetic; enforces `cash_balance >= payout_liability + inventory_impact_reserve`.
- `ewma.move` — gas-congestion surcharge ("EWMA penalty") added to trade fees.
- `constants.move` — upgrade-only constants/sentinels (version, scalings, `pos_inf_tick`, resolution period).
- `pricing/pricing.move` — the live pricing boundary: binds the market's underlying to current propbook feeds, pre-expiry live-pricing check, feed freshness, the pricing-safe surface envelope (forward>0, basis, |rho|<=1, sigma band), SVI variance + normal-CDF binary pricing; settlement read.
- `config/` — `protocol_config.move` (global admin knobs + trading-pause + valuation lock + per-expiry rows), `config_constants.move` (defaults + hard bounds + `assert_*` validators), and per-subsystem snapshot configs: `pricing_config`, `ewma_config`, `strike_exposure_config`.
- `capabilities/` — `admin.move` (singleton `AdminCap`), `market_lifecycle_cap.move` (revocable market-creation gate), `pool_valuation_cap.move` (revocable flush gate), `pause_cap.move` (versioned pause / per-pool mint pause).
- `plp/plp.move` — LP vault: idle DUSDC, PLP treasury, per-expiry rebalancing, incentive streams, full-pool valuation (`PoolValuation` hot potato), the privileged flush.
- `plp/pool_accounting.move` — durable per-expiry sent/received flows, profit basis, loss watermarks, funding caps, `pending_protocol_profit` (D033 deferred-carry).
- `plp/lp_book.move` — async supply/withdraw request queues + FIFO drain at the frozen mark.
- `strike_exposure/strike_exposure.move` — exposure accounting engine for one strike grid (mint insert / partial-close / remove / settlement recompute; the packed order id is the canonical bit-equal source of the stored quantity atom).
- `strike_exposure/range_codec.move` — absolute-tick ⟷ raw conversion, settlement prefix, sentinels (`raw = tick * tick_size`; no centered grid, no boundary indices).
- `strike_exposure/index/strike_payout_tree.move` — payout-liability + max-live-backing index (treap; `walk_linear`).
- `events/` — `order_events`, `vault_events`, `builder_code_events`, `config_events` (structs only).

### `propbook` (6 modules — the extracted oracle)
- `registry.move` — `OracleRegistry`: Pyth feed creation + binding (`create_and_share_pyth_feed`, `bind_pyth_to_underlying`) and the admin-gated `create_and_share_block_scholes_stores`, which creates one underlying's value/SVI store pair canonical-at-creation (no separate BS bind step); typed canonical lookups.
- `feeds/pyth_feed.move` — Pyth Lazer spot ingestion (normalize, stale/future/zero gating) + exact-timestamp minute history used for **settlement**.
- `feeds/block_scholes_sid.move` — derives the Block Scholes series id (version | kind | underlying | value scale | expiry) from a slot's own identity; the shared client/package sid contract. Reads derive the id they want — nothing accepts one from a caller — so a valid observation can only land in the slot it was signed for.
- `feeds/block_scholes_store.move` — the two per-underlying stores (`BlockScholesValueStore` = spot + forwards, one signed value batch; `BlockScholesSVIStore` = SVI sets, its own signed batch), keyed by signed sid. Writes enter only through `apply_{value,svi}_batch`, which take the verifier's hot-potato batch by value; per-series ordering is lexicographic on (model time, envelope time) with an envelope floor — the stored publish time never regresses, because consumers gate freshness and anchor the SVI roll-down on it — so the stored observation is relayer-submission-order-independent for any monotone provider stream (a regressed provider stream is first-writer-wins by design); malformed timestamps (model after envelope), foreign, stale, envelope-regressing, and duplicate entries are skipped, never aborted. Values stay raw `u128` at provider scale — the pricing-safe envelope is enforced by the consumer in `predict::pricing`.
- `oracle_lane/oracle_lane.move` — generic per-lane observation store (latest + exact-timestamp inserts) used by the Pyth feed.
- `constants.move` — propbook constants/sentinels.

### External dependency: `bs_oracle` (Block Scholes' signature verifier — trust boundary, not audited surface)
- Block Scholes publishes and owns this package (git-pinned dep; linked on testnet via `dep-replacements`, never republished — a republish would change the `type_name::original_id` domain separator and reject every provider signature). `verify::verify_and_create_{value,svi}_batch` checks a secp256k1/keccak signature against the shared `SignerRegistry` and mints hot-potato `ValueBatch`/`SviBatch` — holding one IS the proof of a valid provider signature, so the relayer that lands it is untrusted by construction. Read it for trust-boundary reasoning (lens 03/08); findings about its internals belong to the provider.

### `account` (3 modules — extracted custody)
- `account.move` — `Account` object + `Auth` (owner/app kinds); stored-balance deposit/withdraw; `settle` at the wrapper address; app-auth via `Permit`.
- `account_registry.move` — `AccountRegistry` + `AccountAdminCap`; `authorize_app`/`deauthorize_app`; `generate_auth_as_app`.
- `account_events.move` — account event structs.

## Lifecycle (per expiry market)
`market_manager` cadence config → `create_and_share_expiry_market` (reads no live spot; absolute ticks snapshotted from cadence) → seed propbook Pyth + BS data for the emitted expiry → `mint` → live trade/redeem (partial or full close) → **passive settlement** (terminal spot = the exact post-expiry Pyth print from propbook minute history; if absent, the market stays unsettled and live valuation aborts) → settled redeem → compaction (free storage). Full-pool valuation: a transaction-local `PoolValuation` snapshots active expiries, values each once under the valuation lock; the **privileged** flush prices PLP supply AND withdraw at one exact `current_nav` mark.

## Glossary (neutral)
absolute tick = strike unit; `raw = tick * tick_size`. `pos_inf_tick`/`neg_inf` = open-ended-range sentinels. winner payout = the full `Q` (leverage was removed 2026-08-14; there is no floor). The only pre-settlement conservatism is the aggregate disjoint-backing λ buffer (D030). payout_liability / settled_payout_liability = cash the market must back. inventory_impact_reserve = isolated escrow of collected inventory-impact charges. EWMA penalty = gas-congestion fee surcharge. basis = forward/spot from BS pushes. SVI = volatility-surface parameterization for the binary tail. NAV = pool value pricing PLP shares; the flush mark is the **exact** `current_nav` (tree `walk_linear`, floored), no conservative band. float_scaling = 1e9 fixed-point.

## Prior-awareness (mandatory)
Before raising anything, read and apply the [Predict development-system authority order](../../../packages/predict/predeploy/README.md#authority-order). Do not duplicate an existing open item or re-litigate a rejected direction unless its recorded revisit condition is met.
A candidate matching a settled decision or policy is tagged with its owning D-id, RP-id, or committed-policy reference and downranked to Info rather than raised as new.
Prior-awareness cuts BOTH ways: a register or ledger entry that no longer matches HEAD (the pinning test is gone, the code stopped implementing the recorded response, `docs/risks.md` claims behavior the code doesn't have) is NOT protection — that drift is itself a reportable finding, at the severity of the underlying gap.

## Empirical toolbox (lens 09 owns it; any lens may use Python)
`packages/predict/simulations/` is a real localnet + Python economic harness:
- `cd packages/predict && python3 -m harness parity --source /path/to/scenario_dataset.csv --max-rows N` — fresh **localnet** plus the independent Python mirror and exact economic parity comparison. **Localnet runs only in the main loop**.
- `python_replay.py` and ad-hoc Python simulations written to the scratchpad are subagent-safe when they do not start a localnet.
- `python_indexes/` mirrors the Move `strike_payout_tree`; `python_replay.py` mirrors mint admission / pricing / NAV. NOTE: both still model the removed leverage economics and have not been migrated — treat them as stale until they are. Reuse them to write **new adversarial scenarios** and property/fuzz checks (randomized mint/redeem/supply/withdraw sequences asserting solvency, NAV supply/withdraw symmetry, rounding direction, no-underflow). The existing harness is a *parity* harness (one vault/market/manager, happy-path rows) — to find bugs you must author new stress scenarios, not just rerun it.
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
