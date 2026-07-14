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
const EBlockScholesSpotFeedNotBoundToUnderlying: u64 = 9;
const EBlockScholesForwardFeedNotBoundToUnderlying: u64 = 10;
const EBlockScholesSVIFeedNotBoundToUnderlying: u64 = 11;

/// Market uniqueness key. Predict permits one market per Propbook underlying and
/// expiry; the market's tick size, allocation cap, and initial cash target are
/// committed by creation.
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
}

/// Stored deployment policy for one cadence.
public struct CadenceConfig has copy, drop, store {
    /// Raw-price-per-tick factor snapshotted into each created market.
    tick_size: u64,
    /// Coarser raw-price step that new finite mint boundaries must align to.
    admission_tick_size: u64,
    /// DUSDC pool allocation cap snapshotted into pool accounting for each created expiry.
    max_expiry_allocation: u64,
    /// Minimum DUSDC cash target snapshotted into pool accounting for each created expiry.
    initial_expiry_cash: u64,
    /// Number of future cadence slots that deployment may keep filled.
    /// Zero disables this cadence; enabled cadences are capped by an upgrade-required bound.
    window_size: u64,
}

/// Next market selected for creation plus the cadence terms to snapshot into it.
public struct DeployableMarket has copy, drop {
    expiry: u64,
    cadence: CadenceConfig,
}

/// Stored deployment policy and watermarks for one Propbook underlying.
public struct UnderlyingMarketConfig has copy, drop, store {
    /// Deployment config indexed by cadence ID.
    cadences: vector<CadenceConfig>,
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

// === Public Functions ===

/// Return the raw-price-per-tick factor for this cadence config.
public fun cadence_tick_size(config: &CadenceConfig): u64 {
    config.tick_size
}

/// Return the coarser raw-price step that new finite mint boundaries must align to.
public fun cadence_admission_tick_size(config: &CadenceConfig): u64 {
    config.admission_tick_size
}

/// Return the DUSDC pool allocation cap snapshotted for each created expiry.
public fun cadence_max_expiry_allocation(config: &CadenceConfig): u64 {
    config.max_expiry_allocation
}

/// Return the minimum DUSDC cash target snapshotted for each created expiry.
public fun cadence_initial_expiry_cash(config: &CadenceConfig): u64 {
    config.initial_expiry_cash
}

/// Return the number of future cadence slots deployment may keep filled.
public fun cadence_window_size(config: &CadenceConfig): u64 {
    config.window_size
}

/// Return whether this cadence is enabled.
public fun cadence_enabled(config: &CadenceConfig): bool {
    config.window_size > 0
}

// === Public-Package Functions ===

public(package) fun new(ctx: &mut TxContext): MarketManager {
    MarketManager {
        underlying_configs: table::new(ctx),
        market_ids: table::new(ctx),
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

/// Return the stored deployment policy for one underlying/cadence.
public(package) fun cadence_config(
    manager: &MarketManager,
    propbook_underlying_id: u32,
    cadence_id: u8,
): CadenceConfig {
    let cadence_index = cadence_index(cadence_id);
    let cadence = &manager.underlying_config(propbook_underlying_id).cadences[cadence_index];
    *cadence
}

/// Return the next expiry and snapshotted cadence terms for an underlying/cadence.
///
/// The candidate is the greater of the next watermark slot and the first future
/// slot after the current clock time. Reserved higher-rank cadence slots and
/// already-created markets are skipped, and the selected expiry must still fit
/// inside the cadence window.
public(package) fun next_deployable_market(
    manager: &MarketManager,
    propbook_registry: &OracleRegistry,
    propbook_underlying_id: u32,
    cadence_id: u8,
    clock: &Clock,
): DeployableMarket {
    let cadence_index = cadence_index(cadence_id);
    let underlying = manager.underlying_config(propbook_underlying_id);
    let cadence = &underlying.cadences[cadence_index];
    assert!(cadence.window_size > 0, ECadenceDisabled);

    let now_ms = clock.timestamp_ms();
    let period_ms = cadence_period_ms(cadence_id);
    let watermark_candidate = underlying.last_deployed_expiries[cadence_index] + period_ms;
    let next_future_candidate = ((now_ms / period_ms) + 1) * period_ms;
    let mut expiry = watermark_candidate.max(next_future_candidate);
    let window_end = now_ms + cadence.window_size * period_ms;

    while (expiry <= window_end) {
        let key = MarketKey { propbook_underlying_id, expiry };
        if (
            has_higher_rank_overlap(underlying, cadence_id, expiry)
                || manager.market_ids.contains(key)
        ) {
            expiry = expiry + period_ms;
        } else {
            assert!(
                propbook_registry.propbook_pyth_id_for_underlying(propbook_underlying_id).is_some(),
                EPythFeedNotBoundToUnderlying,
            );
            assert!(
                propbook_registry
                    .propbook_block_scholes_spot_id_for_underlying(propbook_underlying_id)
                    .is_some(),
                EBlockScholesSpotFeedNotBoundToUnderlying,
            );
            assert!(
                propbook_registry
                    .propbook_block_scholes_forward_id_for_underlying(propbook_underlying_id)
                    .is_some(),
                EBlockScholesForwardFeedNotBoundToUnderlying,
            );
            // Structurally unreachable at HEAD: Propbook binds forward and SVI
            // atomically (bind/replace take the whole surface), so a missing SVI
            // binding always trips the forward assert above first. Kept as
            // defense-in-depth should the binding API ever split.
            assert!(
                propbook_registry
                    .propbook_block_scholes_svi_id_for_underlying(propbook_underlying_id)
                    .is_some(),
                EBlockScholesSVIFeedNotBoundToUnderlying,
            );

            return DeployableMarket {
                expiry,
                cadence: *cadence,
            }
        }
    };

    abort ECadenceWindowExceeded
}

public(package) fun expiry(deployable: &DeployableMarket): u64 {
    deployable.expiry
}

public(package) fun tick_size(deployable: &DeployableMarket): u64 {
    deployable.cadence.tick_size
}

public(package) fun admission_tick_size(deployable: &DeployableMarket): u64 {
    deployable.cadence.admission_tick_size
}

public(package) fun cadence_period_ms(cadence_id: u8): u64 {
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

public(package) fun max_expiry_allocation(deployable: &DeployableMarket): u64 {
    deployable.cadence.max_expiry_allocation
}

public(package) fun initial_expiry_cash(deployable: &DeployableMarket): u64 {
    deployable.cadence.initial_expiry_cash
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
            UnderlyingMarketConfig {
                cadences: disabled_cadences(),
                last_deployed_expiries: vector[0, 0, 0, 0, 0, 0],
            },
        );
}

public(package) fun set_template_cadence_config(
    manager: &mut MarketManager,
    propbook_underlying_id: u32,
    cadence_id: u8,
    tick_size: u64,
    admission_tick_size: u64,
    max_expiry_allocation: u64,
    initial_expiry_cash: u64,
    window_size: u64,
) {
    let config = CadenceConfig {
        tick_size,
        admission_tick_size,
        max_expiry_allocation,
        initial_expiry_cash,
        window_size,
    };
    assert_cadence_config(&config);
    let cadence_index = cadence_index(cadence_id);
    let cadence =
        &mut manager.underlying_config_mut(propbook_underlying_id).cadences[cadence_index];
    *cadence = config;
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
    // Both EInvalidDeploymentExpiry asserts are structurally unreachable via
    // `registry::create_and_share_expiry_market`: the expiry always comes from
    // `next_deployable_market`, which yields grid-aligned values strictly above
    // the watermark. Kept as internal-invariant guards for any future caller.
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

fun disabled_cadence(): CadenceConfig {
    CadenceConfig {
        tick_size: 0,
        admission_tick_size: 0,
        max_expiry_allocation: 0,
        initial_expiry_cash: 0,
        window_size: 0,
    }
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

fun assert_cadence_config(config: &CadenceConfig) {
    let CadenceConfig {
        tick_size,
        admission_tick_size,
        max_expiry_allocation,
        initial_expiry_cash,
        window_size,
    } = *config;
    let disabled =
        tick_size == 0
            && admission_tick_size == 0
            && max_expiry_allocation == 0
            && initial_expiry_cash == 0
            && window_size == 0;
    if (disabled) return;

    assert!(
        tick_size > 0
            && admission_tick_size > 0
            && max_expiry_allocation > 0
            && initial_expiry_cash > 0
            && window_size > 0,
        EInvalidCadenceConfig,
    );
    config_constants::assert_market_tick_size_bounds(tick_size);
    config_constants::assert_market_tick_size_bounds(admission_tick_size);
    // >= tick_size follows: admission_tick_size > 0 and divisible by tick_size
    // forces a multiple k >= 1.
    assert!(admission_tick_size % tick_size == 0, EInvalidCadenceConfig);
    config_constants::assert_cadence_window_size(window_size);
    assert!(initial_expiry_cash >= constants::expiry_cash_floor!(), EInvalidCadenceConfig);
    assert!(initial_expiry_cash <= max_expiry_allocation, EInvalidCadenceConfig);
}

fun has_higher_rank_overlap(
    underlying: &UnderlyingMarketConfig,
    cadence_id: u8,
    expiry: u64,
): bool {
    let mut higher_cadence_id = cadence_id + 1;
    while ((higher_cadence_id as u64) < underlying.cadences.length()) {
        let higher_cadence = &underlying.cadences[cadence_index(higher_cadence_id)];
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
