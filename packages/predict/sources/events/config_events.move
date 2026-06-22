// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Admin and configuration events for Predict.
module deepbook_predict::config_events;

use deepbook_predict::{
    ewma_config::EwmaConfig,
    expiry_cash_config::ExpiryCashConfig,
    pricing_config::PricingConfig,
    stake_config::StakeConfig,
    strike_exposure_config::StrikeExposureConfig
};
use sui::event;

/// Emitted when quote-freshness config changes.
public struct PricingConfigUpdated has copy, drop, store {
    protocol_config_id: ID,
    pyth_spot_freshness_ms: u64,
    block_scholes_surface_freshness_ms: u64,
}

/// Emitted when protocol-scalar risk/reserve policy changes: the per-flow
/// liquidation candidate budget or the protocol+insurance reserve cut of
/// materialized terminal profit.
public struct RiskConfigUpdated has copy, drop, store {
    protocol_config_id: ID,
    trade_liquidation_budget: u64,
    /// Protocol+insurance reserve share of materialized terminal profit, FLOAT_SCALING.
    protocol_reserve_profit_share: u64,
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
    backing_buffer_lambda: u64,
    base_fee: u64,
    min_fee: u64,
    min_ask_price: u64,
    max_ask_price: u64,
    expiry_fee_window_ms: u64,
    expiry_fee_max_multiplier: u64,
}

/// Emitted when the EWMA gas-price penalty config changes.
public struct EwmaConfigUpdated has copy, drop, store {
    protocol_config_id: ID,
    alpha: u64,
    z_score_threshold: u64,
    penalty_rate: u64,
    enabled: bool,
}

/// Emitted when the DEEP-stake benefit config changes. These thresholds govern
/// the per-trade fee discount.
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

/// Emitted when registry-owned market deployment cadence config changes.
public struct CadenceConfigUpdated has copy, drop, store {
    registry_id: ID,
    cadence_id: u8,
    tick_size: u64,
    max_expiry_allocation: u64,
    window_size: u64,
}

/// Emitted when a new expiry market is created.
public struct MarketCreated has copy, drop, store {
    expiry_market_id: ID,
    pool_vault_id: ID,
    /// Propbook underlying this market resolves current oracle bindings through.
    propbook_underlying_id: u32,
    expiry: u64,
    /// Raw-price-per-tick factor; indexers/SDKs derive raw strikes as `tick * tick_size`.
    tick_size: u64,
    /// DUSDC pool allocation cap snapshotted for this expiry.
    max_expiry_allocation: u64,
}

/// Emitted alongside `MarketCreated` with the per-market policy snapshotted into
/// the expiry market at creation. These values are immutable for the market's
/// life (there is no per-market config setter), so this single event is the
/// authoritative source for the policy actually in force on the market.
public struct MarketConfigSnapshot has copy, drop, store {
    expiry_market_id: ID,
    terminal_floor_index: u64,
    liquidation_ltv: u64,
    backing_buffer_lambda: u64,
    base_fee: u64,
    min_fee: u64,
    min_ask_price: u64,
    max_ask_price: u64,
    expiry_fee_window_ms: u64,
    expiry_fee_max_multiplier: u64,
    trading_loss_rebate_rate: u64,
}

/// Emitted when minting pause state changes for one expiry market.
public struct ExpiryMarketMintPausedUpdated has copy, drop, store {
    expiry_market_id: ID,
    paused: bool,
}

/// Emitted once when a market crosses into terminal settlement: `ensure_settled`
/// records the terminal `settlement_price` from Propbook's exact-expiry Pyth spot.
/// This is the canonical per-market settlement signal — settlement is otherwise
/// passive, so a consumer cannot observe the moment without it. Fires exactly once
/// per market (guarded by the settled short-circuit) regardless of which flow
/// (user redeem or keeper sweep) triggers the recording.
public struct MarketSettled has copy, drop, store {
    expiry_market_id: ID,
    propbook_underlying_id: u32,
    expiry: u64,
    settlement_price: u64,
    /// On-chain landing time of the settlement, `clock.timestamp_ms()`.
    settled_at_ms: u64,
}

// === Public-Package Functions ===

public(package) fun emit_pricing_config_updated(protocol_config_id: ID, config: &PricingConfig) {
    event::emit(PricingConfigUpdated {
        protocol_config_id,
        pyth_spot_freshness_ms: config.pyth_spot_freshness_ms(),
        block_scholes_surface_freshness_ms: config.block_scholes_surface_freshness_ms(),
    });
}

public(package) fun emit_risk_config_updated(
    protocol_config_id: ID,
    trade_liquidation_budget: u64,
    protocol_reserve_profit_share: u64,
) {
    event::emit(RiskConfigUpdated {
        protocol_config_id,
        trade_liquidation_budget,
        protocol_reserve_profit_share,
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
        backing_buffer_lambda: config.backing_buffer_lambda(),
        base_fee: config.base_fee(),
        min_fee: config.min_fee(),
        min_ask_price: config.min_ask_price(),
        max_ask_price: config.max_ask_price(),
        expiry_fee_window_ms: config.expiry_fee_window_ms(),
        expiry_fee_max_multiplier: config.expiry_fee_max_multiplier(),
    });
}

public(package) fun emit_ewma_config_updated(protocol_config_id: ID, config: &EwmaConfig) {
    event::emit(EwmaConfigUpdated {
        protocol_config_id,
        alpha: config.alpha(),
        z_score_threshold: config.z_score_threshold(),
        penalty_rate: config.penalty_rate(),
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

public(package) fun emit_cadence_config_updated(
    registry_id: ID,
    cadence_id: u8,
    tick_size: u64,
    max_expiry_allocation: u64,
    window_size: u64,
) {
    event::emit(CadenceConfigUpdated {
        registry_id,
        cadence_id,
        tick_size,
        max_expiry_allocation,
        window_size,
    });
}

public(package) fun emit_market_created(
    expiry_market_id: ID,
    pool_vault_id: ID,
    propbook_underlying_id: u32,
    expiry: u64,
    tick_size: u64,
    max_expiry_allocation: u64,
) {
    event::emit(MarketCreated {
        expiry_market_id,
        pool_vault_id,
        propbook_underlying_id,
        expiry,
        tick_size,
        max_expiry_allocation,
    });
}

public(package) fun emit_market_config_snapshot(
    expiry_market_id: ID,
    strike_exposure_config: &StrikeExposureConfig,
    expiry_cash_config: &ExpiryCashConfig,
) {
    event::emit(MarketConfigSnapshot {
        expiry_market_id,
        terminal_floor_index: strike_exposure_config.terminal_floor_index(),
        liquidation_ltv: strike_exposure_config.liquidation_ltv(),
        backing_buffer_lambda: strike_exposure_config.backing_buffer_lambda(),
        base_fee: strike_exposure_config.base_fee(),
        min_fee: strike_exposure_config.min_fee(),
        min_ask_price: strike_exposure_config.min_ask_price(),
        max_ask_price: strike_exposure_config.max_ask_price(),
        expiry_fee_window_ms: strike_exposure_config.expiry_fee_window_ms(),
        expiry_fee_max_multiplier: strike_exposure_config.expiry_fee_max_multiplier(),
        trading_loss_rebate_rate: expiry_cash_config.trading_loss_rebate_rate(),
    });
}

public(package) fun emit_expiry_market_mint_paused_updated(expiry_market_id: ID, paused: bool) {
    event::emit(ExpiryMarketMintPausedUpdated {
        expiry_market_id,
        paused,
    });
}

public(package) fun emit_market_settled(
    expiry_market_id: ID,
    propbook_underlying_id: u32,
    expiry: u64,
    settlement_price: u64,
    settled_at_ms: u64,
) {
    event::emit(MarketSettled {
        expiry_market_id,
        propbook_underlying_id,
        expiry,
        settlement_price,
        settled_at_ms,
    });
}
