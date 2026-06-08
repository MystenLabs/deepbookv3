// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Sparse-initialized strike exposure index for live NAV valuation.
///
/// The parent `StrikeExposure` owns the expiry `StrikeGrid`; callers must pass
/// that same grid into mutation and valuation APIs. The matrix does not duplicate
/// grid geometry in storage.
///
/// The matrix preallocates a centered subset of page objects at market creation
/// and lazily materializes outer pages on first write. It stores page-local
/// prefix quantities and strike-weighted quantities for exact valuation across
/// sampled live pricing curve segments, plus aggregate live floor shares for
/// contracts whose value has a non-zero floor. It also keeps in-object full-page
/// totals so wide valuation reads can skip page loads for complete middle pages.
module deepbook_predict::strike_nav_matrix;

use deepbook::math;
use deepbook_predict::{constants, pricing::CurvePoint, strike_grid::StrikeGrid};
use sui::table::{Self, Table};

const PAGE_SLOTS: u64 = 128;

const EInsufficientQuantity: u64 = 0;
const EInvalidCurveRange: u64 = 1;
const EZeroQuantity: u64 = 2;
const EInvalidPreallocatedTicks: u64 = 3;

/// Page store for exact live NAV segment reads.
public struct StrikeNavMatrix has store {
    pages: Table<u64, vector<NavTotals>>,
    page_totals: vector<NavTotals>,
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

/// Create a NAV matrix with a centered preallocated span for the oracle strike grid.
public(package) fun new(
    grid: &StrikeGrid,
    preallocated_ticks: u64,
    ctx: &mut TxContext,
): StrikeNavMatrix {
    let total_strikes = grid.total_strikes();
    assert_valid_preallocated_ticks(total_strikes, preallocated_ticks);
    let page_count = page_count(total_strikes);
    let mut pages = table::new(ctx);
    let mut page_totals = vector[];
    let mut page_key = 0;
    while (page_key < page_count) {
        page_totals.push_back(empty_nav_totals());
        page_key = page_key + 1;
    };
    let (start_page, end_page) = preallocated_page_bounds(total_strikes, preallocated_ticks);
    page_key = start_page;
    while (page_key <= end_page) {
        pages.add(page_key, empty_nav_page());
        page_key = page_key + 1;
    };

    StrikeNavMatrix {
        pages,
        page_totals,
        base_qty: 0,
        floor_shares: 0,
    }
}

/// Insert interval quantity for `(lower, higher]`.
public(package) fun insert_range(
    nav: &mut StrikeNavMatrix,
    grid: &StrikeGrid,
    lower: u64,
    higher: u64,
    qty: u64,
    floor_shares: u64,
) {
    nav.apply_range(grid, lower, higher, qty, floor_shares, true);
}

/// Remove interval quantity for `(lower, higher]`.
public(package) fun remove_range(
    nav: &mut StrikeNavMatrix,
    grid: &StrikeGrid,
    lower: u64,
    higher: u64,
    qty: u64,
    floor_shares: u64,
) {
    nav.apply_range(grid, lower, higher, qty, floor_shares, false);
}

/// Evaluate aggregate live contract range and floor values against a sampled pricing curve.
///
/// This is the valuation path used after the caller's bounded
/// liquidation-maintenance policy, not an exact per-order recoverability proof.
/// Returns `(total_range, total_floor_amount)`.
public(package) fun live_value(
    nav: &StrikeNavMatrix,
    grid: &StrikeGrid,
    curve: &vector<CurvePoint>,
    minted_min_strike: u64,
    minted_max_strike: u64,
    floor_index: u64,
): (u64, u64) {
    let len = curve.length();
    assert!(len > 0, EInvalidCurveRange);
    assert!(
        curve[0].strike() <= minted_min_strike && curve[len - 1].strike() >= minted_max_strike,
        EInvalidCurveRange,
    );

    let mut value = nav.base_qty;
    let (mut page_lo, mut slot_lo) = strike_to_coords(grid, curve[0].strike());
    let (start, end) = nav.boundary_weighted_quantities(page_lo, slot_lo);
    value = value + math::mul(start.quantity, curve[0].up_price());
    value = value - math::mul(end.quantity, curve[0].up_price());

    let mut ci = 1;
    while (ci < len) {
        let strike_lo = curve[ci - 1].strike();
        let strike_hi = curve[ci].strike();
        let price_lo = curve[ci - 1].up_price();
        let price_hi = curve[ci].up_price();
        let (page_hi, slot_hi) = strike_to_coords(grid, strike_hi);
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
    (value, floor_value)
}

/// Destroy all materialized page storage.
public(package) fun destroy(nav: StrikeNavMatrix) {
    let StrikeNavMatrix {
        mut pages,
        page_totals,
        base_qty: _,
        floor_shares: _,
    } = nav;
    let page_count = page_totals.length();
    let mut page_key = 0;
    while (page_key < page_count) {
        if (pages.contains(page_key)) {
            let _page = pages.remove(page_key);
        };
        page_key = page_key + 1;
    };
    pages.destroy_empty();
}

fun apply_range(
    nav: &mut StrikeNavMatrix,
    grid: &StrikeGrid,
    lower: u64,
    higher: u64,
    qty: u64,
    floor_shares: u64,
    add: bool,
) {
    assert_range_boundaries(grid, lower, higher, qty);
    apply_exact_delta(&mut nav.floor_shares, floor_shares, add);

    if (lower == constants::neg_inf!()) {
        apply_exact_delta(&mut nav.base_qty, qty, add);
    } else {
        nav.apply_boundary_delta(grid, lower, qty, true, add);
    };

    if (higher != constants::pos_inf!()) {
        nav.apply_boundary_delta(grid, higher, qty, false, add);
    };
}

fun floor_amount(floor_shares: u64, floor_index: u64): u64 {
    // Aggregate NAV rounds down so one-unit fixed-point dust cannot make
    // valuation abort; per-order redeem and settlement floors remain exact.
    math::mul(floor_shares, floor_index)
}

fun apply_boundary_delta(
    nav: &mut StrikeNavMatrix,
    grid: &StrikeGrid,
    strike: u64,
    qty: u64,
    is_start: bool,
    add: bool,
) {
    let (page_key, slot) = strike_to_coords(grid, strike);
    let weighted = weighted_quantity(qty, math::mul(qty, strike));
    nav.ensure_page(page_key);
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
            if (tick_index >= grid.total_strikes()) break;

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
    let node = nav.page_prefix_totals(page_key, slot);
    if (slot == 0) {
        (node.start, node.end)
    } else {
        let prev = nav.page_prefix_totals(page_key, slot - 1);
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
        let end_node = nav.page_prefix_totals(end_page, end_slot);
        let mut start_delta = end_node.start;
        let mut end_delta = end_node.end;
        let start_node = nav.page_prefix_totals(start_page, start_slot);
        apply_weighted_delta(&mut start_delta, start_node.start, false);
        apply_weighted_delta(&mut end_delta, start_node.end, false);
        return (start_delta, end_delta)
    };

    let first_end = nav.page_totals[start_page];
    let mut start_delta = first_end.start;
    let mut end_delta = first_end.end;
    let first_start = nav.page_prefix_totals(start_page, start_slot);
    apply_weighted_delta(&mut start_delta, first_start.start, false);
    apply_weighted_delta(&mut end_delta, first_start.end, false);

    let mut page_key = start_page + 1;
    while (page_key < end_page) {
        let totals = nav.page_totals[page_key];
        apply_weighted_delta(&mut start_delta, totals.start, true);
        apply_weighted_delta(&mut end_delta, totals.end, true);
        page_key = page_key + 1;
    };

    let last_end = nav.page_prefix_totals(end_page, end_slot);
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

fun ensure_page(nav: &mut StrikeNavMatrix, page_key: u64) {
    if (!nav.pages.contains(page_key)) {
        nav.pages.add(page_key, empty_nav_page());
    };
}

fun page_prefix_totals(nav: &StrikeNavMatrix, page_key: u64, slot: u64): NavTotals {
    if (nav.pages.contains(page_key)) {
        nav.pages.borrow(page_key)[slot]
    } else {
        empty_nav_totals()
    }
}

fun assert_valid_preallocated_ticks(total_strikes: u64, preallocated_ticks: u64) {
    assert!(preallocated_ticks <= total_strikes - 1, EInvalidPreallocatedTicks);
}

fun preallocated_page_bounds(total_strikes: u64, preallocated_ticks: u64): (u64, u64) {
    let total_ticks = total_strikes - 1;
    let center_tick = total_ticks / 2;
    let start_tick = center_tick - preallocated_ticks / 2;
    let end_tick = start_tick + preallocated_ticks;

    (start_tick / PAGE_SLOTS, end_tick / PAGE_SLOTS)
}

fun assert_range_boundaries(grid: &StrikeGrid, lower: u64, higher: u64, qty: u64) {
    assert!(qty > 0, EZeroQuantity);
    grid.assert_range_boundaries(lower, higher);
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

fun strike_to_coords(grid: &StrikeGrid, strike: u64): (u64, u64) {
    let tick_index = grid.finite_strike_index(strike);
    let page_key = tick_index / PAGE_SLOTS;
    let slot = tick_index % PAGE_SLOTS;
    (page_key, slot)
}

fun page_count(total_strikes: u64): u64 {
    (total_strikes - 1) / PAGE_SLOTS + 1
}
