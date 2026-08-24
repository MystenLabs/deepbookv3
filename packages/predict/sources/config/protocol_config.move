// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Protocol-wide configuration and flow gates for Predict.
///
/// This shared object owns the admin-tunable config structs, the trading pause
/// gate, the protocol-wide emergency freeze, and the full-pool valuation
/// in-flight state (flag + flush ordinal, held across the transactions a flush
/// spans; keeper/config flows gate on it, trading flows read it to stamp their
/// deltas). Flow modules decide which gates apply before they mutate expiry,
/// oracle, pool, or account state.
module deepbook_predict::protocol_config;

use deepbook_predict::{
    admin::AdminCap,
    config_constants,
    config_events,
    constants,
    ewma_config::{Self, EwmaConfig},
    pricing_config::{Self, PricingConfig},
    strike_exposure_config::{Self, StrikeExposureConfig}
};
use sui::clock::Clock;

const ETradingPaused: u64 = 0;
const EValuationInProgress: u64 = 1;
const EValuationNotInProgress: u64 = 2;
const EPackageVersionDisabled: u64 = 3;
const EVersionWatermarkNotAdvanced: u64 = 4;
const EProtocolFrozen: u64 = 5;

/// Shared protocol policy and config state.
public struct ProtocolConfig has key {
    id: UID,
    pricing_config: PricingConfig,
    /// Merged protocol + insurance reserve share of materialized terminal profit,
    /// in FLOAT_SCALING. The complement accrues to LPs.
    protocol_reserve_profit_share: u64,
    /// Portion of a referred mint's trader-paid trading fee and congestion
    /// surcharge routed to the referrer, in FLOAT_SCALING.
    referral_fee_rate: u64,
    /// Fee charged on an executed PLP supply fill, in FLOAT_SCALING, deducted from
    /// the DUSDC taken in before shares are priced. Ships at zero — a deposit
    /// dilutes the pool's risk per dollar rather than concentrating it, so it is
    /// not taxed; the knob exists to keep that reversible.
    plp_supply_fee_rate: u64,
    /// Fee charged on an executed PLP withdraw fill, in FLOAT_SCALING, withheld
    /// from the marked payout. Retained by the pool, so it accrues to the holders
    /// who stay. Both rates are read once per flush into the frozen mark, so every
    /// fill in one flush is charged the same pair.
    plp_withdraw_fee_rate: u64,
    /// Frozen-mark attempts a queued LP supply/withdraw request gets before the
    /// protocol cancels and refunds it. `1` (the default) is fill-or-kill; above
    /// that a missing request rests at the queue head and stops that queue for the
    /// flush, so this is an LP-queue liveness knob (RP-12).
    lp_request_limit_flush_attempts: u64,
    /// Ceiling on LP-attributable pool value that queued supplies may raise the pool
    /// to, enforced at the flush against the frozen mark. Defaults to `u64::MAX`, so
    /// the pool is uncapped until an operator sets a figure (RP-23).
    max_lp_pool_value: u64,
    /// How long a started full-pool valuation may stay in flight before
    /// `plp::abort_valuation` becomes permissionless. A stalled flush blocks only
    /// LP queue fills and the flush-set markets' settlement — trading continues —
    /// so this bounds LP-fill latency and is tuned alongside flush cadence (RP-29).
    max_valuation_window_ms: u64,
    /// Range operations one market's valuation delta log may record before trades
    /// on that market abort for the rest of its wait; prices a bounded per-market
    /// trade freeze against `value_expiry`'s compute headroom (one extra pricer
    /// evaluation per logged boundary).
    max_valuation_log_ops: u64,
    strike_exposure_template_config: StrikeExposureConfig,
    ewma_config: EwmaConfig,
    /// Minimum package version permitted to run version-gated flows. Monotonic;
    /// `bump_version_watermark` advances it to the running `current_version!()`,
    /// retiring older versions. A running version below this floor is dead
    /// (`assert_version`). `current_version!()` stays the upgrade-required code
    /// constant; this is the runtime floor.
    version_watermark: u64,
    /// Blocks new risk creation while true.
    trading_paused: bool,
    /// Emergency hard stop. While true, `assert_version` aborts, halting every
    /// version-gated flow (mint, redeem, settlement, valuation, LP supply/withdraw,
    /// admin config) — the same blast radius as a version-disable, but reversible
    /// without a package upgrade. Force-on via `PauseCap`; cleared by `AdminCap`.
    /// Account-package custody withdrawals and builder-fee claims are ungated and
    /// stay available (already-earned funds).
    frozen: bool,
    /// True for the whole duration of a full-pool valuation, across every
    /// transaction it spans. Keeper cash flows, market lifecycle, and config
    /// mutations gate on it; trading flows do NOT — they read it (with
    /// `flush_seq`) to decide whether a market's valuation stamp is current, and
    /// record their book deltas for the flush to cancel out (see `plp`).
    valuation_in_progress: bool,
    /// Monotonic flush ordinal, bumped by `begin_valuation`. A market's valuation
    /// stamp names the flush that made it; a stamp whose ordinal is not the
    /// current one — or held while no valuation is in flight — is stale and is
    /// lazily discarded by the next trade, so aborting a flush never has to visit
    /// its stamped markets.
    flush_seq: u64,
}

// === Public Functions ===

/// Return the protocol config object ID for external discovery and PTB construction.
public fun id(config: &ProtocolConfig): ID {
    config.id.to_inner()
}

/// Return the global trading-pause state for SDK and devInspect reads.
public fun trading_paused(config: &ProtocolConfig): bool {
    config.trading_paused
}

/// Return the global protocol-freeze state for SDK and devInspect reads.
public fun frozen(config: &ProtocolConfig): bool {
    config.frozen
}

/// Return whether a full-pool valuation is in flight, for SDK and devInspect
/// reads. The flush spans transactions, so "in flight" is an observable state: a
/// keeper reads it to notice a flush it must finish or discard, and an integrator
/// reads it to explain a gated keeper/config transaction. Trading is not gated on
/// it.
public fun valuation_in_progress(config: &ProtocolConfig): bool {
    config.valuation_in_progress
}

/// Return the live referral fee rate for SDK and devInspect reads.
public fun referral_fee_rate(config: &ProtocolConfig): u64 {
    config.referral_fee_rate
}

/// Set the base fee multiplier snapshotted by newly created expiry markets.
public fun set_template_base_fee(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    fee: u64,
    clock: &Clock,
) {
    config.assert_version();
    config.strike_exposure_template_config.set_base_fee(fee);
    config_events::emit_strike_exposure_template_config_updated(
        &config.strike_exposure_template_config,
        clock.timestamp_ms(),
    );
}

/// Set the minimum fee floor snapshotted by newly created expiry markets.
public fun set_template_min_fee(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    fee: u64,
    clock: &Clock,
) {
    config.assert_version();
    config.strike_exposure_template_config.set_min_fee(fee);
    config_events::emit_strike_exposure_template_config_updated(
        &config.strike_exposure_template_config,
        clock.timestamp_ms(),
    );
}

/// Set the expiry-fee ramp window snapshotted by newly created expiry markets.
public fun set_template_expiry_fee_window_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
    clock: &Clock,
) {
    config.assert_version();
    config.strike_exposure_template_config.set_expiry_fee_window_ms(value);
    config_events::emit_strike_exposure_template_config_updated(
        &config.strike_exposure_template_config,
        clock.timestamp_ms(),
    );
}

/// Set the expiry-fee max multiplier snapshotted by newly created expiry markets.
public fun set_template_expiry_fee_max_multiplier(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
    clock: &Clock,
) {
    config.assert_version();
    config.strike_exposure_template_config.set_expiry_fee_max_multiplier(value);
    config_events::emit_strike_exposure_template_config_updated(
        &config.strike_exposure_template_config,
        clock.timestamp_ms(),
    );
}

/// Set the backing-buffer lambda snapshotted by newly created expiry markets.
public fun set_template_backing_buffer_lambda(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
    clock: &Clock,
) {
    config.assert_version();
    config.strike_exposure_template_config.set_backing_buffer_lambda(value);
    config_events::emit_strike_exposure_template_config_updated(
        &config.strike_exposure_template_config,
        clock.timestamp_ms(),
    );
}

/// Set the maximum marginal inventory-impact rate snapshotted by newly created
/// expiry markets. `0` (the default) disables both charges and rebates.
public fun set_template_inventory_impact_max_rate(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
    clock: &Clock,
) {
    config.assert_version();
    config.strike_exposure_template_config.set_inventory_impact_max_rate(value);
    config_events::emit_strike_exposure_template_config_updated(
        &config.strike_exposure_template_config,
        clock.timestamp_ms(),
    );
}

/// Set the minimum raw entry probability snapshotted by newly created expiry markets.
public fun set_template_min_entry_probability(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
    clock: &Clock,
) {
    config.assert_version();
    config.strike_exposure_template_config.set_min_entry_probability(value);
    config_events::emit_strike_exposure_template_config_updated(
        &config.strike_exposure_template_config,
        clock.timestamp_ms(),
    );
}

/// Set the maximum raw entry probability snapshotted by newly created expiry markets.
public fun set_template_max_entry_probability(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
    clock: &Clock,
) {
    config.assert_version();
    config.strike_exposure_template_config.set_max_entry_probability(value);
    config_events::emit_strike_exposure_template_config_updated(
        &config.strike_exposure_template_config,
        clock.timestamp_ms(),
    );
}

/// Select which source the live forward is built from: `true` carries the Block
/// Scholes basis on a fresh Pyth spot, `false` uses the Block Scholes forward
/// directly. Locked during valuation so one flush marks every market on one formula.
public fun set_use_pyth_spot_for_forward(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    enabled: bool,
    clock: &Clock,
) {
    config.assert_version();
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_use_pyth_spot_for_forward(enabled);
    config_events::emit_pricing_config_updated(&config.pricing_config, clock.timestamp_ms());
}

/// Set the live Pyth spot freshness threshold.
public fun set_pyth_spot_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
    clock: &Clock,
) {
    config.assert_version();
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_pyth_spot_freshness_ms(value);
    config_events::emit_pricing_config_updated(&config.pricing_config, clock.timestamp_ms());
}

/// Set the live Block Scholes spot/forward freshness threshold.
public fun set_block_scholes_price_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
    clock: &Clock,
) {
    config.assert_version();
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_block_scholes_price_freshness_ms(value);
    config_events::emit_pricing_config_updated(&config.pricing_config, clock.timestamp_ms());
}

/// Set the live Block Scholes SVI freshness threshold.
public fun set_block_scholes_svi_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
    clock: &Clock,
) {
    config.assert_version();
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_block_scholes_svi_freshness_ms(value);
    config_events::emit_pricing_config_updated(&config.pricing_config, clock.timestamp_ms());
}

/// Set how many frozen-mark attempts a queued LP request gets before it is
/// cancelled and refunded. `1` is fill-or-kill. Raising it lets a request rest at
/// the head across flushes, which stops that queue each time it misses — see RP-12
/// for the liveness cost that buys.
public fun set_lp_request_limit_flush_attempts(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    attempts: u64,
) {
    config.assert_version();
    // The flush reads this value mid-PTB; refuse to move it under a valuation in
    // flight, as the other setters a flush reads from do.
    config.assert_not_valuation_in_progress();
    config_constants::assert_lp_request_limit_flush_attempts(attempts);
    config.lp_request_limit_flush_attempts = attempts;
}

/// Set how long a started full-pool valuation may stay in flight before anyone may
/// discard it. A stalled flush costs LP-fill latency (and settlement latency for
/// its own market set), not a trading pause, so this is an operator liveness knob:
/// too short and a legitimate long flush can be discarded from under the keeper,
/// too long and an abandoned one delays queued LP fills for that duration. See
/// RP-29.
public fun set_max_valuation_window_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    window_ms: u64,
) {
    config.assert_version();
    // The deadline is read against a flush already in flight; refuse to move it
    // under one, so a started flush cannot have its escape hatch shifted.
    config.assert_not_valuation_in_progress();
    config_constants::assert_max_valuation_window_ms(window_ms);
    config.max_valuation_window_ms = window_ms;
}

/// Set how many range operations one market's valuation delta log may record
/// while it awaits its `value_expiry`. Deliberately NOT gated on the valuation
/// flag: raising the cap mid-flush is the operator's live remedy when a hot
/// market fills its log under a stalled keeper, and each logged boundary only
/// adds compute (one pricer evaluation) to that market's own valuation
/// transaction.
public fun set_max_valuation_log_ops(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    log_ops: u64,
) {
    config.assert_version();
    config_constants::assert_max_valuation_log_ops(log_ops);
    config.max_valuation_log_ops = log_ops;
}

/// Set the ceiling on LP-attributable pool value that queued supplies may raise the
/// pool to. A supply that would carry the pool past it is filled up to the cap at the
/// flush and its remainder stays queued;
/// withdrawals and already-issued PLP are unaffected, so lowering this below current
/// pool value closes the pool to new capital rather than forcing anyone out.
public fun set_max_lp_pool_value(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    max_pool_value: u64,
) {
    config.assert_version();
    // The flush reads this mid-PTB, like the attempt count.
    config.assert_not_valuation_in_progress();
    config_constants::assert_max_lp_pool_value(max_pool_value);
    config.max_lp_pool_value = max_pool_value;
}

/// Set the EWMA gas-price penalty parameters.
public fun set_ewma_params(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    alpha: u64,
    z_score_threshold: u64,
    penalty_rate: u64,
    clock: &Clock,
) {
    config.assert_version();
    config.ewma_config.set_params(alpha, z_score_threshold, penalty_rate);
    config_events::emit_ewma_config_updated(&config.ewma_config, clock.timestamp_ms());
}

/// Enable or disable the EWMA gas-price penalty.
public fun set_ewma_enabled(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    enabled: bool,
    clock: &Clock,
) {
    config.assert_version();
    config.ewma_config.set_enabled(enabled);
    config_events::emit_ewma_config_updated(&config.ewma_config, clock.timestamp_ms());
}

/// Set whether trading is paused.
public fun set_trading_paused(config: &mut ProtocolConfig, _admin_cap: &AdminCap, paused: bool) {
    config.assert_version();
    config.set_trading_paused_internal(paused);
}

/// Set the protocol-wide emergency freeze.
///
/// Intentionally NOT version-gated, unlike every other admin setter: the freeze
/// gate lives inside `assert_version`, so routing this through it would make an
/// engaged freeze unclearable without a package upgrade — defeating the point.
public fun set_frozen(config: &mut ProtocolConfig, _admin_cap: &AdminCap, frozen: bool) {
    config.set_frozen_internal(frozen);
}

/// Advance the version floor to this package's compiled-in `current_version!()`.
///
/// The floor cannot be set above the executing package's version. This function
/// is ungated so an upgraded package can retire older versions; it aborts unless
/// the executing version is strictly greater than the existing floor.
public fun bump_version_watermark(config: &mut ProtocolConfig, _admin_cap: &AdminCap) {
    let version = constants::current_version!();
    assert!(version > config.version_watermark, EVersionWatermarkNotAdvanced);
    config.version_watermark = version;
}

/// Set the protocol reserve profit share used when materializing aggregate
/// expiry profit. Admin-gated; validated against its config-constants envelope.
public fun set_protocol_reserve_profit_share(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    protocol_reserve_profit_share: u64,
) {
    config.assert_version();
    config.assert_not_valuation_in_progress();
    config_constants::assert_protocol_reserve_profit_share(protocol_reserve_profit_share);
    config.protocol_reserve_profit_share = protocol_reserve_profit_share;
}

/// Set the portion of referred mint fees routed to the referrer. The new rate
/// applies to subsequent mints without changing their all-in account withdrawal.
public fun set_referral_fee_rate(config: &mut ProtocolConfig, _admin_cap: &AdminCap, rate: u64) {
    config.assert_version();
    config_constants::assert_referral_fee_rate(rate);
    config.referral_fee_rate = rate;
}

/// Set the fee charged on executed PLP supply fills. Admin-gated and validated
/// against its config-constants envelope. Locked during valuation so the rate a
/// flush froze into its mark cannot change midway through that flush.
public fun set_plp_supply_fee_rate(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    rate: u64,
    clock: &Clock,
) {
    config.assert_version();
    config.assert_not_valuation_in_progress();
    config_constants::assert_plp_supply_fee_rate(rate);
    config.plp_supply_fee_rate = rate;
    config_events::emit_plp_fee_rates_updated(
        config.plp_supply_fee_rate,
        config.plp_withdraw_fee_rate,
        clock.timestamp_ms(),
    );
}

/// Set the fee charged on executed PLP withdraw fills. Same gating as the supply
/// leg; the two are independent so the exit charge can move without taxing entry.
public fun set_plp_withdraw_fee_rate(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    rate: u64,
    clock: &Clock,
) {
    config.assert_version();
    config.assert_not_valuation_in_progress();
    config_constants::assert_plp_withdraw_fee_rate(rate);
    config.plp_withdraw_fee_rate = rate;
    config_events::emit_plp_fee_rates_updated(
        config.plp_supply_fee_rate,
        config.plp_withdraw_fee_rate,
        clock.timestamp_ms(),
    );
}

// === Public-Package Functions ===

public(package) fun pricing_config(config: &ProtocolConfig): &PricingConfig {
    &config.pricing_config
}

public(package) fun plp_supply_fee_rate(config: &ProtocolConfig): u64 {
    config.plp_supply_fee_rate
}

public(package) fun plp_withdraw_fee_rate(config: &ProtocolConfig): u64 {
    config.plp_withdraw_fee_rate
}

public(package) fun protocol_reserve_profit_share(config: &ProtocolConfig): u64 {
    config.protocol_reserve_profit_share
}

public(package) fun lp_request_limit_flush_attempts(config: &ProtocolConfig): u64 {
    config.lp_request_limit_flush_attempts
}

public(package) fun max_lp_pool_value(config: &ProtocolConfig): u64 {
    config.max_lp_pool_value
}

public(package) fun max_valuation_window_ms(config: &ProtocolConfig): u64 {
    config.max_valuation_window_ms
}

public(package) fun max_valuation_log_ops(config: &ProtocolConfig): u64 {
    config.max_valuation_log_ops
}

public(package) fun current_flush_seq(config: &ProtocolConfig): u64 {
    config.flush_seq
}

/// True iff a valuation stamp minted under `stamp_seq` belongs to the flush that
/// is in flight right now. False for a stale stamp (an aborted or completed
/// flush's leftovers) and when no flush is in flight — the caller lazily discards
/// the stamp in those cases.
public(package) fun is_current_flush(config: &ProtocolConfig, stamp_seq: u64): bool {
    config.valuation_in_progress && config.flush_seq == stamp_seq
}

public(package) fun strike_exposure_template_config(
    config: &ProtocolConfig,
): &StrikeExposureConfig {
    &config.strike_exposure_template_config
}

public(package) fun strike_exposure_config_snapshot(config: &ProtocolConfig): StrikeExposureConfig {
    strike_exposure_config::snapshot(&config.strike_exposure_template_config)
}

public(package) fun ewma_config(config: &ProtocolConfig): &EwmaConfig {
    &config.ewma_config
}

/// Abort unless the protocol is operational: not emergency-frozen, and the
/// running package version is at or above the watermark floor.
///
/// Version-gated flows thread the shared `ProtocolConfig` through this check, so
/// the freeze here reaches every one of them.
public(package) fun assert_version(config: &ProtocolConfig) {
    assert!(!config.frozen, EProtocolFrozen);
    assert!(constants::current_version!() >= config.version_watermark, EPackageVersionDisabled);
}

/// Abort unless trading mutations are currently allowed.
///
/// Intentionally omits the package-version gate: callers assert the version
/// separately via `assert_version` when the flow is version-gated.
public(package) fun assert_trading_allowed(config: &ProtocolConfig) {
    config.assert_not_trading_paused();
}

/// Abort unless a valuation lock is currently active.
public(package) fun assert_valuation_in_progress(config: &ProtocolConfig) {
    assert!(config.valuation_in_progress, EValuationNotInProgress);
}

/// Abort unless no valuation lock is currently active.
public(package) fun assert_not_valuation_in_progress(config: &ProtocolConfig) {
    assert!(!config.valuation_in_progress, EValuationInProgress);
}

/// Create and share the protocol-wide configuration object.
public(package) fun create_and_share(ctx: &mut TxContext): ID {
    let config = new(ctx);
    let id = config.id();
    transfer::share_object(config);
    id
}

/// Force `trading_paused = true` without admin authority. Reserved for
/// `PauseCap` holders going through the registry; cannot be used to unpause.
public(package) fun pause_trading(config: &mut ProtocolConfig) {
    config.set_trading_paused_internal(true);
}

/// Force `frozen = true` without admin authority. Reserved for `PauseCap`
/// holders going through the registry; cannot be used to lift the freeze.
public(package) fun freeze_protocol(config: &mut ProtocolConfig) {
    config.set_frozen_internal(true);
}

/// Begin a full-pool valuation: engage the in-flight flag for the flush's whole
/// multi-transaction span and mint its ordinal. Bumping `flush_seq` here is what
/// invalidates every stamp a previous flush left behind, so neither completion
/// nor abort ever needs to visit stamped markets.
public(package) fun begin_valuation(config: &mut ProtocolConfig) {
    config.assert_not_valuation_in_progress();
    config.flush_seq = config.flush_seq + 1;
    config.valuation_in_progress = true;
}

/// End a full-pool valuation (completion and abort both land here). Stamps naming
/// this flush go stale the moment the flag drops.
public(package) fun end_valuation(config: &mut ProtocolConfig) {
    config.assert_valuation_in_progress();
    config.valuation_in_progress = false;
}

fun set_trading_paused_internal(config: &mut ProtocolConfig, paused: bool) {
    config.trading_paused = paused;
    config_events::emit_trading_paused_updated(config.id(), paused);
}

fun set_frozen_internal(config: &mut ProtocolConfig, frozen: bool) {
    config.frozen = frozen;
    config_events::emit_protocol_frozen_updated(config.id(), frozen);
}

/// Abort unless trading is not paused.
fun assert_not_trading_paused(config: &ProtocolConfig) {
    assert!(!config.trading_paused, ETradingPaused);
}

fun new(ctx: &mut TxContext): ProtocolConfig {
    ProtocolConfig {
        id: object::new(ctx),
        pricing_config: pricing_config::new(),
        protocol_reserve_profit_share: config_constants::default_protocol_reserve_profit_share!(),
        referral_fee_rate: config_constants::default_referral_fee_rate!(),
        plp_supply_fee_rate: config_constants::default_plp_supply_fee_rate!(),
        plp_withdraw_fee_rate: config_constants::default_plp_withdraw_fee_rate!(),
        lp_request_limit_flush_attempts: config_constants::default_lp_request_limit_flush_attempts!(),
        max_lp_pool_value: config_constants::default_max_lp_pool_value!(),
        max_valuation_window_ms: config_constants::default_max_valuation_window_ms!(),
        max_valuation_log_ops: config_constants::default_max_valuation_log_ops!(),
        strike_exposure_template_config: strike_exposure_config::new(),
        ewma_config: ewma_config::new(),
        version_watermark: constants::current_version!(),
        trading_paused: false,
        frozen: false,
        valuation_in_progress: false,
        flush_seq: 0,
    }
}
