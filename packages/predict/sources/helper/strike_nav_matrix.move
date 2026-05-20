// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Dense strike exposure index for live NAV valuation.
///
/// The matrix preallocates page objects at market creation so user trades update
/// existing storage instead of lazily creating new dynamic fields. It stores
/// page-local prefix quantities and strike-weighted quantities for exact
/// valuation across sampled live pricing curve segments.
module deepbook_predict::strike_nav_matrix;

use deepbook::math;
use deepbook_predict::{constants, pricing::CurvePoint};
use sui::table::{Self, Table};

const PAGE_SLOTS: u64 = 128;

const EInvalidTickSize: u64 = 0;
const EInvalidStrikeRange: u64 = 1;
const EInsufficientQuantity: u64 = 2;
const EInvalidCurveRange: u64 = 4;
const EUnalignedStrike: u64 = 5;
const EZeroQuantity: u64 = 6;
const ETooManyStrikes: u64 = 7;

/// Dense preallocated page store for exact live NAV segment reads.
public struct StrikeNavMatrix has store {
    pages: Table<u64, vector<NavSlot>>,
    tick_size: u64,
    min_strike: u64,
    max_strike: u64,
    total_strikes: u64,
    base_qty: u64,
}

/// Page-local prefix totals at one finite strike grid slot.
public struct NavSlot has copy, drop, store {
    agg_q_start: u64,
    agg_qk_start: u64,
    agg_q_end: u64,
    agg_qk_end: u64,
}

/// Evaluate live option value against a sampled pricing curve.
public(package) fun live_value(
    nav: &StrikeNavMatrix,
    curve: &vector<CurvePoint>,
    minted_min_strike: u64,
    minted_max_strike: u64,
): u64 {
    let len = curve.length();
    if (len == 0) return 0;
    assert!(
        curve[0].strike() <= minted_min_strike && curve[len - 1].strike() >= minted_max_strike,
        EInvalidCurveRange,
    );

    let mut value = math::mul(nav.base_qty, constants::float_scaling!());
    let (mut page_lo, mut slot_lo) = nav.unchecked_strike_to_coords(curve[0].strike());
    let (q_start, q_end) = nav.boundary_quantities(page_lo, slot_lo);
    value = value + math::mul(q_start, curve[0].up_price());
    value = value - math::mul(q_end, curve[0].up_price());

    let mut ci = 1;
    while (ci < len) {
        let strike_lo = curve[ci - 1].strike();
        let strike_hi = curve[ci].strike();
        let price_lo = curve[ci - 1].up_price();
        let price_hi = curve[ci].up_price();
        let (page_hi, slot_hi) = nav.unchecked_strike_to_coords(strike_hi);
        let (
            q_start_delta,
            qk_start_delta,
            q_end_delta,
            qk_end_delta,
        ) = nav.accumulate_segment_values(page_lo, slot_lo, page_hi, slot_hi);

        if (q_start_delta > 0) {
            let p_avg = interpolate_price_at_avg_strike(
                q_start_delta,
                qk_start_delta,
                strike_lo,
                strike_hi,
                price_lo,
                price_hi,
            );
            value = value + math::mul(q_start_delta, p_avg);
        };

        if (q_end_delta > 0) {
            let p_end_avg = interpolate_price_at_avg_strike(
                q_end_delta,
                qk_end_delta,
                strike_lo,
                strike_hi,
                price_lo,
                price_hi,
            );
            value = value - math::mul(q_end_delta, p_end_avg);
        };

        page_lo = page_hi;
        slot_lo = slot_hi;
        ci = ci + 1;
    };

    value
}

/// Create a fully preallocated NAV matrix for the oracle strike grid.
public(package) fun new(
    tick_size: u64,
    min_strike: u64,
    max_strike: u64,
    ctx: &mut TxContext,
): StrikeNavMatrix {
    assert_valid_grid(tick_size, min_strike, max_strike);

    let total_strikes = (max_strike - min_strike) / tick_size + 1;
    let page_count = page_count(total_strikes);
    let mut pages = table::new(ctx);
    let mut page_key = 0;
    while (page_key < page_count) {
        pages.add(page_key, empty_nav_page());
        page_key = page_key + 1;
    };

    StrikeNavMatrix {
        pages,
        tick_size,
        min_strike,
        max_strike,
        total_strikes,
        base_qty: 0,
    }
}

/// Insert interval quantity for `(lower, higher]`.
public(package) fun insert_range(nav: &mut StrikeNavMatrix, lower: u64, higher: u64, qty: u64) {
    nav.apply_range(lower, higher, qty, true);
}

/// Remove interval quantity for `(lower, higher]`.
public(package) fun remove_range(nav: &mut StrikeNavMatrix, lower: u64, higher: u64, qty: u64) {
    nav.apply_range(lower, higher, qty, false);
}

/// Destroy all preallocated page storage.
public(package) fun destroy(nav: StrikeNavMatrix) {
    let StrikeNavMatrix {
        mut pages,
        tick_size: _,
        min_strike: _,
        max_strike: _,
        total_strikes,
        base_qty: _,
    } = nav;
    let page_count = page_count(total_strikes);
    let mut page_key = 0;
    while (page_key < page_count) {
        let _page = pages.remove(page_key);
        page_key = page_key + 1;
    };
    pages.destroy_empty();
}

// === Private Functions ===

fun boundary_quantities(nav: &StrikeNavMatrix, page_key: u64, slot: u64): (u64, u64) {
    let page = &nav.pages[page_key];
    let node = page[slot];
    if (slot == 0) {
        (node.agg_q_start, node.agg_q_end)
    } else {
        let prev = page[slot - 1];
        (node.agg_q_start - prev.agg_q_start, node.agg_q_end - prev.agg_q_end)
    }
}

fun accumulate_segment_values(
    nav: &StrikeNavMatrix,
    start_page: u64,
    start_slot: u64,
    end_page: u64,
    end_slot: u64,
): (u64, u64, u64, u64) {
    let mut page_key = start_page;
    let mut q_start_delta = 0;
    let mut qk_start_delta = 0;
    let mut q_end_delta = 0;
    let mut qk_end_delta = 0;
    while (page_key <= end_page) {
        let page = &nav.pages[page_key];
        let end_inclusive = if (page_key == end_page) {
            end_slot
        } else {
            PAGE_SLOTS - 1
        };
        let end_node = &page[end_inclusive];

        q_start_delta = q_start_delta + end_node.agg_q_start;
        qk_start_delta = qk_start_delta + end_node.agg_qk_start;
        q_end_delta = q_end_delta + end_node.agg_q_end;
        qk_end_delta = qk_end_delta + end_node.agg_qk_end;

        if (page_key == start_page) {
            let start_node = &page[start_slot];
            q_start_delta = q_start_delta - start_node.agg_q_start;
            qk_start_delta = qk_start_delta - start_node.agg_qk_start;
            q_end_delta = q_end_delta - start_node.agg_q_end;
            qk_end_delta = qk_end_delta - start_node.agg_qk_end;
        };

        if (page_key == end_page) break;
        page_key = page_key + 1;
    };

    (q_start_delta, qk_start_delta, q_end_delta, qk_end_delta)
}

fun empty_nav_page(): vector<NavSlot> {
    vector::tabulate!(
        PAGE_SLOTS,
        |_| NavSlot {
            agg_q_start: 0,
            agg_qk_start: 0,
            agg_q_end: 0,
            agg_qk_end: 0,
        },
    )
}

fun assert_valid_grid(tick_size: u64, min_strike: u64, max_strike: u64) {
    assert!(tick_size > 0, EInvalidTickSize);
    assert!(min_strike <= max_strike, EInvalidStrikeRange);
    assert!(min_strike % tick_size == 0 && max_strike % tick_size == 0, EUnalignedStrike);

    let total_strikes = (max_strike - min_strike) / tick_size + 1;
    assert!(total_strikes <= constants::oracle_strike_grid_ticks!() + 1, ETooManyStrikes);
}

fun assert_range_shape(lower: u64, higher: u64, qty: u64) {
    assert!(lower < higher, EInvalidStrikeRange);
    assert!(
        !(lower == constants::neg_inf!() && higher == constants::pos_inf!()),
        EInvalidStrikeRange,
    );
    assert!(qty > 0, EZeroQuantity);
}

fun interpolate_price_at_avg_strike(
    qty: u64,
    qty_strike: u64,
    strike_lo: u64,
    strike_hi: u64,
    price_lo: u64,
    price_hi: u64,
): u64 {
    let strike_avg = math::div(qty_strike, qty);
    let ratio = math::div((strike_avg - strike_lo), (strike_hi - strike_lo));
    if (price_hi >= price_lo) {
        price_lo + math::mul(price_hi - price_lo, ratio)
    } else {
        price_lo - math::mul(price_lo - price_hi, ratio)
    }
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

fun apply_range(nav: &mut StrikeNavMatrix, lower: u64, higher: u64, qty: u64, add: bool) {
    assert_range_shape(lower, higher, qty);
    if (lower == constants::neg_inf!()) {
        apply_exact_delta(&mut nav.base_qty, qty, add);
    } else {
        nav.apply_boundary_delta(lower, qty, true, add);
    };

    if (higher != constants::pos_inf!()) {
        nav.apply_boundary_delta(higher, qty, false, add);
    };
}

fun apply_boundary_delta(
    nav: &mut StrikeNavMatrix,
    strike: u64,
    qty: u64,
    is_start: bool,
    add: bool,
) {
    assert!(strike >= nav.min_strike && strike <= nav.max_strike, EInvalidStrikeRange);
    assert!((strike - nav.min_strike) % nav.tick_size == 0, EUnalignedStrike);

    let (page_key, slot) = nav.unchecked_strike_to_coords(strike);
    let qk = math::mul(qty, strike);
    {
        let page = nav.pages.borrow_mut(page_key);
        let mut i = slot;
        while (i < PAGE_SLOTS) {
            let tick_index = page_key * PAGE_SLOTS + i;
            if (tick_index >= nav.total_strikes) break;

            let node = &mut page[i];
            if (is_start) {
                apply_exact_delta(&mut node.agg_q_start, qty, add);
                apply_exact_delta(&mut node.agg_qk_start, qk, add);
            } else {
                apply_exact_delta(&mut node.agg_q_end, qty, add);
                apply_exact_delta(&mut node.agg_qk_end, qk, add);
            };
            i = i + 1;
        };
    };
}

fun apply_exact_delta(value: &mut u64, amount: u64, add: bool) {
    if (add) {
        *value = *value + amount;
    } else {
        assert!(*value >= amount, EInsufficientQuantity);
        *value = *value - amount;
    };
}
