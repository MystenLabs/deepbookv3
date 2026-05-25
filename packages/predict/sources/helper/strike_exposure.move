// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Strike exposure store for one oracle.
///
/// This module owns live NAV/payout indexes and the terminal settled liability
/// cache for one expiry grid. Expiry-market cash backing and payout movement
/// stay outside this module.
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
const ESettledLiabilityNotMaterialized: u64 = 5;
const ESettledLiabilityUnderflow: u64 = 6;
const EInvalidCloseQuantity: u64 = 7;

/// Exposure lifecycle state for one oracle grid.
public struct StrikeExposure has store {
    grid_min: u64,
    grid_tick: u64,
    grid_max: u64,
    next_order_sequence: u64,
    /// Live max payout before settlement; after settlement is cached, remaining settled liability.
    payout_liability: u64,
    /// True once `payout_liability` has switched from live max payout to settled liability.
    settled_liability_materialized: bool,
    live: Option<LiveExposure>,
}

/// Live exposure indexes composed from dense NAV and sparse payout storage.
public struct LiveExposure has store {
    nav: StrikeNavMatrix,
    payout: StrikePayoutTree,
    minted_min_strike: u64,
    minted_max_strike: u64,
}

/// Return live worst-case payout, or remaining settled payout liability once cached.
public(package) fun payout_liability(exposure: &StrikeExposure): u64 {
    exposure.payout_liability
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

/// Return settled payout for one order at a terminal settlement price.
public(package) fun settled_order_payout(
    exposure: &StrikeExposure,
    order: &Order,
    settlement: u64,
): u64 {
    let (lower, higher, quantity) = exposure.order_terms(order);
    if (settlement > lower && settlement <= higher) quantity else 0
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
        exposure.payout_liability,
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

    let live = exposure.live.borrow_mut();
    exposure.payout_liability = live.payout.insert_range(lower, higher, quantity);
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
        payout_liability: 0,
        settled_liability_materialized: false,
        live: option::some(LiveExposure {
            nav: strike_nav_matrix::new(tick_size, min_strike, max_strike, ctx),
            payout: strike_payout_tree::new(tick_size, min_strike, max_strike, ctx),
            minted_min_strike: max_u64(),
            minted_max_strike: 0,
        }),
    }
}

/// Close live indexed quantity and quote the redeemed amount using post-close exposure.
public(package) fun close_and_quote_live_order(
    exposure: &mut StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
    order: &Order,
    close_quantity: u64,
    allocated_capital: u64,
): (Order, u64, u64) {
    let (lower, higher, old_quantity) = exposure.order_terms(order);
    order::assert_valid_quantity(close_quantity);
    assert!(close_quantity <= old_quantity, EInvalidCloseQuantity);
    let replacement_quantity = old_quantity - close_quantity;

    exposure.remove_live_quantity(lower, higher, close_quantity);
    let (fair_price, fee_rate) = pricing::quote_live_range(
        config,
        market,
        pyth,
        clock,
        lower,
        higher,
        exposure.payout_liability,
        allocated_capital,
    );
    let resulting_order = if (replacement_quantity == 0) {
        *order
    } else {
        let sequence = exposure.next_order_sequence;
        let replacement_order = order::replacement(
            order,
            clock.timestamp_ms(),
            replacement_quantity,
            sequence,
        );
        exposure.next_order_sequence = sequence + 1;
        replacement_order
    };
    let principal_amount = math::mul(fair_price, close_quantity);
    let fee_amount = math::mul(fee_rate, close_quantity).min(principal_amount);
    (resulting_order, principal_amount, fee_amount)
}

/// Cache the terminal settled payout liability in `payout_liability`.
///
/// This changes `payout_liability` from live max payout to remaining settled
/// liability. Live indexes are kept until privileged compaction destroys them.
public(package) fun materialize_settled_liability(
    exposure: &mut StrikeExposure,
    settlement: u64,
): u64 {
    if (exposure.settled_liability_materialized) {
        return exposure.payout_liability
    };

    let settled_liability = exposure.live.borrow().payout.settled_value(settlement);
    exposure.payout_liability = settled_liability;
    exposure.settled_liability_materialized = true;
    settled_liability
}

/// Reduce cached settled liability after paying one settled order.
public(package) fun decrease_materialized_settled_liability(
    exposure: &mut StrikeExposure,
    amount: u64,
) {
    assert!(exposure.settled_liability_materialized, ESettledLiabilityNotMaterialized);
    let current_liability = exposure.payout_liability;
    assert!(current_liability >= amount, ESettledLiabilityUnderflow);
    exposure.payout_liability = current_liability - amount;
}

/// Destroy live indexes after terminal liability has been cached.
///
/// Callers must keep this behind privileged compaction because destruction
/// returns storage rebates.
public(package) fun destroy_live_indexes(exposure: &mut StrikeExposure) {
    assert!(exposure.settled_liability_materialized, ESettledLiabilityNotMaterialized);
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
        let strike = exposure.grid_min + min_strike_index * exposure.grid_tick;
        assert!(strike <= exposure.grid_max, EInvalidStrikeIndex);
        strike
    };

    let higher = if (max_strike_index == open_index) {
        constants::pos_inf!()
    } else {
        let strike = exposure.grid_min + max_strike_index * exposure.grid_tick;
        assert!(strike <= exposure.grid_max, EInvalidStrikeIndex);
        strike
    };

    (lower, higher, order.quantity())
}

fun remove_live_quantity(exposure: &mut StrikeExposure, lower: u64, higher: u64, quantity: u64) {
    let live = exposure.live.borrow_mut();
    exposure.payout_liability = live.payout.remove_range(lower, higher, quantity);
    live.nav.remove_range(lower, higher, quantity);
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
