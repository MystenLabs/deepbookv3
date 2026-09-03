// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Admin and configuration events for Predict.
module deepbook_predict::config_events;

use deepbook_predict::{
    ewma_config::EwmaConfig,
    pricing_config::PricingConfig,
    strike_exposure_config::StrikeExposureConfig
};
use sui::event;

/// Emitted when the strike-exposure policy template for future markets changes.
public struct StrikeExposureTemplateConfigUpdated has copy, drop, store {
    backing_buffer_lambda: u64,
    base_fee: u64,
    min_fee: u64,
    min_entry_probability: u64,
    max_entry_probability: u64,
    expiry_fee_window_ms: u64,
    expiry_fee_max_multiplier: u64,
    inventory_impact_max_rate: u64,
    onchain_timestamp_ms: u64,
}

/// Emitted when live pricing policy changes.
public struct PricingConfigUpdated has copy, drop, store {
    use_pyth_spot_for_forward: bool,
    pyth_spot_freshness_ms: u64,
    block_scholes_price_freshness_ms: u64,
    block_scholes_svi_freshness_ms: u64,
    onchain_timestamp_ms: u64,
}

/// Emitted when the EWMA gas-price penalty policy changes.
public struct EwmaConfigUpdated has copy, drop, store {
    alpha: u64,
    z_score_threshold: u64,
    penalty_rate: u64,
    enabled: bool,
    onchain_timestamp_ms: u64,
}

/// Emitted when either PLP fee rate changes.
public struct PlpFeeRatesUpdated has copy, drop, store {
    plp_supply_fee_rate: u64,
    plp_withdraw_fee_rate: u64,
    onchain_timestamp_ms: u64,
}

/// Emitted when global trading pause state changes.
public struct TradingPausedUpdated has copy, drop, store {
    protocol_config_id: ID,
    paused: bool,
}

/// Emitted when the protocol-wide emergency freeze state changes.
public struct ProtocolFrozenUpdated has copy, drop, store {
    protocol_config_id: ID,
    frozen: bool,
}

/// Emitted when a new expiry market is created, with its cadence terms and
/// immutable expiry-policy snapshot. Fraction, fee, probability, and multiplier
/// fields use FLOAT_SCALING; windows use milliseconds.
public struct MarketCreated has copy, drop, store {
    expiry_market_id: ID,
    pool_vault_id: ID,
    /// Propbook underlying this market resolves current oracle bindings through.
    propbook_underlying_id: u32,
    expiry: u64,
    /// Raw-price-per-tick factor; indexers/SDKs derive raw strikes as `tick * tick_size`.
    tick_size: u64,
    /// Coarser raw-price step that new finite mint boundaries must align to.
    admission_tick_size: u64,
    /// USDC pool allocation cap snapshotted for this expiry.
    max_expiry_allocation: u64,
    /// Minimum USDC cash target snapshotted for this expiry.
    initial_expiry_cash: u64,
    backing_buffer_lambda: u64,
    base_fee: u64,
    min_fee: u64,
    min_entry_probability: u64,
    max_entry_probability: u64,
    expiry_fee_window_ms: u64,
    expiry_fee_max_multiplier: u64,
    /// Maximum marginal inventory-impact rate snapshotted by this market.
    inventory_impact_max_rate: u64,
}

/// Emitted when an admin updates or disables one underlying's cadence policy.
/// Passing zero for all numeric policy fields disables the cadence.
public struct CadenceConfigUpdated has copy, drop, store {
    registry_id: ID,
    propbook_underlying_id: u32,
    cadence_id: u8,
    tick_size: u64,
    admission_tick_size: u64,
    max_expiry_allocation: u64,
    initial_expiry_cash: u64,
    window_size: u64,
}

/// Emitted when minting pause state changes for one expiry market.
public struct ExpiryMarketMintPausedUpdated has copy, drop, store {
    expiry_market_id: ID,
    paused: bool,
}

/// Emitted when a market records its reference fine-grid tick from the exact
/// previous-window Propbook Pyth observation.
public struct ReferenceTickSet has copy, drop, store {
    expiry_market_id: ID,
    propbook_underlying_id: u32,
    source_timestamp_ms: u64,
    spot: u64,
    tick: u64,
    onchain_timestamp_ms: u64,
}

/// Emitted once when a market records its terminal settlement price from exact Propbook history.
public struct MarketSettled has copy, drop, store {
    expiry_market_id: ID,
    propbook_underlying_id: u32,
    expiry: u64,
    settlement_price: u64,
    /// `0` = Pyth and `1` = Block Scholes.
    settlement_source: u8,
    /// On-chain landing time of the settlement, `clock.timestamp_ms()`.
    onchain_timestamp_ms: u64,
}

// === Public-Package Functions ===

public(package) fun emit_strike_exposure_template_config_updated(
    config: &StrikeExposureConfig,
    onchain_timestamp_ms: u64,
) {
    event::emit(StrikeExposureTemplateConfigUpdated {
        backing_buffer_lambda: config.backing_buffer_lambda(),
        base_fee: config.base_fee(),
        min_fee: config.min_fee(),
        min_entry_probability: config.min_entry_probability(),
        max_entry_probability: config.max_entry_probability(),
        expiry_fee_window_ms: config.expiry_fee_window_ms(),
        expiry_fee_max_multiplier: config.expiry_fee_max_multiplier(),
        inventory_impact_max_rate: config.inventory_impact_max_rate(),
        onchain_timestamp_ms,
    });
}

public(package) fun emit_pricing_config_updated(config: &PricingConfig, onchain_timestamp_ms: u64) {
    event::emit(PricingConfigUpdated {
        use_pyth_spot_for_forward: config.use_pyth_spot_for_forward(),
        pyth_spot_freshness_ms: config.pyth_spot_freshness_ms(),
        block_scholes_price_freshness_ms: config.block_scholes_price_freshness_ms(),
        block_scholes_svi_freshness_ms: config.block_scholes_svi_freshness_ms(),
        onchain_timestamp_ms,
    });
}

public(package) fun emit_ewma_config_updated(config: &EwmaConfig, onchain_timestamp_ms: u64) {
    event::emit(EwmaConfigUpdated {
        alpha: config.alpha(),
        z_score_threshold: config.z_score_threshold(),
        penalty_rate: config.penalty_rate(),
        enabled: config.enabled(),
        onchain_timestamp_ms,
    });
}

public(package) fun emit_plp_fee_rates_updated(
    plp_supply_fee_rate: u64,
    plp_withdraw_fee_rate: u64,
    onchain_timestamp_ms: u64,
) {
    event::emit(PlpFeeRatesUpdated {
        plp_supply_fee_rate,
        plp_withdraw_fee_rate,
        onchain_timestamp_ms,
    });
}

public(package) fun emit_trading_paused_updated(protocol_config_id: ID, paused: bool) {
    event::emit(TradingPausedUpdated {
        protocol_config_id,
        paused,
    });
}

public(package) fun emit_protocol_frozen_updated(protocol_config_id: ID, frozen: bool) {
    event::emit(ProtocolFrozenUpdated {
        protocol_config_id,
        frozen,
    });
}

public(package) fun emit_market_created(
    expiry_market_id: ID,
    pool_vault_id: ID,
    propbook_underlying_id: u32,
    expiry: u64,
    tick_size: u64,
    admission_tick_size: u64,
    max_expiry_allocation: u64,
    initial_expiry_cash: u64,
    strike_exposure_config: &StrikeExposureConfig,
) {
    event::emit(MarketCreated {
        expiry_market_id,
        pool_vault_id,
        propbook_underlying_id,
        expiry,
        tick_size,
        admission_tick_size,
        max_expiry_allocation,
        initial_expiry_cash,
        backing_buffer_lambda: strike_exposure_config.backing_buffer_lambda(),
        base_fee: strike_exposure_config.base_fee(),
        min_fee: strike_exposure_config.min_fee(),
        min_entry_probability: strike_exposure_config.min_entry_probability(),
        max_entry_probability: strike_exposure_config.max_entry_probability(),
        expiry_fee_window_ms: strike_exposure_config.expiry_fee_window_ms(),
        expiry_fee_max_multiplier: strike_exposure_config.expiry_fee_max_multiplier(),
        inventory_impact_max_rate: strike_exposure_config.inventory_impact_max_rate(),
    });
}

public(package) fun emit_cadence_config_updated(
    registry_id: ID,
    propbook_underlying_id: u32,
    cadence_id: u8,
    tick_size: u64,
    admission_tick_size: u64,
    max_expiry_allocation: u64,
    initial_expiry_cash: u64,
    window_size: u64,
) {
    event::emit(CadenceConfigUpdated {
        registry_id,
        propbook_underlying_id,
        cadence_id,
        tick_size,
        admission_tick_size,
        max_expiry_allocation,
        initial_expiry_cash,
        window_size,
    });
}

public(package) fun emit_expiry_market_mint_paused_updated(expiry_market_id: ID, paused: bool) {
    event::emit(ExpiryMarketMintPausedUpdated {
        expiry_market_id,
        paused,
    });
}

public(package) fun emit_reference_tick_set(
    expiry_market_id: ID,
    propbook_underlying_id: u32,
    source_timestamp_ms: u64,
    spot: u64,
    tick: u64,
    onchain_timestamp_ms: u64,
) {
    event::emit(ReferenceTickSet {
        expiry_market_id,
        propbook_underlying_id,
        source_timestamp_ms,
        spot,
        tick,
        onchain_timestamp_ms,
    });
}

public(package) fun emit_market_settled(
    expiry_market_id: ID,
    propbook_underlying_id: u32,
    expiry: u64,
    settlement_price: u64,
    settlement_source: u8,
    onchain_timestamp_ms: u64,
) {
    event::emit(MarketSettled {
        expiry_market_id,
        propbook_underlying_id,
        expiry,
        settlement_price,
        settlement_source,
        onchain_timestamp_ms,
    });
}
