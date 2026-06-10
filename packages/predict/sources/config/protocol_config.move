// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Protocol-wide configuration and flow gates for Predict.
///
/// This shared object owns the admin-tunable config structs, trading pause,
/// and full-pool valuation lock. Flow modules decide which gates apply before
/// they mutate expiry, oracle, pool, or manager state.
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
use sui::table::{Self, Table};

const ETradingPaused: u64 = 0;
const EValuationInProgress: u64 = 1;
const EValuationNotInProgress: u64 = 2;
const EExpiryConfigAlreadyExists: u64 = 3;
const EExpiryConfigNotFound: u64 = 4;

/// Shared protocol policy and config state.
public struct ProtocolConfig has key {
    id: UID,
    pricing_config: PricingConfig,
    /// Merged protocol and insurance reserve share in FLOAT_SCALING.
    protocol_reserve_profit_share: u64,
    /// Multiplier on the PLP withdraw uncertainty-band fee, in FLOAT_SCALING.
    withdraw_fee_alpha: u64,
    /// Total liquidation candidates checked before live pool valuation.
    valuation_liquidation_budget: u64,
    /// Total liquidation candidates checked before mint and redeem flows.
    trade_liquidation_budget: u64,
    market_oracle_template_config: MarketOracleConfig,
    expiry_cash_template_config: ExpiryCashConfig,
    strike_exposure_template_config: StrikeExposureConfig,
    stake_config: StakeConfig,
    ewma_config: EwmaConfig,
    /// Blocks new risk creation while true.
    trading_paused: bool,
    /// Transaction-local lock held while a full-pool valuation is assembled.
    valuation_in_progress: bool,
    /// Expiry market ID -> mutable expiry-specific protocol controls.
    per_expiry: Table<ID, ExpiryRuntimeConfig>,
}

/// Mutable per-expiry runtime controls. Not snapshotted; flows read the current
/// row for the expiry market they operate on.
public struct ExpiryRuntimeConfig has store {
    /// When true, new mints abort. Other expiry flows remain available.
    mint_paused: bool,
    /// Max net DUSDC the pool may have funded into this expiry.
    max_expiry_funding: u64,
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

/// Return whether new mints are paused for one expiry market.
public fun expiry_mint_paused(config: &ProtocolConfig, expiry_market_id: ID): bool {
    config.expiry_config(expiry_market_id).mint_paused
}

/// Return the max net DUSDC the pool may have funded into one expiry.
public fun expiry_max_funding(config: &ProtocolConfig, expiry_market_id: ID): u64 {
    config.expiry_config(expiry_market_id).max_expiry_funding
}

/// Set the base fee multiplier snapshotted by future expiry markets.
public fun set_template_base_fee(config: &mut ProtocolConfig, _admin_cap: &AdminCap, fee: u64) {
    config.assert_not_valuation_in_progress();
    config.strike_exposure_template_config.set_base_fee(fee);
    config_events::emit_strike_exposure_template_config_updated(
        config.id(),
        &config.strike_exposure_template_config,
    );
}

/// Set the minimum fee floor snapshotted by future expiry markets.
public fun set_template_min_fee(config: &mut ProtocolConfig, _admin_cap: &AdminCap, fee: u64) {
    config.assert_not_valuation_in_progress();
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
    config.assert_not_valuation_in_progress();
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
    config.assert_not_valuation_in_progress();
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
    config.assert_not_valuation_in_progress();
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
    config.assert_not_valuation_in_progress();
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
    config.assert_not_valuation_in_progress();
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
    config.assert_not_valuation_in_progress();
    config.stake_config.set_benefit_powers(lower, upper);
    config_events::emit_stake_config_updated(config.id(), &config.stake_config);
}

/// Set the minimum all-in mint price snapshotted by future expiry markets.
public fun set_template_min_ask_price(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_not_valuation_in_progress();
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
    config.assert_not_valuation_in_progress();
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
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_pyth_spot_freshness_ms(value);
    config_events::emit_pricing_config_updated(config.id(), &config.pricing_config);
}

/// Set the live Block Scholes spot/forward freshness threshold.
public fun set_block_scholes_prices_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_block_scholes_prices_freshness_ms(value);
    config_events::emit_pricing_config_updated(config.id(), &config.pricing_config);
}

/// Set the live Block Scholes SVI freshness threshold.
public fun set_block_scholes_svi_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_block_scholes_svi_freshness_ms(value);
    config_events::emit_pricing_config_updated(config.id(), &config.pricing_config);
}

/// Set the current protocol reserve profit share used when materializing aggregate expiry profit.
public fun set_protocol_reserve_profit_share(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    protocol_reserve_profit_share: u64,
) {
    config.assert_not_valuation_in_progress();
    config_constants::assert_protocol_reserve_profit_share(protocol_reserve_profit_share);
    config.protocol_reserve_profit_share = protocol_reserve_profit_share;
    config_events::emit_fee_config_updated(
        config.id(),
        config.protocol_reserve_profit_share,
        config.withdraw_fee_alpha,
    );
}

/// Set the PLP withdraw uncertainty-band fee multiplier.
public fun set_withdraw_fee_alpha(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    withdraw_fee_alpha: u64,
) {
    config.assert_not_valuation_in_progress();
    config_constants::assert_withdraw_fee_alpha(withdraw_fee_alpha);
    config.withdraw_fee_alpha = withdraw_fee_alpha;
    config_events::emit_fee_config_updated(
        config.id(),
        config.protocol_reserve_profit_share,
        config.withdraw_fee_alpha,
    );
}

/// Set the trading loss rebate rate template used by future expiry markets.
public fun set_template_trading_loss_rebate_rate(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_not_valuation_in_progress();
    config.expiry_cash_template_config.set_trading_loss_rebate_rate(value);
    config_events::emit_expiry_cash_template_config_updated(
        config.id(),
        &config.expiry_cash_template_config,
    );
}

/// Set the total liquidation candidate budget used before live valuations.
public fun set_valuation_liquidation_budget(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    budget: u64,
) {
    config.assert_not_valuation_in_progress();
    config_constants::assert_valuation_liquidation_budget(budget);
    config.valuation_liquidation_budget = budget;
    config_events::emit_risk_config_updated(
        config.id(),
        config.valuation_liquidation_budget,
        config.trade_liquidation_budget,
    );
}

/// Set the total liquidation candidate budget used before mint and redeem flows.
public fun set_trade_liquidation_budget(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    budget: u64,
) {
    config.assert_not_valuation_in_progress();
    config_constants::assert_trade_liquidation_budget(budget);
    config.trade_liquidation_budget = budget;
    config_events::emit_risk_config_updated(
        config.id(),
        config.valuation_liquidation_budget,
        config.trade_liquidation_budget,
    );
}

/// Set the settlement freshness threshold template for future market oracles.
public fun set_market_oracle_template_settlement_freshness_ms(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    value: u64,
) {
    config.assert_not_valuation_in_progress();
    config.market_oracle_template_config.set_settlement_freshness_ms(value);
    config_events::emit_market_oracle_template_config_updated(
        config.id(),
        &config.market_oracle_template_config,
    );
}

/// Set basis guard bounds template for future market oracles.
public fun set_market_oracle_template_basis_bounds(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    config.assert_not_valuation_in_progress();
    config
        .market_oracle_template_config
        .set_basis_bounds(
            max_spot_deviation,
            max_basis_deviation,
            min_basis,
            max_basis,
        );
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
    additional_fee: u64,
) {
    config.assert_not_valuation_in_progress();
    config.ewma_config.set_params(alpha, z_score_threshold, additional_fee);
    config_events::emit_ewma_config_updated(config.id(), &config.ewma_config);
}

/// Enable or disable the EWMA gas-price penalty.
public fun set_ewma_enabled(config: &mut ProtocolConfig, _admin_cap: &AdminCap, enabled: bool) {
    config.assert_not_valuation_in_progress();
    config.ewma_config.set_enabled(enabled);
    config_events::emit_ewma_config_updated(config.id(), &config.ewma_config);
}

/// Set whether trading is paused.
public fun set_trading_paused(config: &mut ProtocolConfig, _admin_cap: &AdminCap, paused: bool) {
    config.set_trading_paused_internal(paused);
}

/// Set whether new mints are paused for one expiry market.
public fun set_expiry_mint_paused(
    config: &mut ProtocolConfig,
    _admin_cap: &AdminCap,
    expiry_market_id: ID,
    paused: bool,
) {
    config.set_expiry_mint_paused_internal(expiry_market_id, paused);
}

// === Public-Package Functions ===

public(package) fun pricing_config(config: &ProtocolConfig): &PricingConfig {
    &config.pricing_config
}

public(package) fun protocol_reserve_profit_share(config: &ProtocolConfig): u64 {
    config.protocol_reserve_profit_share
}

public(package) fun withdraw_fee_alpha(config: &ProtocolConfig): u64 {
    config.withdraw_fee_alpha
}

public(package) fun valuation_liquidation_budget(config: &ProtocolConfig): u64 {
    config.valuation_liquidation_budget
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

public(package) fun register_expiry_runtime_config(
    config: &mut ProtocolConfig,
    expiry_market_id: ID,
) {
    assert!(!config.per_expiry.contains(expiry_market_id), EExpiryConfigAlreadyExists);
    config
        .per_expiry
        .add(
            expiry_market_id,
            ExpiryRuntimeConfig {
                mint_paused: false,
                max_expiry_funding: config_constants::default_max_expiry_funding!(),
            },
        );
}

public(package) fun set_expiry_max_funding(
    config: &mut ProtocolConfig,
    expiry_market_id: ID,
    funding: u64,
) {
    config.assert_not_valuation_in_progress();
    config_constants::assert_max_expiry_funding(funding);
    config.expiry_config_mut(expiry_market_id).max_expiry_funding = funding;
}

/// Abort unless trading mutations are currently allowed.
///
/// Intentionally omits the package-version gate: per-pool mutating flows that
/// call this assert their own mirrored `allowed_versions`, sourced from the
/// registry.
public(package) fun assert_trading_allowed(config: &ProtocolConfig) {
    config.assert_not_trading_paused();
    config.assert_not_valuation_in_progress();
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

/// Force `mint_paused = true` for one expiry. Reserved for `PauseCap` holders
/// going through the registry; cannot be used to unpause.
public(package) fun pause_expiry_mint(config: &mut ProtocolConfig, expiry_market_id: ID) {
    config.set_expiry_mint_paused_internal(expiry_market_id, true);
}

/// Begin a transaction-local full-pool valuation lock.
public(package) fun begin_valuation(config: &mut ProtocolConfig) {
    config.assert_not_valuation_in_progress();
    config.valuation_in_progress = true;
}

/// End a transaction-local full-pool valuation lock.
public(package) fun end_valuation(config: &mut ProtocolConfig) {
    config.assert_valuation_in_progress();
    config.valuation_in_progress = false;
}

fun set_trading_paused_internal(config: &mut ProtocolConfig, paused: bool) {
    config.assert_not_valuation_in_progress();
    config.trading_paused = paused;
    config_events::emit_trading_paused_updated(config.id(), paused);
}

fun set_expiry_mint_paused_internal(
    config: &mut ProtocolConfig,
    expiry_market_id: ID,
    paused: bool,
) {
    config.assert_not_valuation_in_progress();
    config.expiry_config_mut(expiry_market_id).mint_paused = paused;
    config_events::emit_expiry_market_mint_paused_updated(expiry_market_id, paused);
}

/// Abort unless trading is not paused.
fun assert_not_trading_paused(config: &ProtocolConfig) {
    assert!(!config.trading_paused, ETradingPaused);
}

fun expiry_config(config: &ProtocolConfig, expiry_market_id: ID): &ExpiryRuntimeConfig {
    assert!(config.per_expiry.contains(expiry_market_id), EExpiryConfigNotFound);
    config.per_expiry.borrow(expiry_market_id)
}

fun expiry_config_mut(config: &mut ProtocolConfig, expiry_market_id: ID): &mut ExpiryRuntimeConfig {
    assert!(config.per_expiry.contains(expiry_market_id), EExpiryConfigNotFound);
    config.per_expiry.borrow_mut(expiry_market_id)
}

fun new(ctx: &mut TxContext): ProtocolConfig {
    ProtocolConfig {
        id: object::new(ctx),
        pricing_config: pricing_config::new(),
        protocol_reserve_profit_share: config_constants::default_protocol_reserve_profit_share!(),
        withdraw_fee_alpha: config_constants::default_withdraw_fee_alpha!(),
        valuation_liquidation_budget: config_constants::default_valuation_liquidation_budget!(),
        trade_liquidation_budget: config_constants::default_trade_liquidation_budget!(),
        market_oracle_template_config: market_oracle_config::new(),
        expiry_cash_template_config: expiry_cash_config::new(),
        strike_exposure_template_config: strike_exposure_config::new(),
        stake_config: stake_config::new(),
        ewma_config: ewma_config::new(),
        trading_paused: false,
        valuation_in_progress: false,
        per_expiry: table::new(ctx),
    }
}

// `new_for_testing` removed: tests obtain the ProtocolConfig that
// `registry::init_for_testing` shares via `create_and_share`, taken with
// `take_shared<ProtocolConfig>()`.
