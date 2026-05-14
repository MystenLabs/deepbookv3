// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Protocol-wide configuration read by expiry markets.
module deepbook_predict::protocol_config;

use deepbook_predict::{
    fee_config::{Self, FeeConfig},
    market_oracle_config::{Self, MarketOracleConfig},
    pricing_config::{Self, PricingConfig},
    risk_config::{Self, RiskConfig}
};

const ETradingPaused: u64 = 0;
const EValuationInProgress: u64 = 1;
const EValuationNotInProgress: u64 = 2;

/// Shared protocol policy state.
public struct ProtocolConfig has key {
    id: UID,
    pricing_config: PricingConfig,
    fee_config: FeeConfig,
    risk_config: RiskConfig,
    market_oracle_config: MarketOracleConfig,
    trading_paused: bool,
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

/// Return the pricing configuration.
public(package) fun pricing_config(config: &ProtocolConfig): &PricingConfig {
    &config.pricing_config
}

/// Return the fee split configuration.
public(package) fun fee_config(config: &ProtocolConfig): &FeeConfig {
    &config.fee_config
}

/// Return the risk configuration.
public(package) fun risk_config(config: &ProtocolConfig): &RiskConfig {
    &config.risk_config
}

/// Return the market oracle configuration template.
public(package) fun market_oracle_config(config: &ProtocolConfig): &MarketOracleConfig {
    &config.market_oracle_config
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

/// Abort unless trading is not paused.
fun assert_not_trading_paused(config: &ProtocolConfig) {
    assert!(!config.trading_paused, ETradingPaused);
}

/// Create and share the protocol-wide configuration object.
public(package) fun create_and_share(ctx: &mut TxContext): ID {
    let config = ProtocolConfig {
        id: object::new(ctx),
        pricing_config: pricing_config::new(),
        fee_config: fee_config::new(),
        risk_config: risk_config::new(),
        market_oracle_config: market_oracle_config::new(),
        trading_paused: false,
        valuation_in_progress: false,
    };
    let id = config.id();
    transfer::share_object(config);
    id
}

/// Set the base fee multiplier.
public(package) fun set_base_fee(config: &mut ProtocolConfig, fee: u64) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_base_fee(fee);
}

/// Set the minimum fee floor.
public(package) fun set_min_fee(config: &mut ProtocolConfig, fee: u64) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_min_fee(fee);
}

/// Set the utilization multiplier.
public(package) fun set_utilization_multiplier(config: &mut ProtocolConfig, multiplier: u64) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_utilization_multiplier(multiplier);
}

/// Set the global minimum allowed mint price.
public(package) fun set_min_ask_price(config: &mut ProtocolConfig, value: u64) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_min_ask_price(value);
}

/// Set the global maximum allowed mint price.
public(package) fun set_max_ask_price(config: &mut ProtocolConfig, value: u64) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_max_ask_price(value);
}

/// Set the live Pyth spot freshness threshold.
public(package) fun set_pyth_spot_freshness_ms(config: &mut ProtocolConfig, value: u64) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_pyth_spot_freshness_ms(value);
}

/// Set the live Block Scholes spot/forward freshness threshold.
public(package) fun set_block_scholes_prices_freshness_ms(config: &mut ProtocolConfig, value: u64) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_block_scholes_prices_freshness_ms(value);
}

/// Set the live Block Scholes SVI freshness threshold.
public(package) fun set_block_scholes_svi_freshness_ms(config: &mut ProtocolConfig, value: u64) {
    config.assert_not_valuation_in_progress();
    config.pricing_config.set_block_scholes_svi_freshness_ms(value);
}

/// Set the fee distribution shares.
public(package) fun set_fee_shares(
    config: &mut ProtocolConfig,
    lp_fee_share: u64,
    protocol_fee_share: u64,
    insurance_fee_share: u64,
) {
    config.assert_not_valuation_in_progress();
    config.fee_config.set_fee_shares(lp_fee_share, protocol_fee_share, insurance_fee_share);
}

/// Set the maximum total exposure percentage.
public(package) fun set_max_total_exposure_pct(config: &mut ProtocolConfig, pct: u64) {
    config.assert_not_valuation_in_progress();
    config.risk_config.set_max_total_exposure_pct(pct);
}

/// Set the current DUSDC allocation for new expiry markets.
public(package) fun set_expiry_allocation(config: &mut ProtocolConfig, allocation: u64) {
    config.assert_not_valuation_in_progress();
    config.risk_config.set_expiry_allocation(allocation);
}

/// Set the utilization threshold that enables allocation growth.
public(package) fun set_grow_utilization_threshold(config: &mut ProtocolConfig, threshold: u64) {
    config.assert_not_valuation_in_progress();
    config.risk_config.set_grow_utilization_threshold(threshold);
}

/// Set the utilization threshold that enables allocation shrink.
public(package) fun set_shrink_utilization_threshold(config: &mut ProtocolConfig, threshold: u64) {
    config.assert_not_valuation_in_progress();
    config.risk_config.set_shrink_utilization_threshold(threshold);
}

/// Set the growth target multiplier.
public(package) fun set_grow_factor(config: &mut ProtocolConfig, factor: u64) {
    config.assert_not_valuation_in_progress();
    config.risk_config.set_grow_factor(factor);
}

/// Set the shrink target multiplier.
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

/// Set whether trading is paused.
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

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): ProtocolConfig {
    ProtocolConfig {
        id: object::new(ctx),
        pricing_config: pricing_config::new(),
        fee_config: fee_config::new(),
        risk_config: risk_config::new(),
        market_oracle_config: market_oracle_config::new(),
        trading_paused: false,
        valuation_in_progress: false,
    }
}

#[test_only]
public fun destroy_for_testing(config: ProtocolConfig) {
    let ProtocolConfig {
        id,
        pricing_config,
        fee_config,
        risk_config,
        market_oracle_config,
        trading_paused: _,
        valuation_in_progress: _,
    } = config;
    id.delete();
    pricing_config.destroy_for_testing();
    fee_config.destroy_for_testing();
    risk_config.destroy_for_testing();
    market_oracle_config.destroy_for_testing();
}
