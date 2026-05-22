// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Strike exposure store for one oracle.
///
/// This module is the package boundary for expiry exposure accounting across
/// the live, settled, and compacted phases. It keeps live NAV/payout indexes in
/// sync while they exist, retains compacted liability facts after those indexes
/// are destroyed, owns order-id strike decoding against the oracle grid, and
/// owns the leveraged-order lifecycle index used by liquidation.
module deepbook_predict::strike_exposure;

use deepbook::{constants::max_u64, math};
use deepbook_predict::{
    constants,
    leverage_book::{Self, LeverageBook},
    market_oracle::MarketOracle,
    math as predict_math,
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
const EInvalidExpiryWindow: u64 = 5;
const ESettledLiquidationIncomplete: u64 = 6;
const EOrderNotActive: u64 = 7;

/// Exposure lifecycle state for one oracle grid.
public struct StrikeExposure has store {
    grid_min: u64,
    grid_tick: u64,
    grid_max: u64,
    next_order_sequence: u64,
    live: Option<LiveExposure>,
    compacted: Option<CompactedExposure>,
    leverage_book: LeverageBook,
    settled_liquidation_complete: bool,
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

/// Liquidated leveraged order facts needed by the expiry market.
public struct LiquidatedOrder has drop {
    order_id: u256,
    quantity: u64,
    borrowed_principal: u64,
    debt_amount: u64,
    borrow_fee_recovered: u64,
    position_value: u64,
}

// === Public-Package Functions ===

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

/// Quote a live strike interval from current oracle state after validating grid alignment.
public(package) fun quote_live_strikes(
    exposure: &StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
    lower: u64,
    higher: u64,
): (u64, u64) {
    let (_, _) = exposure.strike_indices(lower, higher);
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

public(package) fun is_liquidated(exposure: &StrikeExposure, order_id: u256): bool {
    exposure.leverage_book.is_liquidated(order_id)
}

public(package) fun is_active_leveraged_order(exposure: &StrikeExposure, order_id: u256): bool {
    exposure.leverage_book.is_active(order_id)
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

/// Return aggregate debt and borrow-fee amounts for all active leveraged orders.
public(package) fun active_debt_terms_at_ms(
    exposure: &StrikeExposure,
    expiry_ms: u64,
    max_expiry_borrow_fee: u64,
    debt_timestamp_ms: u64,
): (u64, u64) {
    let mut total_debt = 0;
    let mut total_fee = 0;
    let mut order_ids = exposure.leverage_book.active_order_ids();
    while (!order_ids.is_empty()) {
        let order_id = order_ids.pop_back();
        if (exposure.leverage_book.is_active(order_id)) {
            let (debt_amount, borrow_fee_amount) = exposure.active_order_debt_terms_at_ms(
                expiry_ms,
                max_expiry_borrow_fee,
                order_id,
                debt_timestamp_ms,
            );
            total_debt = total_debt + debt_amount;
            total_fee = total_fee + borrow_fee_amount;
        };
    };
    order_ids.destroy_empty();
    (total_debt, total_fee)
}

public(package) fun order_debt_terms_at_ms(
    exposure: &StrikeExposure,
    expiry_ms: u64,
    max_expiry_borrow_fee: u64,
    order_id: u256,
    debt_timestamp_ms: u64,
): (u64, u64) {
    if (!predict_order_id::is_leveraged_order(order_id)) return (0, 0);

    exposure.active_order_debt_terms_at_ms(
        expiry_ms,
        max_expiry_borrow_fee,
        order_id,
        debt_timestamp_ms,
    )
}

/// Return compacted settlement and payout liability.
public(package) fun compacted_values(exposure: &StrikeExposure): (u64, u64) {
    let compacted = exposure.compacted.borrow();
    (compacted.settlement, compacted.payout_liability)
}

public(package) fun unpack_liquidated_order(
    order: LiquidatedOrder,
): (u256, u64, u64, u64, u64, u64) {
    let LiquidatedOrder {
        order_id,
        quantity,
        borrowed_principal,
        debt_amount,
        borrow_fee_recovered,
        position_value,
    } = order;
    (order_id, quantity, borrowed_principal, debt_amount, borrow_fee_recovered, position_value)
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
        leverage_book: leverage_book::new(ctx),
        settled_liquidation_complete: false,
    }
}

/// Encode a strike interval into an order ID using this exposure book's strike grid.
public(package) fun new_order_id(
    exposure: &mut StrikeExposure,
    expiry_ms: u64,
    lower: u64,
    higher: u64,
    quantity: u64,
    leverage: u64,
    minted_price: u64,
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
        minted_price,
        quantity,
        sequence,
    )
}

/// Encode a fresh order ID for the same interval and leverage as an existing order.
public(package) fun replacement_order_id(
    exposure: &mut StrikeExposure,
    expiry_ms: u64,
    order_id: u256,
    quantity: u64,
    minted_price: u64,
    clock: &Clock,
): u256 {
    let (lower, higher) = exposure.order_strikes(order_id);
    exposure.new_order_id(
        expiry_ms,
        lower,
        higher,
        quantity,
        predict_order_id::leverage(order_id),
        minted_price,
        clock,
    )
}

/// Insert interval quantity for an encoded order ID.
public(package) fun insert_order(exposure: &mut StrikeExposure, order_id: u256) {
    exposure.insert_live_indexes(order_id);
    if (predict_order_id::is_leveraged_order(order_id)) {
        exposure.leverage_book.insert_order(order_id);
        exposure.settled_liquidation_complete = false;
    };
}

/// Remove interval quantity for an encoded order ID.
public(package) fun remove_order(exposure: &mut StrikeExposure, order_id: u256) {
    exposure.remove_live_indexes(order_id);
    if (predict_order_id::is_leveraged_order(order_id)) {
        exposure.leverage_book.remove_order(order_id);
    };
}

/// Remove a compacted order and reduce retained payout liability.
public(package) fun remove_compacted_order(
    exposure: &mut StrikeExposure,
    order_id: u256,
    payout_amount: u64,
) {
    if (predict_order_id::is_leveraged_order(order_id)) {
        exposure.leverage_book.remove_order(order_id);
    };
    exposure.decrease_compacted_liabilities(payout_amount);
}

public(package) fun remove_liquidated_order(exposure: &mut StrikeExposure, order_id: u256) {
    exposure.leverage_book.remove_liquidated_order(order_id)
}

/// Abort unless active settled leveraged orders have already been swept.
public(package) fun assert_settled_liquidation_complete(exposure: &StrikeExposure) {
    assert!(
        exposure.settled_liquidation_complete || !exposure.leverage_book.has_active_orders(),
        ESettledLiquidationIncomplete,
    );
}

/// Remove live underwater leveraged orders and return their liquidation facts.
public(package) fun liquidate_live_orders(
    exposure: &mut StrikeExposure,
    config: &PricingConfig,
    market: &MarketOracle,
    pyth: &PythSource,
    clock: &Clock,
    expiry_ms: u64,
    max_expiry_borrow_fee: u64,
): vector<LiquidatedOrder> {
    let order_ids = exposure.leverage_book.active_order_ids();
    let debt_timestamp_ms = clock.timestamp_ms();
    let mut liquidated_orders = vector[];
    let mut i = 0;
    while (i < order_ids.length()) {
        let order_id = order_ids[i];
        if (exposure.leverage_book.is_active(order_id)) {
            let quantity = predict_order_id::quantity(order_id);
            let (fair_price, _) = exposure.quote_live_order(config, market, pyth, clock, order_id);
            let position_value = math::mul(fair_price, quantity);
            let (debt_amount, _) = exposure.active_order_debt_terms_at_ms(
                expiry_ms,
                max_expiry_borrow_fee,
                order_id,
                debt_timestamp_ms,
            );
            if (position_value <= debt_amount) {
                liquidated_orders.push_back(exposure.liquidate_order(
                    order_id,
                    position_value,
                    debt_amount,
                ));
            };
        };
        i = i + 1;
    };
    liquidated_orders
}

/// Remove settled underwater leveraged orders and return their liquidation facts.
public(package) fun liquidate_settled_orders(
    exposure: &mut StrikeExposure,
    settlement: u64,
    expiry_ms: u64,
    max_expiry_borrow_fee: u64,
): vector<LiquidatedOrder> {
    let order_ids = exposure.leverage_book.active_order_ids();
    let mut liquidated_orders = vector[];
    let mut i = 0;
    while (i < order_ids.length()) {
        let order_id = order_ids[i];
        if (exposure.leverage_book.is_active(order_id)) {
            let quantity = predict_order_id::quantity(order_id);
            let position_value = math::mul(
                exposure.settled_order_price(settlement, order_id),
                quantity,
            );
            let (debt_amount, _) = exposure.active_order_debt_terms_at_ms(
                expiry_ms,
                max_expiry_borrow_fee,
                order_id,
                expiry_ms,
            );
            if (position_value <= debt_amount) {
                liquidated_orders.push_back(exposure.liquidate_order(
                    order_id,
                    position_value,
                    debt_amount,
                ));
            };
        };
        i = i + 1;
    };
    exposure.settled_liquidation_complete = true;
    liquidated_orders
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

fun active_order_debt_terms_at_ms(
    exposure: &StrikeExposure,
    expiry_ms: u64,
    max_expiry_borrow_fee: u64,
    order_id: u256,
    debt_timestamp_ms: u64,
): (u64, u64) {
    assert!(exposure.leverage_book.is_active(order_id), EOrderNotActive);
    let borrowed_principal = predict_order_id::borrowed_principal(order_id);
    let initial_index = borrow_index(
        max_expiry_borrow_fee,
        expiry_ms,
        predict_order_id::inserted_at_ms(order_id),
    );
    let current_index = borrow_index(max_expiry_borrow_fee, expiry_ms, debt_timestamp_ms);
    let debt_amount = predict_math::mul_div_round_up(
        borrowed_principal,
        current_index,
        initial_index,
    );
    (debt_amount, debt_amount - borrowed_principal)
}

fun borrow_index(max_expiry_borrow_fee: u64, expiry_ms: u64, timestamp_ms: u64): u64 {
    assert!(expiry_ms > 0, EInvalidExpiryWindow);

    let window = constants::leverage_borrow_window_ms!();
    let remaining = if (timestamp_ms >= expiry_ms) {
        0
    } else {
        expiry_ms - timestamp_ms
    };
    let elapsed = if (remaining >= window) {
        0
    } else {
        window - remaining
    };
    let phase = predict_math::mul_div_round_down(elapsed, constants::float_scaling!(), window);
    let phase_squared = predict_math::mul_div_round_down(
        phase,
        phase,
        constants::float_scaling!(),
    );

    constants::float_scaling!()
        + predict_math::mul_div_round_down(
            max_expiry_borrow_fee,
            phase_squared,
            constants::float_scaling!(),
        )
}

fun liquidate_order(
    exposure: &mut StrikeExposure,
    order_id: u256,
    position_value: u64,
    debt_amount: u64,
): LiquidatedOrder {
    let quantity = predict_order_id::quantity(order_id);
    let borrowed_principal = predict_order_id::borrowed_principal(order_id);
    exposure.remove_live_indexes(order_id);
    exposure.leverage_book.liquidate_order(order_id);
    let principal_recovered = position_value.min(borrowed_principal);
    LiquidatedOrder {
        order_id,
        quantity,
        borrowed_principal,
        debt_amount,
        borrow_fee_recovered: position_value - principal_recovered,
        position_value,
    }
}

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

fun insert_live_indexes(exposure: &mut StrikeExposure, order_id: u256) {
    let qty = predict_order_id::quantity(order_id);
    let (lower, higher) = exposure.order_strikes(order_id);
    let live = exposure.live.borrow_mut();
    live.payout.insert_range(lower, higher, qty);
    live.nav.insert_range(lower, higher, qty);
    track_minted_boundaries(live, lower, higher);
}

fun remove_live_indexes(exposure: &mut StrikeExposure, order_id: u256) {
    let qty = predict_order_id::quantity(order_id);
    let (lower, higher) = exposure.order_strikes(order_id);
    let live = exposure.live.borrow_mut();
    live.payout.remove_range(lower, higher, qty);
    live.nav.remove_range(lower, higher, qty);
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
