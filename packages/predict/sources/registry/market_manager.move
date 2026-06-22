// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Market identity and deployment cadence manager for Predict.
///
/// `Registry` owns this state and delegates market admission to it. Fixed
/// cadence IDs, periods, and rank order are upgrade-required. Underlying rows,
/// cadence deployment terms, and per-underlying watermarks are stored here.
module deepbook_predict::market_manager;

use deepbook_predict::{config_constants, constants};
use propbook::registry::OracleRegistry;
use sui::{clock::Clock, table::{Self, Table}};

const EUnderlyingNotRegistered: u64 = 0;
const EUnderlyingAlreadyRegistered: u64 = 1;
const ECadenceDisabled: u64 = 2;
const EMarketAlreadyCreated: u64 = 3;
const EInvalidCadence: u64 = 4;
const ECadenceWindowExceeded: u64 = 5;
const EInvalidDeploymentExpiry: u64 = 6;
const EInvalidCadenceConfig: u64 = 7;
const EPythFeedNotBoundToUnderlying: u64 = 8;
const EBlockScholesFeedNotBoundToUnderlying: u64 = 9;

/// Market uniqueness key. Predict permits one market per Propbook underlying and
/// expiry; the market's tick size and allocation cap are committed by creation.
public struct MarketKey has copy, drop, store {
    propbook_underlying_id: u32,
    expiry: u64,
}

/// Stored market deployment policy, market IDs, and per-underlying watermarks.
public struct MarketManager has store {
    /// Propbook underlying ID -> deployment watermarks.
    underlying_configs: Table<u32, UnderlyingMarketConfig>,
    /// Created markets keyed by `(propbook_underlying_id, expiry)`.
    market_ids: Table<MarketKey, ID>,
    /// Deployment config indexed by cadence ID.
    cadences: vector<CadenceConfig>,
}

/// Stored deployment policy for one cadence.
public struct CadenceConfig has copy, drop, store {
    /// Raw-price-per-tick factor snapshotted into each created market.
    tick_size: u64,
    /// DUSDC pool allocation cap snapshotted into pool accounting for each created expiry.
    max_expiry_allocation: u64,
    /// Number of future cadence slots that deployment may keep filled.
    /// Zero disables this cadence.
    window_size: u64,
}

/// Stored deployment watermarks for one Propbook underlying.
public struct UnderlyingMarketConfig has copy, drop, store {
    /// Highest deployed expiry timestamp indexed by cadence ID.
    last_deployed_expiries: vector<u64>,
}

// === Public Macros ===

/// Cadence ID for one-minute markets.
public macro fun cadence_one_minute(): u8 { 0 }

/// Cadence ID for five-minute markets.
public macro fun cadence_five_minute(): u8 { 1 }

/// Cadence ID for one-hour markets.
public macro fun cadence_one_hour(): u8 { 2 }

/// Cadence ID for one-day markets.
public macro fun cadence_one_day(): u8 { 3 }

/// Cadence ID for one-week markets.
public macro fun cadence_one_week(): u8 { 4 }

/// Cadence ID for one-month markets.
public macro fun cadence_one_month(): u8 { 5 }

// === Public-Package Functions ===

public(package) fun new(ctx: &mut TxContext): MarketManager {
    MarketManager {
        underlying_configs: table::new(ctx),
        market_ids: table::new(ctx),
        cadences: disabled_cadences(),
    }
}

public(package) fun expiry_market_id(
    manager: &MarketManager,
    propbook_underlying_id: u32,
    expiry: u64,
): Option<ID> {
    let key = MarketKey { propbook_underlying_id, expiry };
    if (manager.market_ids.contains(key)) {
        option::some(*manager.market_ids.borrow(key))
    } else {
        option::none()
    }
}

public(package) fun cadence_config(manager: &MarketManager, cadence_id: u8): (u64, u64, u64) {
    let cadence = &manager.cadences[cadence_index(cadence_id)];
    (cadence.tick_size, cadence.max_expiry_allocation, cadence.window_size)
}

/// Return the next expiry, tick size, and allocation cap for an underlying/cadence.
///
/// The candidate is the greater of the next watermark slot and the first future
/// slot after the current clock time. Reserved higher-rank cadence slots are skipped,
/// and the selected expiry must still fit inside the cadence window.
public(package) fun next_deployable_market(
    manager: &MarketManager,
    propbook_registry: &OracleRegistry,
    propbook_underlying_id: u32,
    cadence_id: u8,
    clock: &Clock,
): (u64, u64, u64) {
    let cadence_index = cadence_index(cadence_id);
    let cadence = &manager.cadences[cadence_index];
    assert!(cadence.window_size > 0, ECadenceDisabled);

    let underlying = manager.underlying_config(propbook_underlying_id);
    let now_ms = clock.timestamp_ms();
    let period_ms = cadence_period_ms(cadence_id);
    let watermark_candidate = underlying.last_deployed_expiries[cadence_index] + period_ms;
    let next_future_candidate = ((now_ms / period_ms) + 1) * period_ms;
    let mut expiry = watermark_candidate.max(next_future_candidate);
    let window_end = now_ms + cadence.window_size * period_ms;

    while (expiry <= window_end) {
        if (manager.has_higher_rank_overlap(cadence_id, expiry)) {
            expiry = expiry + period_ms;
        } else {
            let key = MarketKey { propbook_underlying_id, expiry };
            assert!(!manager.market_ids.contains(key), EMarketAlreadyCreated);
            assert!(
                propbook_registry.propbook_pyth_id_for_underlying(propbook_underlying_id).is_some(),
                EPythFeedNotBoundToUnderlying,
            );
            assert!(
                propbook_registry
                    .propbook_block_scholes_id_for_underlying(propbook_underlying_id)
                    .is_some(),
                EBlockScholesFeedNotBoundToUnderlying,
            );

            return (expiry, cadence.tick_size, cadence.max_expiry_allocation)
        }
    };

    abort ECadenceWindowExceeded
}

public(package) fun register_underlying(manager: &mut MarketManager, propbook_underlying_id: u32) {
    assert!(
        !manager.underlying_configs.contains(propbook_underlying_id),
        EUnderlyingAlreadyRegistered,
    );
    manager
        .underlying_configs
        .add(
            propbook_underlying_id,
            UnderlyingMarketConfig { last_deployed_expiries: vector[0, 0, 0, 0, 0, 0] },
        );
}

public(package) fun set_cadence_config(
    manager: &mut MarketManager,
    cadence_id: u8,
    tick_size: u64,
    max_expiry_allocation: u64,
    window_size: u64,
) {
    assert_cadence_config(tick_size, max_expiry_allocation, window_size);
    let cadence = &mut manager.cadences[cadence_index(cadence_id)];
    cadence.tick_size = tick_size;
    cadence.max_expiry_allocation = max_expiry_allocation;
    cadence.window_size = window_size;
}

public(package) fun record_expiry_creation(
    manager: &mut MarketManager,
    propbook_underlying_id: u32,
    cadence_id: u8,
    expiry: u64,
    expiry_market_id: ID,
) {
    let cadence_index = cadence_index(cadence_id);
    let period_ms = cadence_period_ms(cadence_id);
    assert!(expiry % period_ms == 0, EInvalidDeploymentExpiry);
    assert!(
        expiry > manager
            .underlying_config(propbook_underlying_id)
            .last_deployed_expiries[cadence_index],
        EInvalidDeploymentExpiry,
    );

    let key = MarketKey { propbook_underlying_id, expiry };
    assert!(!manager.market_ids.contains(key), EMarketAlreadyCreated);
    manager.market_ids.add(key, expiry_market_id);
    let watermark =
        &mut manager
            .underlying_config_mut(propbook_underlying_id)
            .last_deployed_expiries[cadence_index];
    *watermark = expiry;
}

// === Private Functions ===

fun underlying_config(
    manager: &MarketManager,
    propbook_underlying_id: u32,
): &UnderlyingMarketConfig {
    assert!(manager.underlying_configs.contains(propbook_underlying_id), EUnderlyingNotRegistered);
    manager.underlying_configs.borrow(propbook_underlying_id)
}

fun underlying_config_mut(
    manager: &mut MarketManager,
    propbook_underlying_id: u32,
): &mut UnderlyingMarketConfig {
    assert!(manager.underlying_configs.contains(propbook_underlying_id), EUnderlyingNotRegistered);
    manager.underlying_configs.borrow_mut(propbook_underlying_id)
}

fun cadence_period_ms(cadence_id: u8): u64 {
    if (cadence_id == cadence_one_minute!()) {
        constants::one_minute_ms!()
    } else if (cadence_id == cadence_five_minute!()) {
        constants::five_minutes_ms!()
    } else if (cadence_id == cadence_one_hour!()) {
        constants::one_hour_ms!()
    } else if (cadence_id == cadence_one_day!()) {
        constants::one_day_ms!()
    } else if (cadence_id == cadence_one_week!()) {
        constants::one_week_ms!()
    } else {
        assert!(cadence_id == cadence_one_month!(), EInvalidCadence);
        constants::one_month_ms!()
    }
}

fun disabled_cadence(): CadenceConfig {
    CadenceConfig { tick_size: 0, max_expiry_allocation: 0, window_size: 0 }
}

fun disabled_cadences(): vector<CadenceConfig> {
    vector[
        disabled_cadence(),
        disabled_cadence(),
        disabled_cadence(),
        disabled_cadence(),
        disabled_cadence(),
        disabled_cadence(),
    ]
}

fun cadence_index(cadence_id: u8): u64 {
    assert!(cadence_id <= cadence_one_month!(), EInvalidCadence);
    (cadence_id as u64)
}

fun assert_cadence_config(tick_size: u64, max_expiry_allocation: u64, window_size: u64) {
    let disabled = tick_size == 0 && max_expiry_allocation == 0 && window_size == 0;
    if (disabled) return;

    assert!(tick_size > 0 && max_expiry_allocation > 0 && window_size > 0, EInvalidCadenceConfig);
    config_constants::assert_market_tick_size_bounds(tick_size);
    assert!(max_expiry_allocation >= constants::min_expiry_allocation!(), EInvalidCadenceConfig);
}

fun has_higher_rank_overlap(manager: &MarketManager, cadence_id: u8, expiry: u64): bool {
    let mut higher_cadence_id = cadence_id + 1;
    while ((higher_cadence_id as u64) < manager.cadences.length()) {
        let higher_cadence = &manager.cadences[cadence_index(higher_cadence_id)];
        if (
            higher_cadence.window_size > 0
                && expiry % cadence_period_ms(higher_cadence_id) == 0
        ) {
            return true
        };
        higher_cadence_id = higher_cadence_id + 1;
    };
    false
}
