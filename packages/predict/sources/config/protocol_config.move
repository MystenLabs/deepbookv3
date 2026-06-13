// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Protocol-wide configuration and flow gates for Predict.
///
/// This shared object owns the admin-tunable config structs and the trading
/// pause gate. Flow modules decide which gates apply before they mutate expiry,
/// oracle, pool, or manager state.
module deepbook_predict::protocol_config;

use deepbook_predict::{
    admin::AdminCap,
    config_constants,
    config_events,
    ewma_config::{Self, EwmaConfig},
    expiry_cash_config::{Self, ExpiryCashConfig},
    market_oracle_config::{Self, MarketOracleConfig},
    pricing_config::{Self, PricingConfig},
    stake_config::{Self, StakeConfig},
    strike_exposure_config::{Self, StrikeExposureConfig}
};

const ETradingPaused: u64 = 0;

/// Shared protocol policy and config state.
public struct ProtocolConfig has key {
    id: UID,
    pricing_config: PricingConfig,
    /// Total liquidation candidates checked before mint and redeem flows.
    trade_liquidation_budget: u64,
    market_oracle_template_config: MarketOracleConfig,
    expiry_cash_template_config: ExpiryCashConfig,
    strike_exposure_template_config: StrikeExposureConfig,
    stake_config: StakeConfig,
    ewma_config: EwmaConfig,
    /// Blocks new risk creation while true.
    trading_paused: bool,
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
    config.strike_exposure_template_config.set_base_fee(fee);
    config_events::emit_strike_exposure_template_config_updated(
        config.id(),
        &config.strike_exposure_template_config,
    );
}

/// Set the minimum fee floor snapshotted by future expiry markets.
public fun set_template_min_fee(config: &mut ProtocolConfig, _admin_cap: &AdminCap, fee: u64) {
    config.strike_exposure_template_config.set_min_fee(fee);
    config_events::emit_strike_exposure_template_config_updated(
        config.id(),
        &config.strike_exposure_template_config,
    );
}

/// Set the expiry-fee ramp window snapshotted by future expiry markets.
public fun set_template_expiry_fee_window_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.strike_exposure_template_config.set_expiry_fee_window_ms(value);
    config_events::emit_strike_exposure_template_config_updated(
        config.id(),
        &config.strike_exposure_template_config,
    );
}

/// Set the expiry-fee max multiplier snapshotted by future expiry markets.
public fun set_template_expiry_fee_max_multiplier(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.strike_exposure_template_config.set_expiry_fee_max_multiplier(value);
    config_events::emit_strike_exposure_template_config_updated(
        config.id(),
        &config.strike_exposure_template_config,
    );
}

/// Set the terminal floor index snapshotted by future expiry markets.
public fun set_template_terminal_floor_index(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.strike_exposure_template_config.set_terminal_floor_index(value);
    config_events::emit_strike_exposure_template_config_updated(
        config.id(),
        &config.strike_exposure_template_config,
    );
}

/// Set the liquidation LTV snapshotted by future expiry markets.
public fun set_template_liquidation_ltv(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.strike_exposure_template_config.set_liquidation_ltv(value);
    config_events::emit_strike_exposure_template_config_updated(
        config.id(),
        &config.strike_exposure_template_config,
    );
}

/// Set the backing-buffer lambda snapshotted by future expiry markets.
public fun set_template_backing_buffer_lambda(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.strike_exposure_template_config.set_backing_buffer_lambda(value);
    config_events::emit_strike_exposure_template_config_updated(
        config.id(),
        &config.strike_exposure_template_config,
    );
}

/// Set the staking benefit thresholds: `lower` (half of max benefits) and
/// `upper` (full benefits). Validated as a pair (`upper > 2 * lower`).
public fun set_benefit_powers(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    lower: u64,
    upper: u64,
) {
    config.stake_config.set_benefit_powers(lower, upper);
    config_events::emit_stake_config_updated(config.id(), &config.stake_config);
}

/// Set the minimum all-in mint price snapshotted by future expiry markets.
public fun set_template_min_ask_price(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.strike_exposure_template_config.set_min_ask_price(value);
    config_events::emit_strike_exposure_template_config_updated(
        config.id(),
        &config.strike_exposure_template_config,
    );
}

/// Set the maximum all-in mint price snapshotted by future expiry markets.
public fun set_template_max_ask_price(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.strike_exposure_template_config.set_max_ask_price(value);
    config_events::emit_strike_exposure_template_config_updated(
        config.id(),
        &config.strike_exposure_template_config,
    );
}

/// Set the live Pyth spot freshness threshold.
public fun set_pyth_spot_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.pricing_config.set_pyth_spot_freshness_ms(value);
    config_events::emit_pricing_config_updated(config.id(), &config.pricing_config);
}

/// Set the live Block Scholes spot/forward freshness threshold.
public fun set_block_scholes_prices_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.pricing_config.set_block_scholes_prices_freshness_ms(value);
    config_events::emit_pricing_config_updated(config.id(), &config.pricing_config);
}

/// Set the live Block Scholes SVI freshness threshold.
public fun set_block_scholes_svi_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.pricing_config.set_block_scholes_svi_freshness_ms(value);
    config_events::emit_pricing_config_updated(config.id(), &config.pricing_config);
}

/// Set the trading loss rebate rate template used by future expiry markets.
public fun set_template_trading_loss_rebate_rate(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.expiry_cash_template_config.set_trading_loss_rebate_rate(value);
    config_events::emit_expiry_cash_template_config_updated(
        config.id(),
        &config.expiry_cash_template_config,
    );
}

/// Set the total liquidation candidate budget used before mint and redeem flows.
public fun set_trade_liquidation_budget(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    budget: u64,
) {
    config_constants::assert_trade_liquidation_budget(budget);
    config.trade_liquidation_budget = budget;
    config_events::emit_risk_config_updated(config.id(), config.trade_liquidation_budget);
}

/// Set the settlement freshness threshold template for future market oracles.
public fun set_market_oracle_template_settlement_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.market_oracle_template_config.set_settlement_freshness_ms(value);
    config_events::emit_market_oracle_template_config_updated(
        config.id(),
        &config.market_oracle_template_config,
    );
}

/// Set the EWMA gas-price penalty parameters.
public fun set_ewma_params(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    alpha: u64,
    z_score_threshold: u64,
    penalty_rate: u64,
) {
    config.ewma_config.set_params(alpha, z_score_threshold, penalty_rate);
    config_events::emit_ewma_config_updated(config.id(), &config.ewma_config);
}

/// Enable or disable the EWMA gas-price penalty.
public fun set_ewma_enabled(config: &mut ProtocolConfig, _admin_cap: &AdminCap, enabled: bool) {
    config.ewma_config.set_enabled(enabled);
    config_events::emit_ewma_config_updated(config.id(), &config.ewma_config);
}

/// Set whether trading is paused.
public fun set_trading_paused(config: &mut ProtocolConfig, _admin_cap: &AdminCap, paused: bool) {
    config.set_trading_paused_internal(paused);
}

// === Public-Package Functions ===

public(package) fun pricing_config(config: &ProtocolConfig): &PricingConfig {
    &config.pricing_config
}

public(package) fun trade_liquidation_budget(config: &ProtocolConfig): u64 {
    config.trade_liquidation_budget
}

public(package) fun market_oracle_config_snapshot(config: &ProtocolConfig): MarketOracleConfig {
    market_oracle_config::snapshot(&config.market_oracle_template_config)
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

/// Abort unless trading mutations are currently allowed.
///
/// Intentionally omits the package-version gate: per-pool mutating flows that
/// call this assert their own mirrored `allowed_versions`, sourced from the
/// registry.
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
        trade_liquidation_budget: config_constants::default_trade_liquidation_budget!(),
        market_oracle_template_config: market_oracle_config::new(),
        expiry_cash_template_config: expiry_cash_config::new(),
        strike_exposure_template_config: strike_exposure_config::new(),
        stake_config: stake_config::new(),
        ewma_config: ewma_config::new(),
        trading_paused: false,
    }
}

// `new_for_testing` removed: tests obtain the ProtocolConfig that
// `registry::init_for_testing` shares via `create_and_share`, taken with
// `take_shared<ProtocolConfig>()`.
