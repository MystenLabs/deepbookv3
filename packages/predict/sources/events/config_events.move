// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Admin and configuration events for Predict.
module deepbook_predict::config_events;

use deepbook_predict::strike_exposure_config::StrikeExposureConfig;
use sui::event;

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

/// Emitted when a keeper publishes one underlying's quote calibration correction.
/// Carries the whole table, so an indexer can reconstruct the correction in force
/// at any time without reading protocol state.
public struct QuoteCalibrationPublished has copy, drop, store {
    protocol_config_id: ID,
    propbook_underlying_id: u32,
    /// Corrected probabilities in FLOAT_SCALING, row-major over the time and
    /// probability grids the package compiles in.
    knots: vector<u64>,
    /// On-chain landing time of the publication, `clock.timestamp_ms()`.
    published_at_ms: u64,
}

/// Emitted when quote calibration is switched on or off. The switch emits
/// because it is a safety control, like the trading pause and the protocol
/// freeze; the staleness window and the deviation cap are ordinary policy and
/// stay silent, as every other economic knob on this object does.
public struct QuoteCalibrationEnabledUpdated has copy, drop, store {
    protocol_config_id: ID,
    enabled: bool,
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
    /// DUSDC pool allocation cap snapshotted for this expiry.
    max_expiry_allocation: u64,
    /// Minimum DUSDC cash target snapshotted for this expiry.
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

public(package) fun emit_protocol_frozen_updated(protocol_config_id: ID, frozen: bool) {
    event::emit(ProtocolFrozenUpdated {
        protocol_config_id,
        frozen,
    });
}

public(package) fun emit_quote_calibration_published(
    protocol_config_id: ID,
    propbook_underlying_id: u32,
    knots: vector<u64>,
    published_at_ms: u64,
) {
    event::emit(QuoteCalibrationPublished {
        protocol_config_id,
        propbook_underlying_id,
        knots,
        published_at_ms,
    });
}

public(package) fun emit_quote_calibration_enabled_updated(protocol_config_id: ID, enabled: bool) {
    event::emit(QuoteCalibrationEnabledUpdated {
        protocol_config_id,
        enabled,
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
