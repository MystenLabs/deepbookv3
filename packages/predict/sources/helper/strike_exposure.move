// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Strike exposure store for one oracle.
///
/// This module owns the live NAV and payout indexes for one expiry grid. It can
/// compute settled liability before settlement economics are finalized, but does
/// not retain finalized settlement facts after dense storage is destroyed.
module deepbook_predict::strike_exposure;

use deepbook::constants::max_u64;
use deepbook_predict::{
    constants,
    market_oracle::MarketOracle,
    pricing,
    pricing_config::PricingConfig,
    pyth_source::PythSource,
    strike_nav_matrix::{Self, StrikeNavMatrix},
    strike_payout_tree::{Self, StrikePayoutTree}
};
use sui::clock::Clock;

const ELiveIndexesDestroyed: u64 = 0;
const ELiveIndexesNotDestroyed: u64 = 1;
const EInvalidStrikeGrid: u64 = 3;

/// Exposure lifecycle state for one oracle grid.
public struct StrikeExposure has store {
    grid_min: u64,
    grid_tick: u64,
    grid_max: u64,
    live: Option<LiveExposure>,
}

/// Live exposure indexes composed from dense NAV and sparse payout storage.
public struct LiveExposure has store {
    nav: StrikeNavMatrix,
    payout: StrikePayoutTree,
    minted_min_strike: u64,
    minted_max_strike: u64,
}

/// Return the exact worst-case settled payout across all settlement prices.
public(package) fun max_payout(exposure: &StrikeExposure): u64 {
    exposure.assert_live_indexes_exist();
    exposure.live.borrow().payout.max_payout()
}

/// Abort unless live indexes have been destroyed.
public(package) fun assert_live_indexes_destroyed(exposure: &StrikeExposure) {
    assert!(exposure.live.is_none(), ELiveIndexesNotDestroyed);
}

/// Evaluate live option value for active exposure.
public(package) fun live_value(
    exposure: &StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): u64 {
    exposure.assert_live_indexes_exist();

    let live = exposure.live.borrow();
    let (minted_min_strike, minted_max_strike) = live.minted_strike_range();
    if (minted_min_strike == 0 && minted_max_strike == 0) {
        0
    } else {
        let curve = pricing::build_live_curve(
            config,
            market,
            pyth,
            clock,
            exposure.grid_min,
            exposure.grid_tick,
            exposure.grid_max,
            minted_min_strike,
            minted_max_strike,
        );
        live.nav.live_value(&curve, minted_min_strike, minted_max_strike)
    }
}

/// Evaluate settled payout liability.
public(package) fun settled_value(exposure: &StrikeExposure, settlement: u64): u64 {
    exposure.assert_live_indexes_exist();
    exposure.live.borrow().payout.settled_value(settlement)
}

/// Create a strike exposure book for the oracle grid.
public(package) fun new(
    tick_size: u64,
    min_strike: u64,
    max_strike: u64,
    ctx: &mut TxContext,
): StrikeExposure {
    StrikeExposure {
        grid_min: min_strike,
        grid_tick: tick_size,
        grid_max: max_strike,
        live: option::some(LiveExposure {
            nav: strike_nav_matrix::new(tick_size, min_strike, max_strike, ctx),
            payout: strike_payout_tree::new(tick_size, min_strike, max_strike, ctx),
            minted_min_strike: max_u64(),
            minted_max_strike: 0,
        }),
    }
}

/// Insert interval quantity for `(lower, higher]`.
public(package) fun insert_range(exposure: &mut StrikeExposure, lower: u64, higher: u64, qty: u64) {
    exposure.assert_live_indexes_exist();
    exposure.assert_strikes_on_grid(lower, higher);
    let live = exposure.live.borrow_mut();
    live.payout.insert_range(lower, higher, qty);
    live.nav.insert_range(lower, higher, qty);
    live.track_minted_boundaries(lower, higher);
}

/// Remove interval quantity for `(lower, higher]`.
public(package) fun remove_range(exposure: &mut StrikeExposure, lower: u64, higher: u64, qty: u64) {
    exposure.assert_live_indexes_exist();
    exposure.assert_strikes_on_grid(lower, higher);
    let live = exposure.live.borrow_mut();
    live.payout.remove_range(lower, higher, qty);
    live.nav.remove_range(lower, higher, qty);
}

/// Destroy live NAV and payout indexes after expiry economics are finalized.
public(package) fun destroy_live_indexes(exposure: &mut StrikeExposure) {
    exposure.assert_live_indexes_exist();
    let live = exposure.live.extract();
    let LiveExposure {
        nav,
        payout,
        minted_min_strike: _,
        minted_max_strike: _,
    } = live;
    nav.destroy();
    payout.destroy();
}

fun assert_live_indexes_exist(exposure: &StrikeExposure) {
    assert!(exposure.live.is_some(), ELiveIndexesDestroyed);
}

fun minted_strike_range(live: &LiveExposure): (u64, u64) {
    if (live.minted_min_strike > live.minted_max_strike) (0, 0) else (
        live.minted_min_strike,
        live.minted_max_strike,
    )
}

fun assert_strikes_on_grid(exposure: &StrikeExposure, lower: u64, higher: u64) {
    assert!(lower < higher, EInvalidStrikeGrid);
    if (lower != constants::neg_inf!()) exposure.assert_finite_strike_on_grid(lower);
    if (higher != constants::pos_inf!()) exposure.assert_finite_strike_on_grid(higher);
}

fun assert_finite_strike_on_grid(exposure: &StrikeExposure, strike: u64) {
    assert!(strike >= exposure.grid_min && strike <= exposure.grid_max, EInvalidStrikeGrid);
    assert!((strike - exposure.grid_min) % exposure.grid_tick == 0, EInvalidStrikeGrid);
}

fun track_minted_boundaries(live: &mut LiveExposure, lower: u64, higher: u64) {
    if (lower != constants::neg_inf!()) {
        live.minted_min_strike = live.minted_min_strike.min(lower);
        live.minted_max_strike = live.minted_max_strike.max(lower);
    };

    if (higher != constants::pos_inf!()) {
        live.minted_min_strike = live.minted_min_strike.min(higher);
        live.minted_max_strike = live.minted_max_strike.max(higher);
    };
}
