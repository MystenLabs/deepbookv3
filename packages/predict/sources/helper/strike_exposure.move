// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Strike exposure store for one oracle.
///
/// This module owns the live NAV and payout indexes for one expiry grid. It can
/// compute settled liability before settlement economics are finalized, but does
/// not retain finalized settlement facts after dense storage is destroyed.
module deepbook_predict::strike_exposure;

use deepbook::{constants::max_u64, math};
use deepbook_predict::{
    constants,
    market_oracle::MarketOracle,
    order::{Self, Order},
    pricing,
    pricing_config::PricingConfig,
    pyth_source::PythSource,
    strike_nav_matrix::{Self, StrikeNavMatrix},
    strike_payout_tree::{Self, StrikePayoutTree}
};
use sui::clock::Clock;

const EInvalidTickSize: u64 = 2;
const EInvalidStrikeGrid: u64 = 3;
const EInvalidStrikeIndex: u64 = 4;

/// Exposure lifecycle state for one oracle grid.
public struct StrikeExposure has store {
    grid_min: u64,
    grid_tick: u64,
    grid_max: u64,
    next_order_sequence: u64,
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
    exposure.live.borrow().payout.max_payout()
}

/// Evaluate live option value for active exposure.
public(package) fun live_value(
    exposure: &StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): u64 {
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
    exposure.live.borrow().payout.settled_value(settlement)
}

/// Return settled payout for one order at a terminal settlement price.
public(package) fun settled_order_payout(
    exposure: &StrikeExposure,
    order: &Order,
    settlement: u64,
): u64 {
    let (lower, higher, quantity) = exposure.order_terms(order);
    if (settlement > lower && settlement <= higher) quantity else 0
}

/// Assert that strike grid creation parameters are valid.
public(package) fun assert_valid_strike_grid(min_strike: u64, tick_size: u64) {
    let _max_strike = validated_max_strike(min_strike, tick_size);
}

/// Quote and allocate a live mint order over this exposure book's strike grid.
public(package) fun allocate_mint_order(
    exposure: &mut StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
    expiry_ms: u64,
    lower: u64,
    higher: u64,
    quantity: u64,
    leverage: u64,
    allocated_capital: u64,
): (Order, u64, u64) {
    let (min_strike_index, max_strike_index) = exposure.strike_indices(lower, higher);
    let (fair_price, fee_rate) = pricing::quote_mint_live_range(
        config,
        market,
        pyth,
        clock,
        lower,
        higher,
        exposure.max_payout(),
        allocated_capital,
    );

    let sequence = exposure.next_order_sequence;
    let allocated_order = order::new_from_strike_indices(
        expiry_ms,
        clock.timestamp_ms(),
        min_strike_index,
        max_strike_index,
        leverage,
        fair_price,
        quantity,
        sequence,
    );
    exposure.next_order_sequence = sequence + 1;

    let quantity = allocated_order.quantity();
    let live = exposure.live.borrow_mut();
    live.payout.insert_range(lower, higher, quantity);
    live.nav.insert_range(lower, higher, quantity);
    live.track_minted_boundaries(lower, higher);

    let principal_amount = math::mul(allocated_order.minted_price(), quantity);
    let fee_amount = math::mul(fee_rate, quantity);
    (allocated_order, principal_amount, fee_amount)
}

/// Create a strike exposure book for the oracle grid.
public(package) fun new(min_strike: u64, tick_size: u64, ctx: &mut TxContext): StrikeExposure {
    let max_strike = validated_max_strike(min_strike, tick_size);
    StrikeExposure {
        grid_min: min_strike,
        grid_tick: tick_size,
        grid_max: max_strike,
        next_order_sequence: 0,
        live: option::some(LiveExposure {
            nav: strike_nav_matrix::new(tick_size, min_strike, max_strike, ctx),
            payout: strike_payout_tree::new(tick_size, min_strike, max_strike, ctx),
            minted_min_strike: max_u64(),
            minted_max_strike: 0,
        }),
    }
}

/// Remove an order and quote its live redeem amount using post-removal exposure.
public(package) fun remove_and_quote_live_order(
    exposure: &mut StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
    order: &Order,
    allocated_capital: u64,
): (u64, u64) {
    let (lower, higher, quantity) = exposure.remove_order(order);
    let (fair_price, fee_rate) = pricing::quote_live_range(
        config,
        market,
        pyth,
        clock,
        lower,
        higher,
        exposure.max_payout(),
        allocated_capital,
    );
    let principal_amount = math::mul(fair_price, quantity);
    let fee_amount = math::mul(fee_rate, quantity).min(principal_amount);
    (principal_amount, fee_amount)
}

/// Destroy live NAV and payout indexes after expiry economics are finalized.
public(package) fun destroy_live_indexes(exposure: &mut StrikeExposure) {
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

fun minted_strike_range(live: &LiveExposure): (u64, u64) {
    if (live.minted_min_strike > live.minted_max_strike) (0, 0) else (
        live.minted_min_strike,
        live.minted_max_strike,
    )
}

fun validated_max_strike(min_strike: u64, tick_size: u64): u64 {
    assert!(tick_size > 0, EInvalidTickSize);
    assert!(tick_size % constants::oracle_tick_size_unit!() == 0, EInvalidTickSize);
    assert!(min_strike > 0, EInvalidStrikeGrid);
    assert!(min_strike % tick_size == 0, EInvalidStrikeGrid);
    let ticks = constants::oracle_strike_grid_ticks!();
    assert!(ticks > 0, EInvalidStrikeGrid);
    min_strike + tick_size * ticks
}

fun strike_indices(exposure: &StrikeExposure, lower: u64, higher: u64): (u64, u64) {
    assert!(lower < higher, EInvalidStrikeGrid);
    assert!(
        !(lower == constants::neg_inf!() && higher == constants::pos_inf!()),
        EInvalidStrikeGrid,
    );
    let open_index = order::open_strike_index();
    let min_strike_index = if (lower == constants::neg_inf!()) {
        open_index
    } else {
        exposure.checked_finite_strike_index(lower)
    };
    let max_strike_index = if (higher == constants::pos_inf!()) {
        open_index
    } else {
        exposure.checked_finite_strike_index(higher)
    };

    (min_strike_index, max_strike_index)
}

fun checked_finite_strike_index(exposure: &StrikeExposure, strike: u64): u64 {
    assert!(strike >= exposure.grid_min && strike <= exposure.grid_max, EInvalidStrikeGrid);
    assert!((strike - exposure.grid_min) % exposure.grid_tick == 0, EInvalidStrikeGrid);
    (strike - exposure.grid_min) / exposure.grid_tick
}

fun order_terms(exposure: &StrikeExposure, order: &Order): (u64, u64, u64) {
    let open_index = order::open_strike_index();
    let min_strike_index = order.min_strike_index();
    let max_strike_index = order.max_strike_index();

    let lower = if (min_strike_index == open_index) {
        constants::neg_inf!()
    } else {
        assert!(min_strike_index < open_index, EInvalidStrikeIndex);
        let strike = exposure.grid_min + min_strike_index * exposure.grid_tick;
        assert!(strike <= exposure.grid_max, EInvalidStrikeIndex);
        strike
    };

    let higher = if (max_strike_index == open_index) {
        constants::pos_inf!()
    } else {
        assert!(max_strike_index < open_index, EInvalidStrikeIndex);
        let strike = exposure.grid_min + max_strike_index * exposure.grid_tick;
        assert!(strike <= exposure.grid_max, EInvalidStrikeIndex);
        strike
    };

    (lower, higher, order.quantity())
}

/// Remove interval quantity for an order and return its range terms.
fun remove_order(exposure: &mut StrikeExposure, order: &Order): (u64, u64, u64) {
    let (lower, higher, quantity) = exposure.order_terms(order);
    let live = exposure.live.borrow_mut();
    live.payout.remove_range(lower, higher, quantity);
    live.nav.remove_range(lower, higher, quantity);
    (lower, higher, quantity)
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
