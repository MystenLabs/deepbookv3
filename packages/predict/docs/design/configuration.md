# Configuration

Predict's tunable policy lives in a small set of configuration structs, a single shared `ProtocolConfig` object, and a `Registry`. This document describes how a parameter change reaches the code that consumes it, why some parameters are frozen into per-expiry objects at creation while others are read live, and which authority can change what. It documents the configuration mechanism; it is not a function reference. For the protocol mechanics these parameters govern, see [../overview.md](../overview.md), [../concepts/leverage-and-floor.md](../concepts/leverage-and-floor.md), and [../risks.md](../risks.md).

## Two layers: admin-tunable values vs. upgrade-required constants

Every protocol parameter falls into one of two layers.

- **Admin-tunable values** are stored in config structs and changed at runtime through `AdminCap`-gated entrypoints. Each such value has a stored field, a `default_*` seed, and an `assert_*` validation helper colocated in the `config_constants` module. The default seeds the field at object creation; thereafter the stored field — not the default — is the live protocol value.
- **Upgrade-required constants** live in the `constants` module as macros and are read directly by the logic that needs them. Changing one requires a package upgrade and a version bump. These encode structural facts and hard protocol invariants that are not meant to drift at an admin's discretion.

`config_constants` is the single home for the admin-tunable layer's defaults, bounds, and validation. The `min_*`/`max_*` bounds defined there are themselves upgrade-required constants: they fix the envelope an admin setter may move within, and changing a bound is a package upgrade. An admin can tune a value anywhere inside its envelope; an admin cannot widen the envelope.

Some structural constants are real and stable enough to state directly:

- **1e9 fixed-point scaling** (`float_scaling`): `500_000_000` is 50%, `1_000_000_000` is 100%. Prices, probabilities, fee rates, ratios, and benefit fractions all use this scale.
- **DUSDC settlement asset has 6 decimals**; contract quantities are 6-decimal quote units, so `1_000_000` is one contract.
- **Position lot size** and **minimum mint-time user principal** are fixed constants, not admin-tunable.
- **The discrete leverage set** is exactly {1x, 1.5x, 2x, 2.5x, 3x}, expressed as 1e9-scaled multipliers. The leverage *tiers* (which probabilities permit which leverage) and the leverage floor window are upgrade-required constants, not config fields.
- **Oracle tick sizes** must be positive multiples of a fixed granularity unit; the strike grid tick count per oracle is a constant.

## Three classes of configuration

Beyond the tunable/constant split, the admin-tunable layer is organized by *when and where* a value is read. There are three classes.

### (A) Template configs — snapshotted into per-expiry objects at creation

`ProtocolConfig` owns the current global *template* for three config structs:

| Template (on `ProtocolConfig`) | Snapshotted into | Governs |
| --- | --- | --- |
| `StrikeExposureConfig` | `StrikeExposure` (embedded on the per-expiry `ExpiryMarket`) | Terminal floor index, liquidation LTV, backing-buffer lambda (fraction of the disjoint-book gap reserved for early exits; 1.0 = fully summed reserve), fee policy (base/min fee, Bernoulli scaling, expiry-fee ramp window and max multiplier), all-in mint price bounds |
| `ExpiryCashConfig` | `ExpiryCash` (embedded on the per-expiry `ExpiryMarket`) | Trading-loss rebate rate (fraction of aggregate expiry trading fees reserved for loss rebates) |
| `MarketOracleConfig` | `MarketOracle` (per expiry) | Settlement-source freshness |

When `create_expiry_market` runs, the per-expiry object constructors snapshot each template into an independent copy stored inside the new object. From that moment the snapshot is decoupled from the template: a later admin change to a template updates the value future markets will snapshot, but it **does not** reach back through the template into any already-created market.

For the two **contract-term** templates — `StrikeExposureConfig` and `ExpiryCashConfig` — this is the full story: those snapshots have no per-object admin setter, so once a market is created its fee schedule, floor curve, liquidation LTV, and rebate rate are fixed for the life of the contract. Traders who minted under one set of terms keep those terms, and an admin cannot retroactively alter the economics of a live market. The contract-term template setters are named with `template` (for example `set_template_base_fee`, `set_template_liquidation_ltv`) to make this "future-only" effect explicit at the call site.

`MarketOracleConfig` is the deliberate exception. The template seeds the
settlement-freshness value future oracles start from via
`set_market_oracle_template_settlement_freshness_ms`, but the live copy on an
existing `MarketOracle` **remains admin-tunable** after creation through the
`AdminCap`-gated per-oracle setter `set_settlement_freshness_ms`. Settlement
freshness is a protocol-safety parameter, not a contract term, so it is allowed
to move on a live oracle.

```mermaid
flowchart LR
    subgraph PC[ProtocolConfig template]
      SEC[StrikeExposureConfig]
      ECC[ExpiryCashConfig]
      MOC[MarketOracleConfig]
    end
    PC -- snapshot at create_expiry_market --> M1[Expiry market #1 objects]
    PC -- snapshot at create_expiry_market --> M2[Expiry market #2 objects]
    admin[AdminCap set_template_*] -. future markets only .-> PC
    admin -. contract terms frozen .-x M1
    admin -- AdminCap per-oracle setters retune MarketOracle --> M1
```

The contract-term snapshots (`StrikeExposureConfig`, `ExpiryCashConfig`) are frozen by design: there is intentionally no admin path to re-template their economics on an existing market. Per-oracle settlement freshness is the only template-class value an admin can still move on a live market.

### (B) Live configs — read by their consumer at use time

Three config structs are read directly from `ProtocolConfig` at the moment they are needed, with no snapshot:

- **`PricingConfig`** — Pyth spot freshness, Block Scholes spot/forward freshness, and Block Scholes SVI freshness thresholds. `Pricing` reads these when resolving live probabilities for mint, redeem, and valuation. Because freshness is a protocol-safety concern rather than a contract term, every flow uses the current thresholds the instant it runs; an admin tightening freshness takes effect immediately and protocol-wide.
- **`EwmaConfig`** — the gas-price EWMA trade-penalty parameters (smoothing `alpha`, z-score threshold, per-unit penalty rate) plus an `enabled` master switch. The penalty is disabled by default. The evolving per-market `EwmaState` lives on `ExpiryMarket`; only the shared knobs live here, so a parameter change applies uniformly to every market's penalty computation.
- **`StakeConfig`** — the DEEP staking benefit curve thresholds (`lower_benefit_power`, `upper_benefit_power`). The benefit ratio rises linearly from 0 to half over `0..lower`, half to full over `lower..upper`, and caps at full above `upper`. That ratio scales the fixed maximum fee discount and applies directly as the loss-rebate share. Read live so that a benefit-curve change applies to all stakers at once.

The distinction from class (A) is deliberate: live configs govern protocol-wide safety and shared economics that should move atomically for everyone, whereas the contract-term template configs govern per-contract terms that must stay fixed for the contracts already written under them.

### (C) Global protocol knobs and per-expiry mint pause

`ProtocolConfig` also holds values that are neither snapshotted nor delegated to a sub-config struct.

**Global flow gates and scalars:**

- `trading_paused` — when true, blocks *new risk creation*. Exits, settlement cleanup, and valuation are intentionally not blocked by the trading pause; they are gated only by the valuation lock. `assert_trading_allowed` combines the not-paused check with the valuation lock.
- `valuation_in_progress` — a transaction-local lock held while a full-pool valuation is assembled. `begin_valuation`/`end_valuation` open and close it; while held, config mutations and new-risk flows abort. Most admin setters first assert the valuation lock is *not* in progress so that policy cannot shift mid-valuation.
- `protocol_reserve_profit_share` — the merged protocol-and-insurance reserve share used when aggregate expiry profit is materialized, in 1e9 scaling.
- `withdraw_fee_alpha` — the multiplier on the PLP withdrawal uncertainty-band fee, in 1e9 scaling. It scales the fee a withdrawing LP pays against the pool's aggregate live-valuation uncertainty band; the fee is retained in idle for remaining LPs (see [../concepts/liquidity-and-nav.md](../concepts/liquidity-and-nav.md)).
- `valuation_liquidation_budget` and `trade_liquidation_budget` — the total liquidation-candidate budgets checked before live pool valuation and before mint/redeem flows respectively. These bound how much liquidation work a single flow performs.

**Per-expiry mint pause:** `mint_paused` is a live `bool` field on each `ExpiryMarket`, read directly off the market object on the mint path. When true, new mints on that one expiry abort; the market's other flows (redeem, settlement) remain available. The admin sets and unsets it through `expiry_market::set_mint_paused` (version-gated), and a `PauseCap` holder can force it true one-way through `registry::pause_expiry_market_mint_pause_cap` (ungated, so the kill switch survives a version freeze).

The folded design: there are no standalone `fee_config`, `risk_config`, or `expiry_runtime_config` modules. The remaining scalar knobs live directly on `ProtocolConfig` with their defaults and bounds in `config_constants`. Readers should not look for those modules; this is the adopted shape.

## How a tunable value is validated

Every admin setter follows the same shape, which keeps creation-time and update-time validation on one path:

1. The setter asserts no valuation is in progress (for the global lock).
2. The new value is validated against its `assert_*` bound in `config_constants` (a single specific error code per value), so it lands inside the upgrade-required envelope.
3. Relational invariants that span more than one field are checked in the owning config setter, not in `config_constants`. For example, the all-in mint price setters require `min_ask_price < max_ask_price`, and the staking setter validates `lower` and `upper` together with `upper > 2 * lower` (which keeps the curve's `upper - lower` denominator positive and `lower > 0`).
4. The value is stored and a config event is emitted reflecting the new state.

The grouped EWMA setter still validates each field against its own
`config_constants` bound and then stores the updated policy together.

Defaults are applied only in the module that constructs the config; runtime logic treats config fields as plain numbers and never reads the `default_*` seeds. Bounds (`min_*`/`max_*`) may also be read directly by runtime logic when they intentionally serve as a hard floor or ceiling, but there are no config fields or getters for the bounds themselves.

Several bounds are tightened on purpose so a single bad admin call cannot quietly disable a safety mechanism: the expiry-fee max multiplier floors at 1x (the ramp can never reduce fees below base); the EWMA z-score threshold floors at one sigma and is capped so it cannot be set so high the penalty never fires; the EWMA penalty rate is capped to bound how punitive the surcharge can be. For the concrete defaults and envelopes, see the source `config_constants` module; this document deliberately does not hardcode numbers that drift.

## Registry tuning: tick size affects only future expiries

The `Registry` owns oracle/feed bindings and a per-feed admin-selected strike `tick_size`. `set_pyth_feed_tick_size` is `AdminCap`-gated and validated against the oracle-tick-size granularity. Like the contract-term template configs, this is a future-only knob: changing a feed's tick size affects the strike grid of expiry markets *created afterward* for that feed. Markets already created keep the tick size that was read into their grid at creation. Tick sizes can therefore be retuned per feed without disturbing live markets.

The `Registry` is also where trading feeds and incentive-asset oracle bindings live together, and it owns the protocol's version set (below).

## Versioning and pause governance

`Registry.allowed_versions` is the authoritative set of package versions permitted to mutate per-pool state. Per-pool objects (`ExpiryMarket`, `PoolVault`, `MarketOracle`, `PythSource`) each mirror this set and refresh it through permissionless `sync_*` entrypoints that copy the registry's current set into the target. The package-internal setters that write a mirror are not callable from outside the package, so a user-supplied version set can never reach a mirror by any other path. Version management entrypoints (`enable_version`, `disable_version`) are intentionally *not* version-gated, so an admin can recover from a fully disabled state; the set may never be left empty.

A `PauseCap` is a revocable emergency capability the admin mints into `Registry.allowed_pause_caps`. Its holders can disable a package version, force global `trading_paused = true`, and force `mint_paused = true` on a single expiry — all one-way. PauseCap operations bypass the version gate so the kill switch survives a version misconfiguration, but they can only *engage* protections; unpausing and re-enabling a version require the `AdminCap`.

## Governance: who can change what

| Authority | Can change |
| --- | --- |
| `AdminCap` (on `ProtocolConfig`) | All template values (future markets only), all live configs (`PricingConfig`, `EwmaConfig`, `StakeConfig`), `protocol_reserve_profit_share`, `withdraw_fee_alpha`, both liquidation budgets, global `trading_paused` |
| `AdminCap` (on an `ExpiryMarket`) | Per-expiry `mint_paused` (set and unset) |
| `AdminCap` (on a `MarketOracle`) | Live per-oracle settlement freshness; register/unregister oracle writer caps |
| `AdminCap` (on `Registry`) | Per-feed `tick_size` (future markets only), version enable/disable, PauseCap mint/revoke, market-lifecycle-cap mint/revoke, Pyth-source creation, incentive-asset bindings, incentive deposits |
| `PauseCap` (via `Registry`) | Disable a version, force global trading pause, force per-expiry mint pause — all one-way (engage only) |
| `MarketOracleWriterCap` (per oracle) | Push Block Scholes spot/forward and SVI data on a `MarketOracle` that has registered its ID. This is an oracle writer/operator capability, not a config-tuning route — per-oracle config bounds are `AdminCap`-gated above |
| `MarketLifecycleCap` (Registry allowlist) | Create expiry markets. A market-lifecycle capability with no oracle-write or config authority |
| Permissionless | `sync_*` version mirrors, and valuation and settlement-cleanup keeper flows (subject to the valuation lock, not the trading pause) |
| Upgrade only | Everything in the `constants` module: scaling, lot size, minimum principal, leverage set and tiers, leverage floor window, oracle granularity/grid, and every `min_*`/`max_*` bound in `config_constants` |

All admin setters route through their owning module: global protocol policy through `protocol_config`, per-object policy through the object's own module, and only registry-owned concerns (versions, pause caps, uniqueness, feed tick size, incentive bindings, multi-object creation) through `registry`. The embedded config struct setters themselves are package-internal; the public, capability-gated entrypoints are the only external surface for changing policy.

## Related reading

- [../concepts/pricing-and-oracles.md](../concepts/pricing-and-oracles.md) — how `PricingConfig` freshness thresholds and per-oracle settlement freshness enter live probability resolution and settlement.
- [../concepts/leverage-and-floor.md](../concepts/leverage-and-floor.md) — the terminal floor index, liquidation LTV, and leverage tiers that `StrikeExposureConfig` governs.
- [../risks.md](../risks.md) — operational and governance risk, including pause/version handling.
- [../overview.md](../overview.md) — object model and lifecycle of expiry markets, oracles, and the pool vault.
