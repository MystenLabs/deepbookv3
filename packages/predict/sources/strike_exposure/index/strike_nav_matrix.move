// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Dense strike exposure index for live NAV valuation.
///
/// The matrix preallocates page objects at market creation so user trades update
/// existing storage instead of lazily creating new dynamic fields. It stores
/// page-local prefix quantities and strike-weighted quantities for exact
/// valuation across sampled live pricing curve segments, plus aggregate live
/// floor shares for contracts whose value has a non-zero floor. It also keeps
/// in-object full-page totals so wide valuation reads can skip dynamic-field
/// page loads for complete middle pages.
module deepbook_predict::strike_nav_matrix;

use deepbook::math;
use deepbook_predict::{constants, math as predict_math, pricing::CurvePoint};
use sui::table::{Self, Table};

const PAGE_SLOTS: u64 = 128;

const EInvalidTickSize: u64 = 0;
const EInvalidStrikeRange: u64 = 1;
const EInsufficientQuantity: u64 = 2;
const EInvalidCurveRange: u64 = 4;
const EUnalignedStrike: u64 = 5;
const EZeroQuantity: u64 = 6;
const ETooManyStrikes: u64 = 7;
const EFloorExceedsLiveValue: u64 = 8;

/// Dense preallocated page store for exact live NAV segment reads.
public struct StrikeNavMatrix has store {
    pages: Table<u64, vector<NavTotals>>,
    page_totals: vector<NavTotals>,
    tick_size: u64,
    min_strike: u64,
    max_strike: u64,
    total_strikes: u64,
    base_qty: u64,
    /// Floor-index-normalized aggregate contract floor, realized with round-down math.
    floor_shares: u64,
}

/// Quantity and strike-weighted quantity tracked together for one boundary side.
public struct WeightedQuantity has copy, drop, store {
    quantity: u64,
    strike_quantity: u64,
}

/// Boundary totals for either one page-local prefix slot or one full page.
public struct NavTotals has copy, drop, store {
    start: WeightedQuantity,
    end: WeightedQuantity,
}

/// Create a fully preallocated NAV matrix for the oracle strike grid.
public(package) fun new(
    min_strike: u64,
    tick_size: u64,
    max_strike: u64,
    ctx: &mut TxContext,
): StrikeNavMatrix {
    assert_valid_grid(min_strike, tick_size, max_strike);

    let total_strikes = (max_strike - min_strike) / tick_size + 1;
    let page_count = page_count(total_strikes);
    let mut pages = table::new(ctx);
    let mut page_totals = vector[];
    let mut page_key = 0;
    while (page_key < page_count) {
        pages.add(page_key, empty_nav_page());
        page_totals.push_back(empty_nav_totals());
        page_key = page_key + 1;
    };

    StrikeNavMatrix {
        pages,
        page_totals,
        tick_size,
        min_strike,
        max_strike,
        total_strikes,
        base_qty: 0,
        floor_shares: 0,
    }
}

/// Insert interval quantity for `(lower, higher]`.
public(package) fun insert_range(
    nav: &mut StrikeNavMatrix,
    lower: u64,
    higher: u64,
    qty: u64,
    floor_shares: u64,
) {
    nav.apply_range(lower, higher, qty, floor_shares, true);
}

/// Remove interval quantity for `(lower, higher]`.
public(package) fun remove_range(
    nav: &mut StrikeNavMatrix,
    lower: u64,
    higher: u64,
    qty: u64,
    floor_shares: u64,
) {
    nav.apply_range(lower, higher, qty, floor_shares, false);
}

/// Evaluate live contract value against a sampled pricing curve.
///
/// The matrix subtracts aggregate floor value from aggregate range value. This
/// is the valuation path used after the caller's bounded liquidation-maintenance
/// policy, not an exact per-order recoverability proof.
public(package) fun live_value(
    nav: &StrikeNavMatrix,
    curve: &vector<CurvePoint>,
    minted_min_strike: u64,
    minted_max_strike: u64,
    floor_index: u64,
): u64 {
    let len = curve.length();
    assert!(len > 0, EInvalidCurveRange);
    assert!(
        curve[0].strike() <= minted_min_strike && curve[len - 1].strike() >= minted_max_strike,
        EInvalidCurveRange,
    );

    let mut value = math::mul(nav.base_qty, constants::float_scaling!());
    let (mut page_lo, mut slot_lo) = nav.unchecked_strike_to_coords(curve[0].strike());
    let (start, end) = nav.boundary_weighted_quantities(page_lo, slot_lo);
    value = value + math::mul(start.quantity, curve[0].up_price());
    value = value - math::mul(end.quantity, curve[0].up_price());

    let mut ci = 1;
    while (ci < len) {
        let strike_lo = curve[ci - 1].strike();
        let strike_hi = curve[ci].strike();
        let price_lo = curve[ci - 1].up_price();
        let price_hi = curve[ci].up_price();
        let (page_hi, slot_hi) = nav.unchecked_strike_to_coords(strike_hi);
        let (start_delta, end_delta) = nav.accumulate_segment_values(
            page_lo,
            slot_lo,
            page_hi,
            slot_hi,
        );

        value =
            value + weighted_segment_value(start_delta, strike_lo, strike_hi, price_lo, price_hi);
        value = value - weighted_segment_value(end_delta, strike_lo, strike_hi, price_lo, price_hi);

        page_lo = page_hi;
        slot_lo = slot_hi;
        ci = ci + 1;
    };

    let floor_value = floor_amount(nav.floor_shares, floor_index);
    assert!(value >= floor_value, EFloorExceedsLiveValue);
    value - floor_value
}

/// Destroy all preallocated page storage.
public(package) fun destroy(nav: StrikeNavMatrix) {
    let StrikeNavMatrix {
        mut pages,
        page_totals: _,
        tick_size: _,
        min_strike: _,
        max_strike: _,
        total_strikes,
        base_qty: _,
        floor_shares: _,
    } = nav;
    let page_count = page_count(total_strikes);
    let mut page_key = 0;
    while (page_key < page_count) {
        let _page = pages.remove(page_key);
        page_key = page_key + 1;
    };
    pages.destroy_empty();
}

fun apply_range(
    nav: &mut StrikeNavMatrix,
    lower: u64,
    higher: u64,
    qty: u64,
    floor_shares: u64,
    add: bool,
) {
    nav.assert_range_boundaries(lower, higher, qty);
    apply_exact_delta(&mut nav.floor_shares, floor_shares, add);

    if (lower == constants::neg_inf!()) {
        apply_exact_delta(&mut nav.base_qty, qty, add);
    } else {
        nav.apply_boundary_delta(lower, qty, true, add);
    };

    if (higher != constants::pos_inf!()) {
        nav.apply_boundary_delta(higher, qty, false, add);
    };
}

fun floor_amount(floor_shares: u64, floor_index: u64): u64 {
    // Aggregate NAV rounds down so one-unit fixed-point dust cannot make
    // valuation abort; per-order redeem and settlement floors remain exact.
    predict_math::mul_div_round_down(floor_shares, floor_index, constants::float_scaling!())
}

fun apply_boundary_delta(
    nav: &mut StrikeNavMatrix,
    strike: u64,
    qty: u64,
    is_start: bool,
    add: bool,
) {
    let (page_key, slot) = nav.unchecked_strike_to_coords(strike);
    let weighted = weighted_quantity(qty, math::mul(qty, strike));
    {
        let totals = &mut nav.page_totals[page_key];
        if (is_start) {
            apply_weighted_delta(&mut totals.start, weighted, add);
        } else {
            apply_weighted_delta(&mut totals.end, weighted, add);
        };
    };
    {
        let page = nav.pages.borrow_mut(page_key);
        let mut i = slot;
        while (i < PAGE_SLOTS) {
            let tick_index = page_key * PAGE_SLOTS + i;
            if (tick_index >= nav.total_strikes) break;

            let node = &mut page[i];
            if (is_start) {
                apply_weighted_delta(&mut node.start, weighted, add);
            } else {
                apply_weighted_delta(&mut node.end, weighted, add);
            };
            i = i + 1;
        };
    };
}

fun boundary_weighted_quantities(
    nav: &StrikeNavMatrix,
    page_key: u64,
    slot: u64,
): (WeightedQuantity, WeightedQuantity) {
    let page = &nav.pages[page_key];
    let node = page[slot];
    if (slot == 0) {
        (node.start, node.end)
    } else {
        let prev = page[slot - 1];
        let mut start = node.start;
        let mut end = node.end;
        apply_weighted_delta(&mut start, prev.start, false);
        apply_weighted_delta(&mut end, prev.end, false);
        (start, end)
    }
}

fun accumulate_segment_values(
    nav: &StrikeNavMatrix,
    start_page: u64,
    start_slot: u64,
    end_page: u64,
    end_slot: u64,
): (WeightedQuantity, WeightedQuantity) {
    if (start_page == end_page) {
        let page = &nav.pages[start_page];
        let end_node = &page[end_slot];
        let mut start_delta = end_node.start;
        let mut end_delta = end_node.end;
        let start_node = &page[start_slot];
        apply_weighted_delta(&mut start_delta, start_node.start, false);
        apply_weighted_delta(&mut end_delta, start_node.end, false);
        return (start_delta, end_delta)
    };

    let first_page = &nav.pages[start_page];
    let first_end = &first_page[PAGE_SLOTS - 1];
    let mut start_delta = first_end.start;
    let mut end_delta = first_end.end;
    let first_start = &first_page[start_slot];
    apply_weighted_delta(&mut start_delta, first_start.start, false);
    apply_weighted_delta(&mut end_delta, first_start.end, false);

    let mut page_key = start_page + 1;
    while (page_key < end_page) {
        let totals = nav.page_totals[page_key];
        apply_weighted_delta(&mut start_delta, totals.start, true);
        apply_weighted_delta(&mut end_delta, totals.end, true);
        page_key = page_key + 1;
    };

    let last_page = &nav.pages[end_page];
    let last_end = &last_page[end_slot];
    apply_weighted_delta(&mut start_delta, last_end.start, true);
    apply_weighted_delta(&mut end_delta, last_end.end, true);

    (start_delta, end_delta)
}

fun empty_nav_totals(): NavTotals {
    NavTotals {
        start: weighted_quantity(0, 0),
        end: weighted_quantity(0, 0),
    }
}

fun empty_nav_page(): vector<NavTotals> {
    vector::tabulate!(PAGE_SLOTS, |_| empty_nav_totals())
}

fun assert_valid_grid(min_strike: u64, tick_size: u64, max_strike: u64) {
    assert!(tick_size > 0, EInvalidTickSize);
    assert!(min_strike <= max_strike, EInvalidStrikeRange);
    assert!(min_strike % tick_size == 0 && max_strike % tick_size == 0, EUnalignedStrike);

    let total_strikes = (max_strike - min_strike) / tick_size + 1;
    assert!(total_strikes <= constants::oracle_strike_grid_ticks!() + 1, ETooManyStrikes);
}

fun assert_range_boundaries(nav: &StrikeNavMatrix, lower: u64, higher: u64, qty: u64) {
    assert_range_shape(lower, higher, qty);
    if (lower != constants::neg_inf!()) nav.assert_finite_boundary(lower);
    if (higher != constants::pos_inf!()) nav.assert_finite_boundary(higher);
}

fun assert_finite_boundary(nav: &StrikeNavMatrix, strike: u64) {
    assert!(strike >= nav.min_strike && strike <= nav.max_strike, EInvalidStrikeRange);
    assert!((strike - nav.min_strike) % nav.tick_size == 0, EUnalignedStrike);
}

fun assert_range_shape(lower: u64, higher: u64, qty: u64) {
    assert!(lower < higher, EInvalidStrikeRange);
    assert!(
        !(lower == constants::neg_inf!() && higher == constants::pos_inf!()),
        EInvalidStrikeRange,
    );
    assert!(qty > 0, EZeroQuantity);
}

fun weighted_quantity(quantity: u64, strike_quantity: u64): WeightedQuantity {
    WeightedQuantity { quantity, strike_quantity }
}

fun apply_exact_delta(value: &mut u64, amount: u64, add: bool) {
    if (add) {
        *value = *value + amount;
    } else {
        assert!(*value >= amount, EInsufficientQuantity);
        *value = *value - amount;
    };
}

fun apply_weighted_delta(value: &mut WeightedQuantity, delta: WeightedQuantity, add: bool) {
    if (add) {
        value.quantity = value.quantity + delta.quantity;
        value.strike_quantity = value.strike_quantity + delta.strike_quantity;
    } else {
        assert!(value.quantity >= delta.quantity, EInsufficientQuantity);
        assert!(value.strike_quantity >= delta.strike_quantity, EInsufficientQuantity);
        value.quantity = value.quantity - delta.quantity;
        value.strike_quantity = value.strike_quantity - delta.strike_quantity;
    };
}

fun weighted_segment_value(
    weighted: WeightedQuantity,
    strike_lo: u64,
    strike_hi: u64,
    price_lo: u64,
    price_hi: u64,
): u64 {
    if (weighted.quantity == 0) return 0;
    let strike_avg = math::div(weighted.strike_quantity, weighted.quantity);
    let ratio = math::div((strike_avg - strike_lo), (strike_hi - strike_lo));
    let price = if (price_hi >= price_lo) {
        price_lo + math::mul(price_hi - price_lo, ratio)
    } else {
        price_lo - math::mul(price_lo - price_hi, ratio)
    };
    math::mul(weighted.quantity, price)
}

fun unchecked_strike_to_coords(nav: &StrikeNavMatrix, strike: u64): (u64, u64) {
    let tick_index = (strike - nav.min_strike) / nav.tick_size;
    let page_key = tick_index / PAGE_SLOTS;
    let slot = tick_index % PAGE_SLOTS;
    (page_key, slot)
}

fun page_count(total_strikes: u64): u64 {
    (total_strikes - 1) / PAGE_SLOTS + 1
}
