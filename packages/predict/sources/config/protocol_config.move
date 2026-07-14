// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Protocol-wide configuration and flow gates for Predict.
///
/// This shared object owns the admin-tunable config structs and the trading pause
/// gate. Flow modules decide which gates apply before they mutate expiry, oracle,
/// pool, or account state.
module deepbook_predict::protocol_config;

use deepbook_predict::{
    admin::AdminCap,
    config_constants,
    config_events,
    constants,
    ewma_config::{Self, EwmaConfig},
    expiry_cash_config::{Self, ExpiryCashConfig},
    pricing_config::{Self, PricingConfig},
    stake_config::{Self, StakeConfig},
    strike_exposure_config::{Self, StrikeExposureConfig},
    valuation_config::{Self, ValuationConfig}
};

const ETradingPaused: u64 = 0;
const EPackageVersionDisabled: u64 = 1;
const EVersionWatermarkNotAdvanced: u64 = 2;

/// Shared protocol policy and config state.
public struct ProtocolConfig has key {
    id: UID,
    pricing_config: PricingConfig,
    /// Merged protocol + insurance reserve share of materialized terminal profit,
    /// in FLOAT_SCALING. The complement accrues to LPs.
    protocol_reserve_profit_share: u64,
    /// Total liquidation candidates checked before mint and redeem flows.
    trade_liquidation_budget: u64,
    expiry_cash_template_config: ExpiryCashConfig,
    strike_exposure_template_config: StrikeExposureConfig,
    stake_config: StakeConfig,
    ewma_config: EwmaConfig,
    /// Minimum package version permitted to run version-gated flows. Monotonic;
    /// `bump_version_watermark` advances it to the running `current_version!()`,
    /// retiring older versions. A running version below this floor is dead
    /// (`assert_version`). `current_version!()` stays the upgrade-required code
    /// constant; this is the runtime floor.
    version_watermark: u64,
    /// Blocks new risk creation while true.
    trading_paused: bool,
    valuation_config: ValuationConfig,
}

// === Public Functions ===

/// Return the protocol config object ID.
public fun id(config: &ProtocolConfig): ID {
    config.id.to_inner()
}

/// Return whether trading is currently paused.
public fun trading_paused(config: &ProtocolConfig): bool {
    config.trading_paused
}

/// Set the base fee multiplier snapshotted by future expiry markets.
public fun set_template_base_fee(config: &mut ProtocolConfig, _admin_cap: &AdminCap, fee: u64) {
    config.assert_version();
    config.strike_exposure_template_config.set_base_fee(fee);
}

/// Set the minimum fee floor snapshotted by future expiry markets.
public fun set_template_min_fee(config: &mut ProtocolConfig, _admin_cap: &AdminCap, fee: u64) {
    config.assert_version();
    config.strike_exposure_template_config.set_min_fee(fee);
}

/// Set the expiry-fee ramp window snapshotted by future expiry markets.
public fun set_template_expiry_fee_window_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_version();
    config.strike_exposure_template_config.set_expiry_fee_window_ms(value);
}

/// Set the expiry-fee max multiplier snapshotted by future expiry markets.
public fun set_template_expiry_fee_max_multiplier(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_version();
    config.strike_exposure_template_config.set_expiry_fee_max_multiplier(value);
}

/// Set the liquidation LTV snapshotted by future expiry markets.
public fun set_template_liquidation_ltv(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_version();
    config.strike_exposure_template_config.set_liquidation_ltv(value);
}

/// Set the max admission leverage snapshotted by future expiry markets.
public fun set_template_max_admission_leverage(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_version();
    config.strike_exposure_template_config.set_max_admission_leverage(value);
}

/// Set the backing-buffer lambda snapshotted by future expiry markets.
public fun set_template_backing_buffer_lambda(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_version();
    config.strike_exposure_template_config.set_backing_buffer_lambda(value);
}

/// Set the staking benefit thresholds: `lower` (half of max benefits) and
/// `upper` (full benefits). Validated as a pair (`upper > 2 * lower`).
public fun set_benefit_powers(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    lower: u64,
    upper: u64,
) {
    config.assert_version();
    config.stake_config.set_benefit_powers(lower, upper);
}

/// Set the minimum raw entry probability snapshotted by future expiry markets.
public fun set_template_min_entry_probability(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_version();
    config.strike_exposure_template_config.set_min_entry_probability(value);
}

/// Set the maximum raw entry probability snapshotted by future expiry markets.
public fun set_template_max_entry_probability(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_version();
    config.strike_exposure_template_config.set_max_entry_probability(value);
}

/// Set the live Pyth spot freshness threshold.
public fun set_pyth_spot_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_version();
    config.pricing_config.set_pyth_spot_freshness_ms(value);
}

/// Set the live Block Scholes spot/forward freshness threshold.
public fun set_block_scholes_price_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_version();
    config.pricing_config.set_block_scholes_price_freshness_ms(value);
}

/// Set the live Block Scholes SVI freshness threshold.
public fun set_block_scholes_svi_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_version();
    config.pricing_config.set_block_scholes_svi_freshness_ms(value);
}

/// Set the hard freshness ceiling on stored valuation marks at the pool flush.
public fun set_nav_mark_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_version();
    config.valuation_config.set_nav_mark_freshness_ms(value);
}

/// Set the trading loss rebate rate template used by future expiry markets.
public fun set_template_trading_loss_rebate_rate(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_version();
    config.expiry_cash_template_config.set_trading_loss_rebate_rate(value);
}

/// Set the total liquidation candidate budget used before mint and redeem flows.
public fun set_trade_liquidation_budget(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    budget: u64,
) {
    config.assert_version();
    config_constants::assert_trade_liquidation_budget(budget);
    config.trade_liquidation_budget = budget;
}

/// Set the EWMA gas-price penalty parameters.
public fun set_ewma_params(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    alpha: u64,
    z_score_threshold: u64,
    penalty_rate: u64,
) {
    config.assert_version();
    config.ewma_config.set_params(alpha, z_score_threshold, penalty_rate);
}

/// Enable or disable the EWMA gas-price penalty.
public fun set_ewma_enabled(config: &mut ProtocolConfig, _admin_cap: &AdminCap, enabled: bool) {
    config.assert_version();
    config.ewma_config.set_enabled(enabled);
}

/// Set whether trading is paused.
public fun set_trading_paused(config: &mut ProtocolConfig, _admin_cap: &AdminCap, paused: bool) {
    config.assert_version();
    config.set_trading_paused_internal(paused);
}

/// Advance the version watermark to this package's compiled-in `current_version!()`,
/// retiring every older version (a running version below the floor is dead — see
/// `assert_version`).
///
/// Takes no target: the floor can only ever move to a version a published binary
/// actually embeds, so admin can never set it above the running package and brick
/// it. Raising the floor therefore requires executing this against the upgraded
/// package, where `current_version!()` is higher. Aborts if the running version
/// does not exceed the current watermark (nothing to retire). Ungated so it stays
/// callable across an upgrade.
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
    config_constants::assert_protocol_reserve_profit_share(protocol_reserve_profit_share);
    config.protocol_reserve_profit_share = protocol_reserve_profit_share;
}

// === Public-Package Functions ===

public(package) fun pricing_config(config: &ProtocolConfig): &PricingConfig {
    &config.pricing_config
}

public(package) fun protocol_reserve_profit_share(config: &ProtocolConfig): u64 {
    config.protocol_reserve_profit_share
}

public(package) fun trade_liquidation_budget(config: &ProtocolConfig): u64 {
    config.trade_liquidation_budget
}

public(package) fun expiry_cash_template_config(config: &ProtocolConfig): &ExpiryCashConfig {
    &config.expiry_cash_template_config
}

public(package) fun strike_exposure_template_config(
    config: &ProtocolConfig,
): &StrikeExposureConfig {
    &config.strike_exposure_template_config
}

public(package) fun expiry_cash_config_snapshot(config: &ProtocolConfig): ExpiryCashConfig {
    expiry_cash_config::snapshot(&config.expiry_cash_template_config)
}

public(package) fun strike_exposure_config_snapshot(config: &ProtocolConfig): StrikeExposureConfig {
    strike_exposure_config::snapshot(&config.strike_exposure_template_config)
}

public(package) fun stake_config(config: &ProtocolConfig): &StakeConfig {
    &config.stake_config
}

public(package) fun ewma_config(config: &ProtocolConfig): &EwmaConfig {
    &config.ewma_config
}

public(package) fun valuation_config(config: &ProtocolConfig): &ValuationConfig {
    &config.valuation_config
}

/// Abort unless the running package version is at or above the watermark floor.
///
/// The single version gate for the package: every version-gated flow threads the
/// shared `ProtocolConfig` and calls this first. Replaces the former per-object
/// `allowed_versions` mirrors.
public(package) fun assert_version(config: &ProtocolConfig) {
    assert!(constants::current_version!() >= config.version_watermark, EPackageVersionDisabled);
}

/// Abort unless trading mutations are currently allowed.
///
/// Intentionally omits the package-version gate: callers assert the version
/// separately via `assert_version` when the flow is version-gated.
public(package) fun assert_trading_allowed(config: &ProtocolConfig) {
    config.assert_not_trading_paused();
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

fun set_trading_paused_internal(config: &mut ProtocolConfig, paused: bool) {
    config.trading_paused = paused;
    config_events::emit_trading_paused_updated(config.id(), paused);
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
        trade_liquidation_budget: config_constants::default_trade_liquidation_budget!(),
        expiry_cash_template_config: expiry_cash_config::new(),
        strike_exposure_template_config: strike_exposure_config::new(),
        stake_config: stake_config::new(),
        ewma_config: ewma_config::new(),
        version_watermark: constants::current_version!(),
        trading_paused: false,
        valuation_config: valuation_config::new(),
    }
}

// Tests obtain the ProtocolConfig that `registry::init_for_testing` shares via
// `create_and_share`, taken with `take_shared<ProtocolConfig>()`.
