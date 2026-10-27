// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Market identity and deployment cadence manager for Predict.
///
/// `Registry` owns this state and delegates market admission to it. Cadence periods
/// live in the registry's admin-extended cadence table and are passed in, indexed by
/// cadence ID; underlying rows, cadence deployment terms, and per-underlying
/// watermarks are stored here. When two enabled cadences can create the same expiry,
/// the one with the longer period owns it.
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
const EBlockScholesStoresNotBoundToUnderlying: u64 = 9;
const ECadenceTableFull: u64 = 10;
const EInvalidCadencePeriod: u64 = 11;
const ECadencePeriodExists: u64 = 12;
const ECadenceWindowBudgetExceeded: u64 = 13;

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
    /// USDC pool allocation cap snapshotted into pool accounting for each created expiry.
    max_expiry_allocation: u64,
    /// Minimum USDC cash target snapshotted into pool accounting for each created expiry.
    initial_expiry_cash: u64,
    /// Number of cadence periods in the rolling future deployment horizon.
    /// Zero disables this cadence.
    window_size: u64,
}

/// Next market selected for creation plus the cadence terms to snapshot into it.
public struct DeployableMarket has copy, drop {
    expiry: u64,
    cadence: CadenceConfig,
}

/// Stored deployment policy and watermarks for one Propbook underlying.
public struct UnderlyingMarketConfig has copy, drop, store {
    /// Deployment config indexed by cadence ID. Rows past its length (cadences added
    /// after the underlying was registered) are disabled until the admin sets them.
    cadences: vector<CadenceConfig>,
    /// Highest deployed expiry timestamp indexed by cadence ID; missing rows are 0.
    last_deployed_expiries: vector<u64>,
}

// === Public Macros ===

/// Built-in cadence ID for one-minute markets.
public macro fun cadence_one_minute(): u8 { 0 }

/// Built-in cadence ID for five-minute markets.
public macro fun cadence_five_minute(): u8 { 1 }

/// Built-in cadence ID for one-hour markets.
public macro fun cadence_one_hour(): u8 { 2 }

/// Built-in cadence ID for one-day markets.
public macro fun cadence_one_day(): u8 { 3 }

/// Built-in cadence ID for one-week markets.
public macro fun cadence_one_week(): u8 { 4 }

/// Built-in cadence ID for one-month (30-day) markets.
public macro fun cadence_one_month(): u8 { 5 }

/// Most cadences the table holds, bounding the slot-rule scan in `next_deploy`.
macro fun max_cadences(): u64 { 16 }

// === Public Functions ===

/// Return the raw-price-per-tick factor for SDK and devInspect cadence reads.
public fun cadence_tick_size(config: &CadenceConfig): u64 {
    config.tick_size
}

/// Return the admission-grid step for SDK and devInspect cadence reads.
public fun cadence_admission_tick_size(config: &CadenceConfig): u64 {
    config.admission_tick_size
}

/// Return the expiry allocation cap for SDK and devInspect cadence reads.
public fun cadence_max_expiry_allocation(config: &CadenceConfig): u64 {
    config.max_expiry_allocation
}

/// Return the initial expiry cash target for SDK and devInspect cadence reads.
public fun cadence_initial_expiry_cash(config: &CadenceConfig): u64 {
    config.initial_expiry_cash
}

/// Return the rolling deployment horizon for SDK and devInspect cadence reads.
public fun cadence_window_size(config: &CadenceConfig): u64 {
    config.window_size
}

/// Return whether this cadence is enabled for SDK and devInspect discovery.
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
    periods: &vector<u64>,
    propbook_underlying_id: u32,
    cadence_id: u8,
): CadenceConfig {
    let cadence_index = cad_index(periods, cadence_id);
    manager.und_config(propbook_underlying_id).cad_at(cadence_index)
}

/// Return every deployment policy for one underlying, one entry per cadence in
/// `periods` and indexed by cadence ID.
public(package) fun cadence_configs(
    manager: &MarketManager,
    periods: &vector<u64>,
    propbook_underlying_id: u32,
): vector<CadenceConfig> {
    let underlying = manager.und_config(propbook_underlying_id);
    vector::tabulate!(periods.length(), |cadence_index| underlying.cad_at(cadence_index))
}

/// Return the next expiry and snapshotted cadence terms for an underlying/cadence.
///
/// The candidate is the greater of the next watermark slot and the first future
/// slot after the current clock time. Slots owned by a longer enabled cadence and
/// already-created markets are skipped, and the selected expiry must still fit
/// inside the cadence window.
public(package) fun next_deploy(
    manager: &MarketManager,
    periods: &vector<u64>,
    propbook_registry: &OracleRegistry,
    propbook_underlying_id: u32,
    cadence_id: u8,
    clock: &Clock,
): DeployableMarket {
    let cadence_index = cad_index(periods, cadence_id);
    let underlying = manager.und_config(propbook_underlying_id);
    let cadence = underlying.cad_at(cadence_index);
    assert!(cadence.window_size > 0, ECadenceDisabled);

    let now_ms = clock.timestamp_ms();
    let period_ms = periods[cadence_index];
    let watermark_candidate = underlying.mark_at(cadence_index) + period_ms;
    let next_future_candidate = ((now_ms / period_ms) + 1) * period_ms;
    let mut expiry = watermark_candidate.max(next_future_candidate);
    let window_end = now_ms + cadence.window_size * period_ms;

    while (expiry <= window_end) {
        let key = MarketKey { propbook_underlying_id, expiry };
        if (
            rank_overlap(underlying, periods, period_ms, expiry)
                || manager.market_ids.contains(key)
        ) {
            expiry = expiry + period_ms;
        } else {
            assert!(
                propbook_registry.propbook_pyth_id_for_underlying(propbook_underlying_id).is_some(),
                EPythFeedNotBoundToUnderlying,
            );
            // Propbook creates both stores and their source identity atomically in one registry
            // row, so this one check proves the complete Block Scholes binding exists.
            assert!(
                propbook_registry
                    .propbook_block_scholes_store_pair_for_underlying(propbook_underlying_id)
                    .is_some(),
                EBlockScholesStoresNotBoundToUnderlying,
            );

            return DeployableMarket { expiry, cadence }
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

public(package) fun cad_period(periods: &vector<u64>, cadence_id: u8): u64 {
    periods[cad_index(periods, cadence_id)]
}

/// The cadence table every registry starts with: the six built-in cadences'
/// periods, indexed by their built-in IDs.
public(package) fun base_periods(): vector<u64> {
    vector[
        constants::one_minute_ms!(),
        constants::five_minutes_ms!(),
        constants::one_hour_ms!(),
        constants::one_day_ms!(),
        constants::one_week_ms!(),
        constants::one_month_ms!(),
    ]
}

/// Append a cadence period to the table and return its cadence ID. The period must
/// be a positive whole number of resolution periods (the settlement grid), at most
/// one year, and not already in the table, and the table must have room.
public(package) fun add_period(periods: &mut vector<u64>, period_ms: u64): u8 {
    assert!(
        period_ms > 0
            && period_ms % constants::resolution_period_ms!() == 0
            && period_ms <= constants::one_year_ms!(),
        EInvalidCadencePeriod,
    );
    assert!(!periods.contains(&period_ms), ECadencePeriodExists);
    assert!(periods.length() < max_cadences!(), ECadenceTableFull);
    periods.push_back(period_ms);
    (periods.length() - 1) as u8
}

public(package) fun max_alloc(deployable: &DeployableMarket): u64 {
    deployable.cadence.max_expiry_allocation
}

public(package) fun init_cash(deployable: &DeployableMarket): u64 {
    deployable.cadence.initial_expiry_cash
}

public(package) fun register_underlying(
    manager: &mut MarketManager,
    periods: &vector<u64>,
    propbook_underlying_id: u32,
) {
    assert!(
        !manager.underlying_configs.contains(propbook_underlying_id),
        EUnderlyingAlreadyRegistered,
    );
    manager
        .underlying_configs
        .add(
            propbook_underlying_id,
            UnderlyingMarketConfig {
                cadences: vector::tabulate!(periods.length(), |_| cad_disabled()),
                last_deployed_expiries: vector::tabulate!(periods.length(), |_| 0),
            },
        );
}

/// Set one underlying's terms for one cadence. The sum of the underlying's enabled
/// windows may not exceed `constants::max_live_expiry_markets`: each enabled cadence
/// keeps at most `window_size` markets live, and the pool refuses to register a live
/// market past that cap.
public(package) fun set_template_cadence_config(
    manager: &mut MarketManager,
    periods: &vector<u64>,
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
    chk_cadence(&config);
    let cadence_index = cad_index(periods, cadence_id);
    let underlying = manager.und_cfg_mut(propbook_underlying_id);
    underlying.pad_rows(periods.length());
    *&mut underlying.cadences[cadence_index] = config;
    let mut window_sum = 0;
    underlying.cadences.do_ref!(|cadence| window_sum = window_sum + cadence.window_size);
    assert!(window_sum <= constants::max_live_expiry_markets!(), ECadenceWindowBudgetExceeded);
}

public(package) fun note_expiry(
    manager: &mut MarketManager,
    periods: &vector<u64>,
    propbook_underlying_id: u32,
    cadence_id: u8,
    expiry: u64,
    expiry_market_id: ID,
) {
    let cadence_index = cad_index(periods, cadence_id);
    // Preserve grid alignment and monotonic cadence watermarks at persistence.
    assert!(expiry % periods[cadence_index] == 0, EInvalidDeploymentExpiry);
    assert!(
        expiry > manager.und_config(propbook_underlying_id).mark_at(cadence_index),
        EInvalidDeploymentExpiry,
    );

    let key = MarketKey { propbook_underlying_id, expiry };
    assert!(!manager.market_ids.contains(key), EMarketAlreadyCreated);
    manager.market_ids.add(key, expiry_market_id);
    let underlying = manager.und_cfg_mut(propbook_underlying_id);
    underlying.pad_rows(periods.length());
    *&mut underlying.last_deployed_expiries[cadence_index] = expiry;
}

// === Private Functions ===

fun und_config(manager: &MarketManager, propbook_underlying_id: u32): &UnderlyingMarketConfig {
    assert!(manager.underlying_configs.contains(propbook_underlying_id), EUnderlyingNotRegistered);
    manager.underlying_configs.borrow(propbook_underlying_id)
}

fun und_cfg_mut(
    manager: &mut MarketManager,
    propbook_underlying_id: u32,
): &mut UnderlyingMarketConfig {
    assert!(manager.underlying_configs.contains(propbook_underlying_id), EUnderlyingNotRegistered);
    manager.underlying_configs.borrow_mut(propbook_underlying_id)
}

fun cad_disabled(): CadenceConfig {
    CadenceConfig {
        tick_size: 0,
        admission_tick_size: 0,
        max_expiry_allocation: 0,
        initial_expiry_cash: 0,
        window_size: 0,
    }
}

fun cad_index(periods: &vector<u64>, cadence_id: u8): u64 {
    assert!((cadence_id as u64) < periods.length(), EInvalidCadence);
    (cadence_id as u64)
}

fun cad_at(underlying: &UnderlyingMarketConfig, cadence_index: u64): CadenceConfig {
    if (cadence_index < underlying.cadences.length()) underlying.cadences[cadence_index]
    else cad_disabled()
}

fun mark_at(underlying: &UnderlyingMarketConfig, cadence_index: u64): u64 {
    if (cadence_index < underlying.last_deployed_expiries.length()) {
        underlying.last_deployed_expiries[cadence_index]
    } else 0
}

/// Extend an underlying's rows to `count` cadences, new rows disabled with a zero
/// watermark. Rows written before a cadence was added are shorter than the table.
fun pad_rows(underlying: &mut UnderlyingMarketConfig, count: u64) {
    while (underlying.cadences.length() < count) underlying.cadences.push_back(cad_disabled());
    while (underlying.last_deployed_expiries.length() < count) {
        underlying.last_deployed_expiries.push_back(0)
    };
}

fun chk_cadence(config: &CadenceConfig) {
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
    config_constants::chk_ticks(tick_size);
    config_constants::chk_ticks(admission_tick_size);
    assert!(admission_tick_size >= tick_size, EInvalidCadenceConfig);
    assert!(admission_tick_size % tick_size == 0, EInvalidCadenceConfig);
    config_constants::chk_cad_win(window_size);
    assert!(initial_expiry_cash >= constants::expiry_cash_floor!(), EInvalidCadenceConfig);
    assert!(initial_expiry_cash <= max_expiry_allocation, EInvalidCadenceConfig);
}

/// Whether an enabled cadence with a period longer than `period_ms` owns `expiry`,
/// i.e. its period divides it. Rows past the underlying's stored length are disabled.
fun rank_overlap(
    underlying: &UnderlyingMarketConfig,
    periods: &vector<u64>,
    period_ms: u64,
    expiry: u64,
): bool {
    let mut cadence_index = 0;
    while (cadence_index < underlying.cadences.length()) {
        let other_period_ms = periods[cadence_index];
        if (
            other_period_ms > period_ms
                && underlying.cadences[cadence_index].window_size > 0
                && expiry % other_period_ms == 0
        ) {
            return true
        };
        cadence_index = cadence_index + 1;
    };
    false
}
