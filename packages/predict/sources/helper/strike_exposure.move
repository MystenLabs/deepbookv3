// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Strike exposure store for one oracle.
///
/// This module is the package boundary for expiry exposure accounting across
/// the live, settled, and compacted phases. It keeps live NAV and payout
/// indexes in sync while they exist, owns grid-aware quote helpers, and retains
/// compacted payout facts after dense strike state is destroyed.
module deepbook_predict::strike_exposure;

use deepbook::{constants::max_u64, math};
use deepbook_predict::{
    constants,
    market_oracle::MarketOracle,
    pricing,
    pricing_config::PricingConfig,
    pyth_source::PythSource,
    range_key::RangeKey,
    strike_nav_matrix::{Self, StrikeNavMatrix},
    strike_payout_tree::{Self, StrikePayoutTree}
};
use sui::clock::Clock;

const EMarketCompacted: u64 = 0;
const EMarketNotCompacted: u64 = 1;
const ECompactedLiabilityUnderflow: u64 = 2;
const EInvalidStrikeGrid: u64 = 3;
const ECompactedLiabilityMismatch: u64 = 4;

/// Exposure lifecycle state for one oracle grid.
public struct StrikeExposure has store {
    grid_min: u64,
    grid_tick: u64,
    grid_max: u64,
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

/// Evaluate live option value and conservative maximum losing fee basis.
public(package) fun live_values(
    exposure: &StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
): (u64, u64) {
    assert!(!exposure.is_compacted(), EMarketCompacted);

    let live = exposure.live.borrow();
    let (minted_min_strike, minted_max_strike) = live.minted_strike_range();
    let option_value = if (minted_min_strike == 0 && minted_max_strike == 0) {
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
    };
    (option_value, live.payout.conservative_losing_fee_basis())
}

/// Evaluate settled liability and exact losing fee basis.
public(package) fun settled_values(exposure: &StrikeExposure, settlement: u64): (u64, u64) {
    assert!(!exposure.is_compacted(), EMarketCompacted);
    exposure.live.borrow().payout.settled_values(settlement)
}

/// Return compacted settlement facts.
public(package) fun compacted_values(exposure: &StrikeExposure): (u64, u64) {
    assert!(exposure.is_compacted(), EMarketNotCompacted);
    let compacted = exposure.compacted.borrow();
    (compacted.settlement, compacted.payout_liability)
}

/// Quote live mint amounts for a grid-aligned range.
public(package) fun quote_mint_amounts(
    exposure: &StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
    key: &RangeKey,
    quantity: u64,
    allocated_capital: u64,
): (u64, u64) {
    assert!(!exposure.is_compacted(), EMarketCompacted);
    exposure.assert_range_on_grid(key);
    let (fair_price, fee_rate) = pricing::quote_mint_live_range(
        config,
        market,
        pyth,
        clock,
        key,
        exposure.max_payout(),
        allocated_capital,
    );
    (math::mul(fair_price, quantity), math::mul(fee_rate, quantity))
}

/// Quote live redeem amounts for a grid-aligned range.
public(package) fun quote_live_redeem_amounts(
    exposure: &StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
    key: &RangeKey,
    quantity: u64,
    allocated_capital: u64,
): (u64, u64) {
    assert!(!exposure.is_compacted(), EMarketCompacted);
    exposure.assert_range_on_grid(key);
    let (fair_price, fee_rate) = pricing::quote_live_range(
        config,
        market,
        pyth,
        clock,
        key,
        exposure.max_payout(),
        allocated_capital,
    );
    let principal_amount = math::mul(fair_price, quantity);
    let fee_amount = math::mul(fee_rate, quantity).min(principal_amount);
    (principal_amount, fee_amount)
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
        compacted: option::none(),
    }
}

/// Insert interval quantity for `(lower, higher]`.
public(package) fun insert_range(
    exposure: &mut StrikeExposure,
    lower: u64,
    higher: u64,
    qty: u64,
    fee_basis: u64,
) {
    assert!(!exposure.is_compacted(), EMarketCompacted);
    exposure.assert_strikes_on_grid(lower, higher);
    let live = exposure.live.borrow_mut();
    live.payout.insert_range(lower, higher, qty, fee_basis);
    live.nav.insert_range(lower, higher, qty);
    live.track_minted_boundaries(lower, higher);
}

/// Remove interval quantity for `(lower, higher]`.
public(package) fun remove_range(
    exposure: &mut StrikeExposure,
    lower: u64,
    higher: u64,
    qty: u64,
    fee_basis: u64,
) {
    assert!(!exposure.is_compacted(), EMarketCompacted);
    exposure.assert_strikes_on_grid(lower, higher);
    let live = exposure.live.borrow_mut();
    live.payout.remove_range(lower, higher, qty, fee_basis);
    live.nav.remove_range(lower, higher, qty);
}

/// Reduce compacted payout liability after a post-compaction redeem.
public(package) fun decrease_compacted_liability(
    exposure: &mut StrikeExposure,
    payout_amount: u64,
) {
    assert!(exposure.is_compacted(), EMarketNotCompacted);
    let compacted = exposure.compacted.borrow_mut();
    assert!(compacted.payout_liability >= payout_amount, ECompactedLiabilityUnderflow);
    compacted.payout_liability = compacted.payout_liability - payout_amount;
}

/// Compact live indexes into settled liability state.
public(package) fun compact(
    exposure: &mut StrikeExposure,
    settlement: u64,
    expected_payout_liability: u64,
) {
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
    assert!(payout_liability == expected_payout_liability, ECompactedLiabilityMismatch);
    exposure.compacted =
        option::some(CompactedExposure {
            settlement,
            payout_liability,
        });
}

fun minted_strike_range(live: &LiveExposure): (u64, u64) {
    if (live.minted_min_strike > live.minted_max_strike) (0, 0) else (
        live.minted_min_strike,
        live.minted_max_strike,
    )
}

fun assert_range_on_grid(exposure: &StrikeExposure, key: &RangeKey) {
    exposure.assert_strikes_on_grid(key.lower_strike(), key.higher_strike())
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
