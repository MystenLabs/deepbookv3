// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Protocol-wide configuration and flow gates for Predict.
///
/// This shared object owns the admin-tunable config structs, trading pause,
/// and full-pool valuation lock. Flow modules decide which gates apply before
/// they mutate expiry, oracle, pool, or manager state.
module deepbook_predict::protocol_config;

use deepbook_predict::{
    fee_config::{Self, FeeConfig},
    leverage_config::{Self, LeverageConfig},
    market_oracle_config::{Self, MarketOracleConfig},
    pricing_config::{Self, PricingConfig},
    risk_config::{Self, RiskConfig}
};

const ETradingPaused: u64 = 0;
const EValuationInProgress: u64 = 1;
const EValuationNotInProgress: u64 = 2;

/// Shared protocol policy and config state.
public struct ProtocolConfig has key {
    id: UID,
    pricing_config: PricingConfig,
    fee_config: FeeConfig,
    risk_config: RiskConfig,
    market_oracle_config: MarketOracleConfig,
    leverage_config: LeverageConfig,
    /// Blocks new risk creation while true.
    trading_paused: bool,
    /// Transaction-local lock held while a full-pool valuation is assembled.
    valuation_in_progress: bool,
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

// === Public-Package Functions ===

public(package) fun pricing_config(config: &ProtocolConfig): &PricingConfig {
    &config.pricing_config
}

public(package) fun fee_config(config: &ProtocolConfig): &FeeConfig {
    &config.fee_config
}

public(package) fun risk_config(config: &ProtocolConfig): &RiskConfig {
    &config.risk_config
}

public(package) fun market_oracle_config(config: &ProtocolConfig): &MarketOracleConfig {
    &config.market_oracle_config
}

public(package) fun leverage_config(config: &ProtocolConfig): &LeverageConfig {
    &config.leverage_config
}

/// Abort unless trading mutations are currently allowed.
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
    let config = ProtocolConfig {
        id: object::new(ctx),
        pricing_config: pricing_config::new(),
        fee_config: fee_config::new(),
        risk_config: risk_config::new(),
        market_oracle_config: market_oracle_config::new(),
        leverage_config: leverage_config::new(),
        trading_paused: false,
        valuation_in_progress: false,
    };
    let id = config.id();
    transfer::share_object(config);
    id
}

public(package) fun set_base_fee(config: &mut ProtocolConfig, fee: u64) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_base_fee(fee);
}

public(package) fun set_min_fee(config: &mut ProtocolConfig, fee: u64) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_min_fee(fee);
}

public(package) fun set_template_max_expiry_borrow_fee(config: &mut ProtocolConfig, value: u64) {
    config.assert_not_valuation_in_progress();
    config.leverage_config.set_template_max_expiry_borrow_fee(value);
}

public(package) fun set_min_ask_price(config: &mut ProtocolConfig, value: u64) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_min_ask_price(value);
}

public(package) fun set_max_ask_price(config: &mut ProtocolConfig, value: u64) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_max_ask_price(value);
}

public(package) fun set_pyth_spot_freshness_ms(config: &mut ProtocolConfig, value: u64) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_pyth_spot_freshness_ms(value);
}

public(package) fun set_block_scholes_prices_freshness_ms(config: &mut ProtocolConfig, value: u64) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_block_scholes_prices_freshness_ms(value);
}

public(package) fun set_block_scholes_svi_freshness_ms(config: &mut ProtocolConfig, value: u64) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_block_scholes_svi_freshness_ms(value);
}

public(package) fun set_fee_shares(
    config: &mut ProtocolConfig,
    lp_fee_share: u64,
    protocol_fee_share: u64,
    insurance_fee_share: u64,
) {
    config.assert_not_valuation_in_progress();
    config.fee_config.set_fee_shares(lp_fee_share, protocol_fee_share, insurance_fee_share);
}

public(package) fun set_max_total_exposure_pct(config: &mut ProtocolConfig, pct: u64) {
    config.assert_not_valuation_in_progress();
    config.risk_config.set_max_total_exposure_pct(pct);
}

public(package) fun set_expiry_allocation(config: &mut ProtocolConfig, allocation: u64) {
    config.assert_not_valuation_in_progress();
    config.risk_config.set_expiry_allocation(allocation);
}

public(package) fun set_grow_utilization_threshold(config: &mut ProtocolConfig, threshold: u64) {
    config.assert_not_valuation_in_progress();
    config.risk_config.set_grow_utilization_threshold(threshold);
}

public(package) fun set_shrink_utilization_threshold(config: &mut ProtocolConfig, threshold: u64) {
    config.assert_not_valuation_in_progress();
    config.risk_config.set_shrink_utilization_threshold(threshold);
}

public(package) fun set_grow_factor(config: &mut ProtocolConfig, factor: u64) {
    config.assert_not_valuation_in_progress();
    config.risk_config.set_grow_factor(factor);
}

public(package) fun set_shrink_factor(config: &mut ProtocolConfig, factor: u64) {
    config.assert_not_valuation_in_progress();
    config.risk_config.set_shrink_factor(factor);
}

/// Set the settlement freshness threshold template for future market oracles.
public(package) fun set_market_oracle_template_settlement_freshness_ms(
    config: &mut ProtocolConfig,
    value: u64,
) {
    config.assert_not_valuation_in_progress();
    config.market_oracle_config.set_settlement_freshness_ms(value);
}

/// Set basis guard bounds template for future market oracles.
public(package) fun set_market_oracle_template_basis_bounds(
    config: &mut ProtocolConfig,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    config.assert_not_valuation_in_progress();
    config
        .market_oracle_config
        .set_basis_bounds(
            max_spot_deviation,
            max_basis_deviation,
            min_basis,
            max_basis,
        );
}

public(package) fun set_trading_paused(config: &mut ProtocolConfig, paused: bool) {
    config.assert_not_valuation_in_progress();
    config.trading_paused = paused;
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

// === Private Functions ===

/// Abort unless trading is not paused.
fun assert_not_trading_paused(config: &ProtocolConfig) {
    assert!(!config.trading_paused, ETradingPaused);
}

// === Test-Only Functions ===

#[test_only]
public(package) fun new_for_testing(ctx: &mut TxContext): ProtocolConfig {
    ProtocolConfig {
        id: object::new(ctx),
        pricing_config: pricing_config::new(),
        fee_config: fee_config::new(),
        risk_config: risk_config::new(),
        market_oracle_config: market_oracle_config::new(),
        leverage_config: leverage_config::new(),
        trading_paused: false,
        valuation_in_progress: false,
    }
}
