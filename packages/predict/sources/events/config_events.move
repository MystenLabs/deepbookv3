// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Admin and configuration events for Predict.
module deepbook_predict::config_events;

use deepbook_predict::{
    ewma_config::EwmaConfig,
    expiry_cash_config::ExpiryCashConfig,
    market_oracle_config::MarketOracleConfig,
    pricing_config::PricingConfig,
    stake_config::StakeConfig,
    strike_exposure_config::StrikeExposureConfig,
    strike_grid::StrikeGrid
};
use sui::event;

/// Emitted when quote-freshness config changes.
public struct PricingConfigUpdated has copy, drop, store {
    protocol_config_id: ID,
    pyth_spot_freshness_ms: u64,
    block_scholes_prices_freshness_ms: u64,
    block_scholes_svi_freshness_ms: u64,
}

/// Emitted when pool fee policy changes.
public struct FeeConfigUpdated has copy, drop, store {
    protocol_config_id: ID,
    protocol_reserve_profit_share: u64,
    withdraw_fee_alpha: u64,
}

/// Emitted when liquidation-budget policy changes.
public struct RiskConfigUpdated has copy, drop, store {
    protocol_config_id: ID,
    valuation_liquidation_budget: u64,
    trade_liquidation_budget: u64,
}

/// Emitted when future expiry-cash template policy changes.
public struct ExpiryCashTemplateConfigUpdated has copy, drop, store {
    protocol_config_id: ID,
    trading_loss_rebate_rate: u64,
}

/// Emitted when future strike-exposure template policy changes.
public struct StrikeExposureTemplateConfigUpdated has copy, drop, store {
    protocol_config_id: ID,
    terminal_floor_index: u64,
    liquidation_ltv: u64,
    base_fee: u64,
    min_fee: u64,
    min_ask_price: u64,
    max_ask_price: u64,
    expiry_fee_window_ms: u64,
    expiry_fee_max_multiplier: u64,
}

/// Emitted when future market-oracle template policy changes.
public struct MarketOracleTemplateConfigUpdated has copy, drop, store {
    protocol_config_id: ID,
    settlement_freshness_ms: u64,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
}

/// Emitted when the EWMA gas-price penalty config changes.
public struct EwmaConfigUpdated has copy, drop, store {
    protocol_config_id: ID,
    alpha: u64,
    z_score_threshold: u64,
    additional_fee: u64,
    enabled: bool,
}

/// Emitted when the DEEP-stake benefit config changes. These thresholds govern
/// the per-trade fee discount and the trading-loss rebate share.
public struct StakeConfigUpdated has copy, drop, store {
    protocol_config_id: ID,
    lower_benefit_power: u64,
    upper_benefit_power: u64,
}

/// Emitted when global trading pause state changes.
public struct TradingPausedUpdated has copy, drop, store {
    protocol_config_id: ID,
    paused: bool,
}

/// Emitted when a new expiry market and its oracle are created.
public struct MarketCreated has copy, drop, store {
    expiry_market_id: ID,
    market_oracle_id: ID,
    pool_vault_id: ID,
    /// PythSource object and Lazer feed backing this market's spot, so
    /// `PythSourceUpdated` history (keyed by these) can be fanned into the market.
    pyth_source_id: ID,
    pyth_lazer_feed_id: u32,
    expiry: u64,
    min_strike: u64,
    tick_size: u64,
    max_strike: u64,
}

/// Emitted alongside `MarketCreated` with the per-market policy snapshotted into
/// the expiry market at creation. These values are immutable for the market's
/// life (there is no per-market config setter), so this single event is the
/// authoritative source for the policy actually in force on the market.
public struct MarketConfigSnapshot has copy, drop, store {
    expiry_market_id: ID,
    market_oracle_id: ID,
    terminal_floor_index: u64,
    liquidation_ltv: u64,
    base_fee: u64,
    min_fee: u64,
    min_ask_price: u64,
    max_ask_price: u64,
    expiry_fee_window_ms: u64,
    expiry_fee_max_multiplier: u64,
    trading_loss_rebate_rate: u64,
}

/// Emitted when admin updates one live oracle's bounds.
public struct MarketOracleBoundsUpdated has copy, drop, store {
    market_oracle_id: ID,
    settlement_freshness_ms: u64,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
}

/// Emitted when minting pause state changes for one expiry market.
public struct ExpiryMarketMintPausedUpdated has copy, drop, store {
    expiry_market_id: ID,
    paused: bool,
}

// === Public-Package Functions ===

public(package) fun emit_pricing_config_updated(protocol_config_id: ID, config: &PricingConfig) {
    event::emit(PricingConfigUpdated {
        protocol_config_id,
        pyth_spot_freshness_ms: config.pyth_spot_freshness_ms(),
        block_scholes_prices_freshness_ms: config.block_scholes_prices_freshness_ms(),
        block_scholes_svi_freshness_ms: config.block_scholes_svi_freshness_ms(),
    });
}

public(package) fun emit_fee_config_updated(
    protocol_config_id: ID,
    protocol_reserve_profit_share: u64,
    withdraw_fee_alpha: u64,
) {
    event::emit(FeeConfigUpdated {
        protocol_config_id,
        protocol_reserve_profit_share,
        withdraw_fee_alpha,
    });
}

public(package) fun emit_risk_config_updated(
    protocol_config_id: ID,
    valuation_liquidation_budget: u64,
    trade_liquidation_budget: u64,
) {
    event::emit(RiskConfigUpdated {
        protocol_config_id,
        valuation_liquidation_budget,
        trade_liquidation_budget,
    });
}

public(package) fun emit_expiry_cash_template_config_updated(
    protocol_config_id: ID,
    config: &ExpiryCashConfig,
) {
    event::emit(ExpiryCashTemplateConfigUpdated {
        protocol_config_id,
        trading_loss_rebate_rate: config.trading_loss_rebate_rate(),
    });
}

public(package) fun emit_strike_exposure_template_config_updated(
    protocol_config_id: ID,
    config: &StrikeExposureConfig,
) {
    event::emit(StrikeExposureTemplateConfigUpdated {
        protocol_config_id,
        terminal_floor_index: config.terminal_floor_index(),
        liquidation_ltv: config.liquidation_ltv(),
        base_fee: config.base_fee(),
        min_fee: config.min_fee(),
        min_ask_price: config.min_ask_price(),
        max_ask_price: config.max_ask_price(),
        expiry_fee_window_ms: config.expiry_fee_window_ms(),
        expiry_fee_max_multiplier: config.expiry_fee_max_multiplier(),
    });
}

public(package) fun emit_market_oracle_template_config_updated(
    protocol_config_id: ID,
    config: &MarketOracleConfig,
) {
    event::emit(MarketOracleTemplateConfigUpdated {
        protocol_config_id,
        settlement_freshness_ms: config.settlement_freshness_ms(),
        max_spot_deviation: config.max_spot_deviation(),
        max_basis_deviation: config.max_basis_deviation(),
        min_basis: config.min_basis(),
        max_basis: config.max_basis(),
    });
}

public(package) fun emit_ewma_config_updated(protocol_config_id: ID, config: &EwmaConfig) {
    event::emit(EwmaConfigUpdated {
        protocol_config_id,
        alpha: config.alpha(),
        z_score_threshold: config.z_score_threshold(),
        additional_fee: config.additional_fee(),
        enabled: config.enabled(),
    });
}

public(package) fun emit_stake_config_updated(protocol_config_id: ID, config: &StakeConfig) {
    event::emit(StakeConfigUpdated {
        protocol_config_id,
        lower_benefit_power: config.lower_benefit_power(),
        upper_benefit_power: config.upper_benefit_power(),
    });
}

public(package) fun emit_trading_paused_updated(protocol_config_id: ID, paused: bool) {
    event::emit(TradingPausedUpdated {
        protocol_config_id,
        paused,
    });
}

public(package) fun emit_market_created(
    expiry_market_id: ID,
    market_oracle_id: ID,
    pool_vault_id: ID,
    pyth_source_id: ID,
    pyth_lazer_feed_id: u32,
    expiry: u64,
    grid: &StrikeGrid,
) {
    event::emit(MarketCreated {
        expiry_market_id,
        market_oracle_id,
        pool_vault_id,
        pyth_source_id,
        pyth_lazer_feed_id,
        expiry,
        min_strike: grid.min_strike(),
        tick_size: grid.tick_size(),
        max_strike: grid.max_strike(),
    });
}

public(package) fun emit_market_config_snapshot(
    expiry_market_id: ID,
    market_oracle_id: ID,
    strike_exposure_config: &StrikeExposureConfig,
    expiry_cash_config: &ExpiryCashConfig,
) {
    event::emit(MarketConfigSnapshot {
        expiry_market_id,
        market_oracle_id,
        terminal_floor_index: strike_exposure_config.terminal_floor_index(),
        liquidation_ltv: strike_exposure_config.liquidation_ltv(),
        base_fee: strike_exposure_config.base_fee(),
        min_fee: strike_exposure_config.min_fee(),
        min_ask_price: strike_exposure_config.min_ask_price(),
        max_ask_price: strike_exposure_config.max_ask_price(),
        expiry_fee_window_ms: strike_exposure_config.expiry_fee_window_ms(),
        expiry_fee_max_multiplier: strike_exposure_config.expiry_fee_max_multiplier(),
        trading_loss_rebate_rate: expiry_cash_config.trading_loss_rebate_rate(),
    });
}

public(package) fun emit_market_oracle_bounds_updated(
    market_oracle_id: ID,
    config: &MarketOracleConfig,
) {
    event::emit(MarketOracleBoundsUpdated {
        market_oracle_id,
        settlement_freshness_ms: config.settlement_freshness_ms(),
        max_spot_deviation: config.max_spot_deviation(),
        max_basis_deviation: config.max_basis_deviation(),
        min_basis: config.min_basis(),
        max_basis: config.max_basis(),
    });
}

public(package) fun emit_expiry_market_mint_paused_updated(expiry_market_id: ID, paused: bool) {
    event::emit(ExpiryMarketMintPausedUpdated {
        expiry_market_id,
        paused,
    });
}
