// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Admin and configuration events for Predict.
module deepbook_predict::config_events;

use deepbook_predict::{
    expiry_cash_config::ExpiryCashConfig,
    strike_exposure_config::StrikeExposureConfig
};
use sui::event;

/// Emitted when global trading pause state changes.
public struct TradingPausedUpdated has copy, drop, store {
    protocol_config_id: ID,
    paused: bool,
}

/// Emitted when a new expiry market is created, with its cadence terms and
/// immutable expiry-policy snapshot. Fraction, leverage, fee, probability, and
/// multiplier fields use FLOAT_SCALING; windows use milliseconds.
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
    /// DUSDC pool allocation cap snapshotted for this expiry.
    max_expiry_allocation: u64,
    /// Minimum DUSDC cash target snapshotted for this expiry.
    initial_expiry_cash: u64,
    liquidation_ltv: u64,
    max_admission_leverage: u64,
    backing_buffer_lambda: u64,
    base_fee: u64,
    min_fee: u64,
    min_entry_probability: u64,
    max_entry_probability: u64,
    expiry_fee_window_ms: u64,
    expiry_fee_max_multiplier: u64,
    /// Window before expiry within which this market admits no leverage above 1x.
    no_leverage_window_ms: u64,
    trading_loss_rebate_rate: u64,
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
    recorded_at_ms: u64,
}

/// Emitted once when a market records its terminal settlement price from the
/// exact-expiry Propbook Pyth observation.
public struct MarketSettled has copy, drop, store {
    expiry_market_id: ID,
    propbook_underlying_id: u32,
    expiry: u64,
    settlement_price: u64,
    /// On-chain landing time of the settlement, `clock.timestamp_ms()`.
    settled_at_ms: u64,
}

// === Public-Package Functions ===

public(package) fun emit_trading_paused_updated(protocol_config_id: ID, paused: bool) {
    event::emit(TradingPausedUpdated {
        protocol_config_id,
        paused,
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
    expiry_cash_config: &ExpiryCashConfig,
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
        liquidation_ltv: strike_exposure_config.liquidation_ltv(),
        max_admission_leverage: strike_exposure_config.max_admission_leverage(),
        backing_buffer_lambda: strike_exposure_config.backing_buffer_lambda(),
        base_fee: strike_exposure_config.base_fee(),
        min_fee: strike_exposure_config.min_fee(),
        min_entry_probability: strike_exposure_config.min_entry_probability(),
        max_entry_probability: strike_exposure_config.max_entry_probability(),
        expiry_fee_window_ms: strike_exposure_config.expiry_fee_window_ms(),
        expiry_fee_max_multiplier: strike_exposure_config.expiry_fee_max_multiplier(),
        no_leverage_window_ms: strike_exposure_config.no_leverage_window_ms(),
        trading_loss_rebate_rate: expiry_cash_config.trading_loss_rebate_rate(),
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
    recorded_at_ms: u64,
) {
    event::emit(ReferenceTickSet {
        expiry_market_id,
        propbook_underlying_id,
        source_timestamp_ms,
        spot,
        tick,
        recorded_at_ms,
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
