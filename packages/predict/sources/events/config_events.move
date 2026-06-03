// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Admin and configuration events for Predict.
module deepbook_predict::config_events;

use deepbook_predict::{
    ewma_config::EwmaConfig,
    fee_config::FeeConfig,
    leverage_config::LeverageConfig,
    market_oracle_config::MarketOracleConfig,
    pricing_config::PricingConfig,
    risk_config::RiskConfig,
    strike_grid::StrikeGrid
};
use sui::event;

/// Emitted when pricing or quote-freshness config changes.
public struct PricingConfigUpdated has copy, drop, store {
    protocol_config_id: ID,
    base_fee: u64,
    min_fee: u64,
    min_ask_price: u64,
    max_ask_price: u64,
    pyth_spot_freshness_ms: u64,
    block_scholes_prices_freshness_ms: u64,
    block_scholes_svi_freshness_ms: u64,
}

/// Emitted when profit-reserve or trading-loss rebate policy changes.
public struct FeeConfigUpdated has copy, drop, store {
    protocol_config_id: ID,
    protocol_reserve_profit_share: u64,
    trading_loss_rebate_rate: u64,
}

/// Emitted when liquidation-budget policy changes.
public struct RiskConfigUpdated has copy, drop, store {
    protocol_config_id: ID,
    valuation_liquidation_budget: u64,
    trade_liquidation_budget: u64,
}

/// Emitted when future-market leverage template policy changes.
public struct LeverageConfigUpdated has copy, drop, store {
    protocol_config_id: ID,
    max_expiry_floor_premium: u64,
    liquidation_ltv: u64,
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
    expiry: u64,
    min_strike: u64,
    tick_size: u64,
    max_strike: u64,
}

/// Emitted when per-oracle bounds are updated.
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
        base_fee: config.base_fee(),
        min_fee: config.min_fee(),
        min_ask_price: config.min_ask_price(),
        max_ask_price: config.max_ask_price(),
        pyth_spot_freshness_ms: config.pyth_spot_freshness_ms(),
        block_scholes_prices_freshness_ms: config.block_scholes_prices_freshness_ms(),
        block_scholes_svi_freshness_ms: config.block_scholes_svi_freshness_ms(),
    });
}

public(package) fun emit_fee_config_updated(protocol_config_id: ID, config: &FeeConfig) {
    event::emit(FeeConfigUpdated {
        protocol_config_id,
        protocol_reserve_profit_share: config.protocol_reserve_profit_share(),
        trading_loss_rebate_rate: config.trading_loss_rebate_rate(),
    });
}

public(package) fun emit_risk_config_updated(protocol_config_id: ID, config: &RiskConfig) {
    event::emit(RiskConfigUpdated {
        protocol_config_id,
        valuation_liquidation_budget: config.valuation_liquidation_budget(),
        trade_liquidation_budget: config.trade_liquidation_budget(),
    });
}

public(package) fun emit_leverage_config_updated(protocol_config_id: ID, config: &LeverageConfig) {
    event::emit(LeverageConfigUpdated {
        protocol_config_id,
        max_expiry_floor_premium: config.max_expiry_floor_premium(),
        liquidation_ltv: config.liquidation_ltv(),
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
    expiry: u64,
    grid: &StrikeGrid,
) {
    event::emit(MarketCreated {
        expiry_market_id,
        market_oracle_id,
        pool_vault_id,
        expiry,
        min_strike: grid.min_strike(),
        tick_size: grid.tick_size(),
        max_strike: grid.max_strike(),
    });
}

public(package) fun emit_market_oracle_bounds_updated(
    market_oracle_id: ID,
    settlement_freshness_ms: u64,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    event::emit(MarketOracleBoundsUpdated {
        market_oracle_id,
        settlement_freshness_ms,
        max_spot_deviation,
        max_basis_deviation,
        min_basis,
        max_basis,
    });
}

public(package) fun emit_expiry_market_mint_paused_updated(expiry_market_id: ID, paused: bool) {
    event::emit(ExpiryMarketMintPausedUpdated {
        expiry_market_id,
        paused,
    });
}
