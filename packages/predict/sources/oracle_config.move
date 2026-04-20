// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Predict-owned configuration layer on top of the core oracle.
///
/// This module stores the admin-tuned staleness thresholds, per-asset basis
/// circuit-breaker bounds, per-oracle strike grids, and per-oracle ask-bound
/// overrides. At oracle creation the thresholds + per-asset bounds are
/// snapshotted into an `OracleBounds` on the oracle itself
/// (`build_oracle_bounds`), so post-creation `oracle::update_prices` and
/// `oracle::update_spot_from_lazer` never need to read from Predict.
module deepbook_predict::oracle_config;

use deepbook_predict::{
    constants,
    market_key::MarketKey,
    oracle::{Self, OracleBounds, OracleSVI, OracleSVICap},
    range_key::RangeKey
};
use std::string::String;
use sui::table::{Self, Table};

// === Errors ===
const EMarketKeyOracleMismatch: u64 = 0;
const EMarketKeyExpiryMismatch: u64 = 1;
const EInvalidStrike: u64 = 2;
const EOracleConfigNotFound: u64 = 3;
const EInvalidCurveRange: u64 = 4;
const ERangeKeyOracleMismatch: u64 = 5;
const ERangeKeyExpiryMismatch: u64 = 6;
const EInvalidAskBound: u64 = 7;
const EInvalidStalenessThreshold: u64 = 8;
const EInvalidBasisBounds: u64 = 9;
const EFeedIdNotConfigured: u64 = 10;

public struct OracleGrid has copy, drop, store {
    min_strike: u64,
    max_strike: u64,
    tick_size: u64,
}

/// Per-oracle override on the protocol-wide ask-price bounds enforced at mint.
/// Present in `OracleConfig.oracle_ask_bounds` only when the oracle has set an
/// override; otherwise the global default on `PricingConfig` applies.
public struct AskBounds has copy, drop, store {
    min_ask_price: u64,
    max_ask_price: u64,
}

/// Per-asset basis circuit-breaker bounds. Snapshotted onto each new oracle
/// (by underlying asset) at `create_oracle`. Updating an entry here does NOT
/// retroactively change existing oracles — operators tune their own oracle
/// via `oracle::set_basis_bounds` if they need to diverge from the default.
public struct BasisBounds has copy, drop, store {
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
}

public struct OracleConfig has store {
    oracle_grids: Table<ID, OracleGrid>,
    /// Per-oracle ask-bound overrides; presence in this table means an override
    /// is active for that oracle id.
    oracle_ask_bounds: Table<ID, AskBounds>,
    /// Per-underlying-asset basis circuit-breaker bounds. Looked up by the
    /// oracle's `underlying_asset` at `create_oracle`; assets with no entry
    /// fall back to the `constants::default_*!()` basis-bound macros.
    asset_basis_bounds: Table<String, BasisBounds>,
    /// Per-underlying-asset Pyth Lazer feed ids. Admin must register an entry
    /// before `create_oracle` can be called for that asset; the feed id is
    /// snapshotted onto the new oracle and drives permissionless
    /// `oracle::update_spot_from_lazer`. Stored as `u64` for type consistency
    /// with the other scalars on `OracleConfig`; narrowed to `u32` (Lazer's
    /// canonical feed-id width) at `registry::create_oracle`. Updating an
    /// entry here does NOT retroactively change existing oracles.
    asset_feed_ids: Table<String, u64>,
    /// Admin-tuned maximum age of `spot_timestamp_ms` used to seed the
    /// per-oracle `spot_staleness_threshold_ms` at `create_oracle`.
    spot_staleness_threshold_ms: u64,
    /// Admin-tuned maximum age of the cached basis used to seed the
    /// per-oracle `basis_staleness_threshold_ms` at `create_oracle`.
    basis_staleness_threshold_ms: u64,
    /// Admin-tuned window within which Lazer's last spot push is treated as
    /// the authoritative master spot. Seeds the per-oracle field at creation.
    lazer_authoritative_threshold_ms: u64,
    /// Admin-tuned window within which Lazer's last spot push freezes
    /// settlement authoritatively. Seeds the per-oracle field at creation;
    /// longer than `lazer_authoritative_threshold_ms` because settlement is
    /// irreversible.
    lazer_settlement_authoritative_threshold_ms: u64,
}

/// Curve sample point with strike and one-sided UP price.
public struct CurvePoint has copy, drop, store {
    strike: u64,
    up_price: u64,
}

/// Create a curve sample point from exact strike and UP price.
public fun new_curve_point(strike: u64, up_price: u64): CurvePoint {
    CurvePoint {
        strike,
        up_price,
    }
}

/// Return the strike stored in a curve point.
public fun strike(point: &CurvePoint): u64 { point.strike }

/// Return the UP price stored in a curve point.
public fun up_price(point: &CurvePoint): u64 { point.up_price }

/// Return the minimum ask price stored in an `AskBounds`.
public fun ask_bounds_min(bounds: &AskBounds): u64 { bounds.min_ask_price }

/// Return the maximum ask price stored in an `AskBounds`.
public fun ask_bounds_max(bounds: &AskBounds): u64 { bounds.max_ask_price }

/// Admin-tuned spot staleness threshold (ms) used to seed new oracles.
public(package) fun spot_staleness_threshold_ms(oracle_config: &OracleConfig): u64 {
    oracle_config.spot_staleness_threshold_ms
}

/// Admin-tuned basis staleness threshold (ms) used to seed new oracles.
public(package) fun basis_staleness_threshold_ms(oracle_config: &OracleConfig): u64 {
    oracle_config.basis_staleness_threshold_ms
}

/// Admin-tuned Lazer-authoritative window (ms) used to seed new oracles.
public(package) fun lazer_authoritative_threshold_ms(oracle_config: &OracleConfig): u64 {
    oracle_config.lazer_authoritative_threshold_ms
}

/// Admin-tuned Lazer-settlement-authoritative window (ms) used to seed new
/// oracles.
public(package) fun lazer_settlement_authoritative_threshold_ms(oracle_config: &OracleConfig): u64 {
    oracle_config.lazer_settlement_authoritative_threshold_ms
}

/// Per-asset basis bounds currently registered for `asset`, or `None` if the
/// asset would fall back to the `constants::default_*!()` basis-bound macros
/// at `create_oracle`.
public(package) fun asset_basis_bounds(
    oracle_config: &OracleConfig,
    asset: String,
): Option<BasisBounds> {
    if (oracle_config.asset_basis_bounds.contains(asset)) {
        option::some(oracle_config.asset_basis_bounds[asset])
    } else {
        option::none()
    }
}

/// Per-asset Pyth Lazer feed id currently registered for `asset`, or `None`
/// if no entry exists. `create_oracle` requires a registered entry and aborts
/// with `EFeedIdNotConfigured` otherwise; this getter is for introspection.
public(package) fun asset_feed_id(oracle_config: &OracleConfig, asset: String): Option<u64> {
    if (oracle_config.asset_feed_ids.contains(asset)) {
        option::some(oracle_config.asset_feed_ids[asset])
    } else {
        option::none()
    }
}

/// Resolve the Pyth Lazer feed id registered for `asset`, or abort if none
/// has been set. Called by `registry::create_oracle` so operators can't pass
/// an arbitrary feed id — admin must bind `asset → feed_id` once per
/// underlying before the first oracle of that asset can be created.
public(package) fun resolve_feed_id(oracle_config: &OracleConfig, asset: String): u64 {
    assert!(oracle_config.asset_feed_ids.contains(asset), EFeedIdNotConfigured);
    oracle_config.asset_feed_ids[asset]
}

public(package) fun basis_bounds_max_spot_deviation(bounds: &BasisBounds): u64 {
    bounds.max_spot_deviation
}

public(package) fun basis_bounds_max_basis_deviation(bounds: &BasisBounds): u64 {
    bounds.max_basis_deviation
}

public(package) fun basis_bounds_min_basis(bounds: &BasisBounds): u64 {
    bounds.min_basis
}

public(package) fun basis_bounds_max_basis(bounds: &BasisBounds): u64 {
    bounds.max_basis
}

/// Create a new oracle-config registry seeded with the `constants::default_*!()`
/// staleness thresholds. `asset_basis_bounds` starts empty; any asset without
/// an explicit entry falls back to `default_basis_bounds()` at creation.
public(package) fun new(ctx: &mut TxContext): OracleConfig {
    OracleConfig {
        oracle_grids: table::new(ctx),
        oracle_ask_bounds: table::new(ctx),
        asset_basis_bounds: table::new(ctx),
        asset_feed_ids: table::new(ctx),
        spot_staleness_threshold_ms: constants::default_spot_staleness_threshold_ms!(),
        basis_staleness_threshold_ms: constants::default_basis_staleness_threshold_ms!(),
        lazer_authoritative_threshold_ms: constants::default_lazer_authoritative_threshold_ms!(),
        lazer_settlement_authoritative_threshold_ms: constants::default_lazer_settlement_authoritative_threshold_ms!(),
    }
}

/// Build an `OracleBounds` snapshot for a new oracle with `underlying_asset`.
/// Staleness fields come from the admin-tuned global config; basis bounds
/// come from the per-asset entry if present, else the `constants::default_*!()`
/// basis-bound macros.
public(package) fun build_oracle_bounds(
    oracle_config: &OracleConfig,
    underlying_asset: String,
): OracleBounds {
    let (
        max_spot_deviation,
        max_basis_deviation,
        min_basis,
        max_basis,
    ) = oracle_config.resolve_basis_bounds(underlying_asset);
    oracle::new_oracle_bounds(
        oracle_config.spot_staleness_threshold_ms,
        oracle_config.basis_staleness_threshold_ms,
        oracle_config.lazer_authoritative_threshold_ms,
        oracle_config.lazer_settlement_authoritative_threshold_ms,
        max_spot_deviation,
        max_basis_deviation,
        min_basis,
        max_basis,
    )
}

/// Admin setter: update the global spot staleness threshold seed used by
/// subsequent `create_oracle` calls. Does NOT retroactively update existing
/// oracles — operators retune their own oracle via
/// `oracle::set_spot_staleness_threshold_ms` if needed.
public(package) fun set_spot_staleness_threshold_ms(oracle_config: &mut OracleConfig, value: u64) {
    validate_staleness_ms(value);
    oracle_config.spot_staleness_threshold_ms = value;
}

/// Admin setter: update the global basis staleness threshold seed. Does NOT
/// retroactively update existing oracles.
public(package) fun set_basis_staleness_threshold_ms(oracle_config: &mut OracleConfig, value: u64) {
    validate_staleness_ms(value);
    oracle_config.basis_staleness_threshold_ms = value;
}

/// Admin setter: update the global Lazer-authoritative window seed. Does NOT
/// retroactively update existing oracles.
public(package) fun set_lazer_authoritative_threshold_ms(
    oracle_config: &mut OracleConfig,
    value: u64,
) {
    validate_staleness_ms(value);
    oracle_config.lazer_authoritative_threshold_ms = value;
}

/// Admin setter: update the global Lazer-settlement-authoritative window
/// seed. Does NOT retroactively update existing oracles.
public(package) fun set_lazer_settlement_authoritative_threshold_ms(
    oracle_config: &mut OracleConfig,
    value: u64,
) {
    validate_staleness_ms(value);
    oracle_config.lazer_settlement_authoritative_threshold_ms = value;
}

/// Admin setter: set or update the per-asset basis bounds seed for `asset`.
/// Consumed by `build_oracle_bounds` at the next matching `create_oracle`.
/// Validates `min_basis < max_basis` and that both deviation fractions fit
/// within 1.0 (1e9 scale).
public(package) fun set_asset_basis_bounds(
    oracle_config: &mut OracleConfig,
    asset: String,
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    validate_basis_bounds_inputs(max_spot_deviation, max_basis_deviation, min_basis, max_basis);
    let bounds = BasisBounds { max_spot_deviation, max_basis_deviation, min_basis, max_basis };
    if (oracle_config.asset_basis_bounds.contains(asset)) {
        let row = &mut oracle_config.asset_basis_bounds[asset];
        *row = bounds;
    } else {
        oracle_config.asset_basis_bounds.add(asset, bounds);
    }
}

/// Admin setter: bind `asset → feed_id` so subsequent `create_oracle` calls
/// for that underlying resolve the Pyth Lazer feed id from config instead of
/// taking it as a PTB arg. Does NOT retroactively update existing oracles —
/// they keep the feed id snapshotted at their own creation time.
public(package) fun set_asset_feed_id(
    oracle_config: &mut OracleConfig,
    asset: String,
    feed_id: u64,
) {
    if (oracle_config.asset_feed_ids.contains(asset)) {
        let row = &mut oracle_config.asset_feed_ids[asset];
        *row = feed_id;
    } else {
        oracle_config.asset_feed_ids.add(asset, feed_id);
    }
}

/// Register the configured strike grid for a newly created oracle.
public(package) fun add_oracle_grid(
    oracle_config: &mut OracleConfig,
    oracle_id: ID,
    min_strike: u64,
    tick_size: u64,
) {
    let max_strike = min_strike + tick_size * constants::oracle_strike_grid_ticks!();
    let grid = OracleGrid {
        min_strike,
        max_strike,
        tick_size,
    };
    oracle_config.oracle_grids.add(oracle_id, grid);
}

/// Set or update a per-oracle ask-bound override. The caller must hold an
/// `OracleSVICap` authorized for `oracle`. Validates the math invariant
/// `min < max < float_scaling`; the "no looser than the global default"
/// constraint is enforced by the caller (see `predict::set_oracle_ask_bounds`).
public(package) fun set_oracle_ask_bounds(
    oracle_config: &mut OracleConfig,
    oracle: &OracleSVI,
    cap: &OracleSVICap,
    min: u64,
    max: u64,
) {
    oracle.assert_authorized_cap(cap);
    assert!(min < max, EInvalidAskBound);
    assert!(max < constants::float_scaling!(), EInvalidAskBound);

    let oracle_id = oracle.id();
    let bounds = AskBounds { min_ask_price: min, max_ask_price: max };
    if (oracle_config.oracle_ask_bounds.contains(oracle_id)) {
        let row = &mut oracle_config.oracle_ask_bounds[oracle_id];
        *row = bounds;
    } else {
        oracle_config.oracle_ask_bounds.add(oracle_id, bounds);
    }
}

/// Remove the per-oracle ask-bound override so the oracle inherits the global
/// default again. No-op if no override is currently set.
public(package) fun clear_oracle_ask_bounds(
    oracle_config: &mut OracleConfig,
    oracle: &OracleSVI,
    cap: &OracleSVICap,
) {
    oracle.assert_authorized_cap(cap);
    let oracle_id = oracle.id();
    if (oracle_config.oracle_ask_bounds.contains(oracle_id)) {
        oracle_config.oracle_ask_bounds.remove(oracle_id);
    };
}

/// Return the per-oracle ask-bound override, or `None` if the oracle inherits
/// the global default.
public(package) fun ask_bounds_override(
    oracle_config: &OracleConfig,
    oracle_id: ID,
): Option<AskBounds> {
    if (oracle_config.oracle_ask_bounds.contains(oracle_id)) {
        option::some(oracle_config.oracle_ask_bounds[oracle_id])
    } else {
        option::none()
    }
}

/// Assert that a strike lies on the configured grid for this oracle.
public(package) fun assert_valid_strike(
    oracle_config: &OracleConfig,
    oracle: &OracleSVI,
    strike: u64,
) {
    let oracle_id = oracle.id();
    let (min_strike, tick_size, max_strike) = oracle_config.grid_params(oracle_id);

    assert!(strike >= min_strike && strike <= max_strike, EInvalidStrike);
    assert!((strike - min_strike) % tick_size == 0, EInvalidStrike);
}

/// Assert that a market key matches the oracle identity, expiry, and strike grid.
public(package) fun assert_key_matches(
    oracle_config: &OracleConfig,
    oracle: &OracleSVI,
    market_key: &MarketKey,
) {
    let oracle_id = oracle.id();

    assert!(market_key.oracle_id() == oracle_id, EMarketKeyOracleMismatch);
    assert!(market_key.expiry() == oracle.expiry(), EMarketKeyExpiryMismatch);
    oracle_config.assert_valid_strike(oracle, market_key.strike());
}

/// Assert that a range key matches the oracle identity, expiry, and that both
/// strikes lie on the configured grid.
public(package) fun assert_range_key_matches(
    oracle_config: &OracleConfig,
    oracle: &OracleSVI,
    range_key: &RangeKey,
) {
    let oracle_id = oracle.id();

    assert!(range_key.oracle_id() == oracle_id, ERangeKeyOracleMismatch);
    assert!(range_key.expiry() == oracle.expiry(), ERangeKeyExpiryMismatch);
    oracle_config.assert_valid_strike(oracle, range_key.lower_strike());
    oracle_config.assert_valid_strike(oracle, range_key.higher_strike());
}

/// Build an adaptive piecewise-linear curve over the configured strike range.
public(package) fun build_curve(
    oracle_config: &OracleConfig,
    oracle: &OracleSVI,
    min_strike: u64,
    max_strike: u64,
): vector<CurvePoint> {
    let oracle_id = oracle.id();
    oracle_config.assert_build_curve(oracle_id, min_strike, max_strike);
    if (oracle.is_settled()) {
        let settlement = oracle.settlement_price().destroy_some();
        let full_price = constants::float_scaling!();

        return vector[new_curve_point(settlement, full_price)]
    };

    // Single-strike edge case.
    if (min_strike == max_strike) {
        let price = oracle.compute_price(min_strike);
        return vector[new_curve_point(min_strike, price)]
    };

    let price_lo = oracle.compute_price(min_strike);
    let price_hi = oracle.compute_price(max_strike);
    let mut points = vector[
        new_curve_point(min_strike, price_lo),
        new_curve_point(max_strike, price_hi),
    ];

    let curve_samples = constants::default_curve_samples!();
    let mut cur_samples = 2;
    let (grid_min, grid_tick, _grid_max) = oracle_config.grid_params(oracle_id);
    while (cur_samples < curve_samples) {
        let (found, idx) = find_gap(&points, grid_tick);
        if (!found) break;

        let strike_lo = points[idx].strike;
        let strike_hi = points[idx + 1].strike;
        let mid_strike = snap_to_tick((strike_lo + strike_hi) / 2, grid_min, grid_tick);
        let price = oracle.compute_price(mid_strike);
        insert_asc(&mut points, new_curve_point(mid_strike, price));
        cur_samples = cur_samples + 1;
    };

    points
}

/// Assert that a requested curve range is valid on the oracle's configured grid.
fun assert_build_curve(
    oracle_config: &OracleConfig,
    oracle_id: ID,
    min_strike: u64,
    max_strike: u64,
) {
    let (grid_min, tick_size, grid_max) = oracle_config.grid_params(oracle_id);

    assert!(min_strike <= max_strike, EInvalidCurveRange);
    assert!(min_strike >= grid_min && min_strike <= grid_max, EInvalidStrike);
    assert!(max_strike >= grid_min && max_strike <= grid_max, EInvalidStrike);
    assert!((min_strike - grid_min) % tick_size == 0, EInvalidStrike);
    assert!((max_strike - grid_min) % tick_size == 0, EInvalidStrike);
}

/// Load the configured strike-grid parameters for an oracle.
fun grid_params(oracle_config: &OracleConfig, oracle_id: ID): (u64, u64, u64) {
    assert!(oracle_config.oracle_grids.contains(oracle_id), EOracleConfigNotFound);
    let grid = oracle_config.oracle_grids.borrow(oracle_id);
    let grid_min = grid.min_strike;
    let grid_max = grid.max_strike;
    let tick_size = grid.tick_size;
    (grid_min, tick_size, grid_max)
}

/// Resolve `(max_spot_deviation, max_basis_deviation, min_basis, max_basis)`
/// for a given underlying asset, falling back to the constants defaults when
/// no per-asset entry is registered.
fun resolve_basis_bounds(
    oracle_config: &OracleConfig,
    underlying_asset: String,
): (u64, u64, u64, u64) {
    if (oracle_config.asset_basis_bounds.contains(underlying_asset)) {
        let b = oracle_config.asset_basis_bounds[underlying_asset];
        (b.max_spot_deviation, b.max_basis_deviation, b.min_basis, b.max_basis)
    } else {
        (
            constants::default_max_spot_deviation!(),
            constants::default_max_basis_deviation!(),
            constants::default_min_basis!(),
            constants::default_max_basis!(),
        )
    }
}

fun validate_staleness_ms(value: u64) {
    assert!(
        value > 0 && value <= constants::max_staleness_threshold_ms!(),
        EInvalidStalenessThreshold,
    );
}

fun validate_basis_bounds_inputs(
    max_spot_deviation: u64,
    max_basis_deviation: u64,
    min_basis: u64,
    max_basis: u64,
) {
    assert!(min_basis < max_basis, EInvalidBasisBounds);
    assert!(min_basis >= constants::min_basis_floor!(), EInvalidBasisBounds);
    assert!(max_basis <= constants::max_basis_ceiling!(), EInvalidBasisBounds);
    assert!(
        max_spot_deviation > 0 && max_spot_deviation <= constants::max_basis_deviation_ceiling!(),
        EInvalidBasisBounds,
    );
    assert!(
        max_basis_deviation > 0 && max_basis_deviation <= constants::max_basis_deviation_ceiling!(),
        EInvalidBasisBounds,
    );
}

/// Insert a new curve point while preserving ascending strike order.
fun insert_asc(points: &mut vector<CurvePoint>, new_point: CurvePoint) {
    points.push_back(new_point);
    let mut i = points.length() - 1;
    while (i > 0) {
        if (points[i - 1].strike <= points[i].strike) break;
        points.swap(i - 1, i);
        i = i - 1;
    };
}

/// Pick the next adjacent gap to bisect based on endpoint UP-price difference.
fun find_gap(points: &vector<CurvePoint>, grid_tick: u64): (bool, u64) {
    let len = points.length();
    let mut best_idx = len;
    let mut best_price_diff = 0;

    let mut i = 0;
    while (i + 1 < len) {
        let lo = &points[i];
        let hi = &points[i + 1];

        if (hi.strike - lo.strike <= grid_tick) {
            i = i + 1;
            continue
        };

        // `points` is strike-sorted, and UP price is monotone non-increasing in strike.
        let price_diff = lo.up_price - hi.up_price;
        if (price_diff > best_price_diff) {
            best_idx = i;
            best_price_diff = price_diff;
        };

        i = i + 1;
    };

    (best_idx != len, best_idx)
}

/// Round a strike down to the nearest tick boundary.
fun snap_to_tick(strike: u64, grid_min: u64, grid_tick: u64): u64 {
    grid_min + (strike - grid_min) / grid_tick * grid_tick
}
