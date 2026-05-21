// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Strike exposure store for one oracle.
///
/// This module is the package boundary for expiry exposure accounting across
/// the live, settled, and compacted phases. It keeps live NAV/payout indexes in
/// sync while they exist, retains compacted liability facts after those indexes
/// are destroyed, and owns order-id strike decoding against the oracle grid.
module deepbook_predict::strike_exposure;

use deepbook::constants::max_u64;
use deepbook_predict::{
    constants,
    market_oracle::MarketOracle,
    predict_order_id,
    pricing,
    pricing_config::PricingConfig,
    pyth_source::PythSource,
    strike_nav_matrix::{Self, StrikeNavMatrix},
    strike_payout_tree::{Self, StrikePayoutTree}
};
use sui::clock::Clock;

const EMarketCompacted: u64 = 0;
const ECompactedLiabilityUnderflow: u64 = 2;
const EInvalidStrikeGrid: u64 = 4;

/// Exposure lifecycle state for one oracle grid.
public struct StrikeExposure has store {
    grid_min: u64,
    grid_tick: u64,
    grid_max: u64,
    next_order_sequence: u64,
    live: Option<LiveExposure>,
    compacted: Option<CompactedExposure>,
}

/// Live exposure indexes composed from dense NAV and sparse payout storage.
public struct LiveExposure has store {
    nav: StrikeNavMatrix,
    payout: StrikePayoutTree,
    minted_min_strike: u64,
    minted_max_strike: u64,
}

/// Settlement facts retained after live exposure indexes are compacted.
public struct CompactedExposure has copy, drop, store {
    settlement: u64,
    payout_liability: u64,
}

/// Quote a live encoded order from current oracle state.
public(package) fun quote_live_order(
    exposure: &StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
    order_id: u256,
): (u64, u64) {
    let (lower, higher) = exposure.order_strikes(order_id);
    pricing::quote_live_strikes(config, market, pyth, clock, lower, higher)
}

/// Return the exact worst-case settled payout across all settlement prices.
public(package) fun max_payout(exposure: &StrikeExposure): u64 {
    if (exposure.is_compacted()) {
        exposure.compacted.borrow().payout_liability
    } else {
        exposure.live.borrow().payout.max_payout()
    }
}

/// Return true once live indexes have been compacted into settled liabilities.
public(package) fun is_compacted(exposure: &StrikeExposure): bool {
    exposure.compacted.is_some()
}

/// Evaluate live option value from current pricing inputs.
public(package) fun live_values(
    exposure: &StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): u64 {
    let (minted_min_strike, minted_max_strike) = exposure.minted_strike_range();
    if (minted_min_strike == 0 && minted_max_strike == 0) return 0;

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
    let live = exposure.live.borrow();
    live.nav.live_value(&curve, minted_min_strike, minted_max_strike)
}

/// Evaluate settled liability at a terminal settlement price.
public(package) fun settled_liability(exposure: &StrikeExposure, settlement: u64): u64 {
    exposure.live.borrow().payout.settled_liability(settlement)
}

/// Return the terminal fixed-point price for an encoded order at settlement.
public(package) fun settled_order_price(
    exposure: &StrikeExposure,
    settlement: u64,
    order_id: u256,
): u64 {
    let (lower, higher) = exposure.order_strikes(order_id);
    if (settlement > lower && settlement <= higher) constants::float_scaling!() else 0
}

/// Return compacted settlement and payout liability.
public(package) fun compacted_values(exposure: &StrikeExposure): (u64, u64) {
    let compacted = exposure.compacted.borrow();
    (compacted.settlement, compacted.payout_liability)
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
        next_order_sequence: 0,
        live: option::some(LiveExposure {
            nav: strike_nav_matrix::new(tick_size, min_strike, max_strike, ctx),
            payout: strike_payout_tree::new(tick_size, min_strike, max_strike, ctx),
            minted_min_strike: max_u64(),
            minted_max_strike: 0,
        }),
        compacted: option::none(),
    }
}

/// Encode a strike interval into an order ID using this exposure book's strike grid.
public(package) fun new_order_id(
    exposure: &mut StrikeExposure,
    expiry_ms: u64,
    lower: u64,
    higher: u64,
    leverage: u64,
    clock: &Clock,
): u256 {
    assert!(!exposure.is_compacted(), EMarketCompacted);
    let (min_strike_index, max_strike_index) = exposure.strike_indices(lower, higher);
    let sequence = exposure.next_order_sequence;
    exposure.next_order_sequence = sequence + 1;
    predict_order_id::encode(
        expiry_ms,
        clock.timestamp_ms(),
        min_strike_index,
        max_strike_index,
        leverage,
        sequence,
    )
}

/// Insert interval quantity for an encoded order ID.
public(package) fun insert_order(
    exposure: &mut StrikeExposure,
    order_id: u256,
    qty: u64,
) {
    let (lower, higher) = exposure.order_strikes(order_id);
    let live = exposure.live.borrow_mut();
    live.payout.insert_range(lower, higher, qty);
    live.nav.insert_range(lower, higher, qty);
    track_minted_boundaries(live, lower, higher);
}

/// Remove interval quantity for an encoded order ID.
public(package) fun remove_order(
    exposure: &mut StrikeExposure,
    order_id: u256,
    qty: u64,
) {
    let (lower, higher) = exposure.order_strikes(order_id);
    let live = exposure.live.borrow_mut();
    live.payout.remove_range(lower, higher, qty);
    live.nav.remove_range(lower, higher, qty);
}

/// Reduce compacted liabilities after a post-compaction redeem.
public(package) fun decrease_compacted_liabilities(
    exposure: &mut StrikeExposure,
    payout_amount: u64,
) {
    let compacted = exposure.compacted.borrow_mut();
    assert!(compacted.payout_liability >= payout_amount, ECompactedLiabilityUnderflow);
    compacted.payout_liability = compacted.payout_liability - payout_amount;
}

/// Compact live indexes into settled liability state.
public(package) fun compact(exposure: &mut StrikeExposure, settlement: u64): u64 {
    assert!(!exposure.is_compacted(), EMarketCompacted);
    let live = exposure.live.extract();
    let LiveExposure {
        nav,
        payout,
        minted_min_strike: _,
        minted_max_strike: _,
    } = live;
    nav.destroy();
    let payout_liability = payout.into_settled_liability(settlement);
    exposure.compacted =
        option::some(CompactedExposure {
            settlement,
            payout_liability,
        });
    payout_liability
}

// === Private Functions ===

fun minted_strike_range(exposure: &StrikeExposure): (u64, u64) {
    let live = exposure.live.borrow();
    if (live.minted_min_strike > live.minted_max_strike) (0, 0) else (
        live.minted_min_strike,
        live.minted_max_strike,
    )
}

fun order_strikes(exposure: &StrikeExposure, order_id: u256): (u64, u64) {
    predict_order_id::strike_range(
        order_id,
        exposure.grid_min,
        exposure.grid_tick,
        exposure.grid_max,
    )
}

fun strike_indices(exposure: &StrikeExposure, lower: u64, higher: u64): (u64, u64) {
    let min_strike_index = if (lower == constants::neg_inf!()) {
        predict_order_id::open_strike_index()
    } else {
        exposure.finite_strike_index(lower)
    };
    let max_strike_index = if (higher == constants::pos_inf!()) {
        predict_order_id::open_strike_index()
    } else {
        exposure.finite_strike_index(higher)
    };

    (min_strike_index, max_strike_index)
}

fun finite_strike_index(exposure: &StrikeExposure, strike: u64): u64 {
    assert!(strike >= exposure.grid_min && strike <= exposure.grid_max, EInvalidStrikeGrid);
    assert!((strike - exposure.grid_min) % exposure.grid_tick == 0, EInvalidStrikeGrid);
    (strike - exposure.grid_min) / exposure.grid_tick
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
