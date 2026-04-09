// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Predict-owned configuration layer on top of the core oracle.
///
/// This module stores per-oracle strike grids, validates market keys against
/// that grid, applies Predict liveness policy, and builds sampled pricing
/// curves for vault MTM evaluation.
module deepbook_predict::oracle_config;

use deepbook_predict::{constants, market_key::MarketKey, oracle::OracleSVI};
use sui::{clock::Clock, table::{Self, Table}};

// === Errors ===
const EMarketKeyOracleMismatch: u64 = 0;
const EMarketKeyExpiryMismatch: u64 = 1;
const EInvalidStrike: u64 = 2;
const EOracleSettled: u64 = 3;
const EOracleExpired: u64 = 4;
const EOracleInactive: u64 = 5;
const EOracleStale: u64 = 6;
const EOracleConfigNotFound: u64 = 7;
const EInvalidCurveRange: u64 = 8;

public struct OracleGrid has copy, drop, store {
    min_strike: u64,
    max_strike: u64,
    tick_size: u64,
}

public struct OracleConfig has store {
    oracle_grids: Table<ID, OracleGrid>,
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

/// Create an empty oracle config registry for Predict.
public(package) fun new(ctx: &mut TxContext): OracleConfig {
    OracleConfig {
        oracle_grids: table::new(ctx),
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

/// Assert that an oracle can still be used for reads and redemptions.
public(package) fun assert_operational_oracle(oracle: &OracleSVI, clock: &Clock) {
    assert!(!oracle.is_settled(), EOracleSettled);
    assert!(oracle.is_active(), EOracleInactive);
    assert!(
        clock.timestamp_ms() <= oracle.timestamp() + constants::staleness_threshold_ms!(),
        EOracleStale,
    );
}

/// Assert that an oracle can still be used for minting new exposure.
public(package) fun assert_mintable_oracle(oracle: &OracleSVI, clock: &Clock) {
    assert_operational_oracle(oracle, clock);
    assert!(clock.timestamp_ms() < oracle.expiry(), EOracleExpired);
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
