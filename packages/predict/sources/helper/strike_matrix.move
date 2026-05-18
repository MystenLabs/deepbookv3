// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Fixed strike-grid exposure store for one oracle.
///
/// This module serves three different queries:
/// 1. live valuation against a sampled price curve
/// 2. exact worst-case settled payout (`max_payout`)
/// 3. aggregate fee-basis valuation for settlement loss rebates
///
/// Live valuation needs fast strike-range reads. For that, each page stores
/// interval boundary aggregates so a segment can recover exact `qty` and
/// `qty * strike` without scanning every strike in the range.
///
/// Exact `max_payout` is a different problem. For a settlement boundary `s`:
/// - interval starts at lower bounds `< s`
/// - interval ends at upper bounds `< s`
///
/// So:
///     payout(s) = base_qty + prefix_sum(q_start - q_end)
///
/// That means exact `max_payout` is the maximum prefix score over strikes in
/// sorted order. A single total is not enough; after each update we need enough
/// structure to recover the best prefix over the whole book.
///
/// The layout is therefore hybrid:
/// - `pages` is a `Table<u64, vector<StrikeNode>>`, with one dynamic-field lookup
///   per 512-strike page instead of one lookup per strike.
/// - creation preallocates the center half of the page range, while outer pages
///   are allocated lazily on first insert and otherwise treated as zero pages.
/// - Each `StrikeNode` stores exact `q_start` / `q_end` plus page-local
///   aggregates used by live valuation range reads.
/// - `page_tree` is an inline vector-backed tree of page summaries. Each summary
///   keeps:
///     * `total_q_start`
///     * `total_q_end`
///     * the best prefix in that page/range, encoded as
///       `(best_prefix_start, best_prefix_end)`
///     * the minimum fee-basis prefix in that page/range, used as a conservative
///       live rebate reserve without tracking fee-weighted live value per node
///
/// The best prefix is stored as an unsigned pair instead of a signed scalar
/// because Move has no native signed integers.
///
/// Update algorithm:
/// - rewrite the touched 512-slot page
/// - recompute that page's summary
/// - merge summaries up the inline tree
///
/// Merge rule:
/// - totals add componentwise
/// - the best prefix of `left + right` is either:
///     * the best prefix entirely inside `left`, or
///     * all of `left` plus the best prefix of `right`
///
/// After that path is rebuilt, the root summary is enough to answer the raw
/// interval peak:
///     base_qty + root.best_prefix_start - root.best_prefix_end
///
/// So the design is intentionally asymmetric:
/// - page-local aggregates optimize live valuation
/// - the inline summary tree optimizes exact `max_payout`
/// - dynamic-field pressure stays bounded because only leaf pages live in `Table`
module deepbook_predict::strike_matrix;

use deepbook::{constants::max_u64, math};
use deepbook_predict::{constants, pricing::CurvePoint};
use sui::table::{Self, Table};

const PAGE_SLOTS: u64 = 256;

const EInvalidTickSize: u64 = 0;
const EInvalidStrikeRange: u64 = 1;
const EZeroQuantity: u64 = 6;
const EUnalignedStrike: u64 = 5;
const EInsufficientQuantity: u64 = 2;
const ENonMonotoneCurve: u64 = 3;
const EInvalidCurveRange: u64 = 4;
const ETooManyStrikes: u64 = 7;

/// Dense strike-indexed book with page-level summaries stored in an inline tree.
public struct StrikeMatrix has store {
    pages: Table<u64, vector<StrikeNode>>,
    page_tree: vector<PageSummary>,
    page_tree_leaf_count: u64,
    tick_size: u64,
    min_strike: u64,
    max_strike: u64,
    minted_min_strike: u64,
    minted_max_strike: u64,
    max_payout: u64,
    /// Raw fees attached to active intervals before applying outcome/rebate rates.
    total_fee_basis: u64,
    /// Quantity and fee basis active before the first finite strike, from
    /// `(-inf, higher]` intervals.
    base_qty: u64,
    base_fee_basis: u64,
}

/// Exact per-strike quantity and fee-basis inventory stored in dense page slots.
public struct StrikeNode has copy, drop, store {
    q_start: u64,
    q_end: u64,
    fee_start: u64,
    fee_end: u64,
    agg_q_start: u64,
    agg_qk_start: u64,
    agg_q_end: u64,
    agg_qk_end: u64,
}

/// Aggregate summary for one page or one internal page-range node.
public struct PageSummary has copy, drop, store {
    total_q_start: u64,
    total_q_end: u64,
    best_prefix_start: u64,
    best_prefix_end: u64,
    total_fee_start: u64,
    total_fee_end: u64,
    min_fee_prefix_start: u64,
    min_fee_prefix_end: u64,
}

// === Public-Package Functions ===

/// Allocate the center strike pages for the oracle grid and a zeroed page-summary tree.
public(package) fun new(
    ctx: &mut TxContext,
    tick_size: u64,
    min_strike: u64,
    max_strike: u64,
): StrikeMatrix {
    assert!(tick_size > 0, EInvalidTickSize);
    assert!(min_strike <= max_strike, EInvalidStrikeRange);
    assert!(min_strike % tick_size == 0 && max_strike % tick_size == 0, EUnalignedStrike);

    let total_strikes = (max_strike - min_strike) / tick_size + 1;
    assert!(total_strikes <= constants::oracle_strike_grid_ticks!() + 1, ETooManyStrikes);
    let page_count = (total_strikes - 1) / PAGE_SLOTS + 1;
    let page_tree_leaf_count = next_pow_2(page_count);
    let page_tree_len = 2 * page_tree_leaf_count - 1;
    let preallocated_page_count = (page_count + 1) / 2;
    let preallocated_page_start = (page_count - preallocated_page_count) / 2;
    let preallocated_page_end = preallocated_page_start + preallocated_page_count;

    let mut pages = table::new(ctx);
    let mut page_key = preallocated_page_start;
    while (page_key < preallocated_page_end) {
        pages.add(page_key, empty_page());
        page_key = page_key + 1;
    };

    let page_tree = vector::tabulate!(page_tree_len, |_| empty_summary());

    StrikeMatrix {
        pages,
        page_tree,
        page_tree_leaf_count,
        tick_size,
        min_strike,
        max_strike,
        minted_min_strike: max_u64(),
        minted_max_strike: 0,
        max_payout: 0,
        total_fee_basis: 0,
        base_qty: 0,
        base_fee_basis: 0,
    }
}

/// Insert interval quantity for `(lower, higher]`.
public(package) fun insert_range(
    matrix: &mut StrikeMatrix,
    lower: u64,
    higher: u64,
    qty: u64,
    fee_basis: u64,
) {
    matrix.apply_range(lower, higher, qty, fee_basis, true);
}

/// Remove interval quantity for `(lower, higher]`.
public(package) fun remove_range(
    matrix: &mut StrikeMatrix,
    lower: u64,
    higher: u64,
    qty: u64,
    fee_basis: u64,
) {
    matrix.apply_range(lower, higher, qty, fee_basis, false);
}

/// Return the exact worst-case settled payout across all settlement prices.
public(package) fun max_payout(matrix: &StrikeMatrix): u64 {
    matrix.max_payout
}

/// Evaluate live option value and conservative maximum losing fee basis.
public(package) fun live_values(matrix: &StrikeMatrix, curve: &vector<CurvePoint>): (u64, u64) {
    let option_value = matrix.evaluate(curve);
    let root = matrix.page_tree[0];
    let min_winning_fee_basis =
        matrix.base_fee_basis + root.min_fee_prefix_start - root.min_fee_prefix_end;
    let conservative_losing_fee_basis = matrix.total_fee_basis - min_winning_fee_basis;
    (option_value, conservative_losing_fee_basis)
}

/// Evaluate settled liability and exact losing fee basis.
public(package) fun settled_values(matrix: &StrikeMatrix, settlement: u64): (u64, u64) {
    let (settled_liability, winning_fee_basis) = matrix.evaluate_settled(settlement);
    (settled_liability, matrix.total_fee_basis - winning_fee_basis)
}

/// Return the strike grid this matrix was created with.
public(package) fun strike_grid(matrix: &StrikeMatrix): (u64, u64, u64) {
    (matrix.min_strike, matrix.tick_size, matrix.max_strike)
}

/// Return the historical minted strike bounds, or `(0, 0)` for an untouched
/// book. These bounds only expand on insert and never contract on remove.
public(package) fun minted_strike_range(matrix: &StrikeMatrix): (u64, u64) {
    if (matrix.minted_min_strike > matrix.minted_max_strike) (0, 0) else (
        matrix.minted_min_strike,
        matrix.minted_max_strike,
    )
}

/// Consume a dense matrix after settlement and return exact settled liability.
public(package) fun into_settled_liability(matrix: StrikeMatrix, settlement: u64): u64 {
    let StrikeMatrix {
        mut pages,
        page_tree: _,
        page_tree_leaf_count: _,
        tick_size,
        min_strike,
        max_strike,
        minted_min_strike: _,
        minted_max_strike: _,
        max_payout: _,
        total_fee_basis: _,
        base_qty,
        base_fee_basis: _,
    } = matrix;

    let total_strikes = (max_strike - min_strike) / tick_size + 1;
    let page_count = (total_strikes - 1) / PAGE_SLOTS + 1;
    let mut remaining_liability = base_qty;
    let mut page_key = 0;

    while (page_key < page_count) {
        if (pages.contains(page_key)) {
            let page = pages.remove(page_key);
            let mut slot = 0;
            while (slot < PAGE_SLOTS) {
                let tick_index = page_key * PAGE_SLOTS + slot;
                if (tick_index >= total_strikes) break;

                let strike = min_strike + tick_index * tick_size;
                let q_start = page[slot].q_start;
                let q_end = page[slot].q_end;
                if (strike < settlement) {
                    remaining_liability = remaining_liability + q_start - q_end;
                };
                slot = slot + 1;
            };
        };
        page_key = page_key + 1;
    };

    pages.destroy_empty();
    remaining_liability
}

// === Private Functions ===

/// Evaluate the current interval book against a sampled live curve.
fun evaluate(matrix: &StrikeMatrix, curve: &vector<CurvePoint>): u64 {
    let len = curve.length();
    if (len == 0) return 0;
    assert!(
        curve[0].strike() <= matrix.minted_min_strike
        && curve[len - 1].strike() >= matrix.minted_max_strike,
        EInvalidCurveRange,
    );

    let mut value = math::mul(matrix.base_qty, constants::float_scaling!());
    let (mut page_lo, mut slot_lo) = matrix.strike_to_coords(curve[0].strike());

    let page = &matrix.pages[page_lo];
    value = value + math::mul(page[slot_lo].q_start, curve[0].up_price());
    value = value - math::mul(page[slot_lo].q_end, curve[0].up_price());

    let mut ci = 1;
    while (ci < len) {
        let ci_strike = curve[ci].strike();
        let ci_strike_prev = curve[ci - 1].strike();
        let ci_up_price = curve[ci].up_price();
        let ci_up_price_prev = curve[ci - 1].up_price();
        let (page_hi, slot_hi) = matrix.strike_to_coords(ci_strike);
        let (
            q_start_delta,
            qk_start_delta,
            q_end_delta,
            qk_end_delta,
        ) = matrix.accumulate_segment_values(page_lo, slot_lo, page_hi, slot_hi);

        if (q_start_delta > 0) {
            assert!(ci_up_price_prev >= ci_up_price, ENonMonotoneCurve);
            let p_avg = interpolate_price_at_avg_strike(
                q_start_delta,
                qk_start_delta,
                ci_strike_prev,
                ci_strike,
                ci_up_price_prev,
                ci_up_price,
            );
            value = value + math::mul(q_start_delta, p_avg);
        };

        if (q_end_delta > 0) {
            assert!(ci_up_price_prev >= ci_up_price, ENonMonotoneCurve);
            let p_end_avg = interpolate_price_at_avg_strike(
                q_end_delta,
                qk_end_delta,
                ci_strike_prev,
                ci_strike,
                ci_up_price_prev,
                ci_up_price,
            );
            value = value - math::mul(q_end_delta, p_end_avg);
        };

        page_lo = page_hi;
        slot_lo = slot_hi;
        ci = ci + 1;
    };

    value
}

/// Evaluate exact settled liability for a concrete settlement price.
fun evaluate_settled(matrix: &StrikeMatrix, settlement: u64): (u64, u64) {
    if (matrix.minted_max_strike < matrix.minted_min_strike) return (0, 0);

    let (min_page, min_slot) = matrix.strike_to_coords(matrix.minted_min_strike);
    let (max_page, max_slot) = matrix.strike_to_coords(matrix.minted_max_strike);
    let mut value = matrix.base_qty;
    let mut winning_fee_basis = matrix.base_fee_basis;
    let mut page_key = min_page;
    while (page_key <= max_page) {
        if (matrix.pages.contains(page_key)) {
            let page = &matrix.pages[page_key];
            let start_slot = if (page_key == min_page) { min_slot } else { 0 };
            let end_slot = if (page_key == max_page) {
                max_slot
            } else {
                PAGE_SLOTS - 1
            };
            let mut slot = start_slot;
            while (slot <= end_slot) {
                let strike = matrix.strike_from_coords(page_key, slot);
                if (strike < settlement) {
                    value = value + page[slot].q_start - page[slot].q_end;
                    winning_fee_basis =
                        winning_fee_basis + page[slot].fee_start - page[slot].fee_end;
                };

                slot = slot + 1;
            };
        };

        page_key = page_key + 1;
    };

    (value, winning_fee_basis)
}

fun compute_max_payout(matrix: &StrikeMatrix): u64 {
    let root = matrix.page_tree[0];
    matrix.base_qty + root.best_prefix_start - root.best_prefix_end
}

/// Apply interval quantity as start/end boundary deltas. The lower endpoint is
/// exclusive and the upper endpoint is inclusive, so live valuation uses
/// `UP@strike` prices: starts add value and ends subtract it.
fun apply_range(
    matrix: &mut StrikeMatrix,
    lower: u64,
    higher: u64,
    qty: u64,
    fee_basis: u64,
    add: bool,
) {
    matrix.assert_can_apply_range(lower, higher, qty, fee_basis, add);

    apply_exact_delta(&mut matrix.total_fee_basis, fee_basis, add);

    if (lower == constants::neg_inf!()) {
        apply_exact_delta(&mut matrix.base_qty, qty, add);
        apply_exact_delta(&mut matrix.base_fee_basis, fee_basis, add);
    } else {
        matrix.apply_boundary_delta(lower, qty, fee_basis, true, add);
    };

    if (higher != constants::pos_inf!()) {
        matrix.apply_boundary_delta(higher, qty, fee_basis, false, add);
    };

    matrix.max_payout = matrix.compute_max_payout();
}

fun assert_can_apply_range(
    matrix: &StrikeMatrix,
    lower: u64,
    higher: u64,
    qty: u64,
    fee_basis: u64,
    add: bool,
) {
    assert!(lower < higher, EInvalidStrikeRange);
    assert!(
        !(lower == constants::neg_inf!() && higher == constants::pos_inf!()),
        EInvalidStrikeRange,
    );
    assert!(qty > 0, EZeroQuantity);
    if (!add) assert!(matrix.total_fee_basis >= fee_basis, EInsufficientQuantity);

    if (lower == constants::neg_inf!()) {
        if (!add) {
            assert!(matrix.base_qty >= qty, EInsufficientQuantity);
            assert!(matrix.base_fee_basis >= fee_basis, EInsufficientQuantity);
        };
    } else {
        matrix.assert_boundary_update_allowed(lower, qty, fee_basis, true, add);
    };

    if (higher != constants::pos_inf!()) {
        matrix.assert_boundary_update_allowed(higher, qty, fee_basis, false, add);
    };
}

fun assert_boundary_update_allowed(
    matrix: &StrikeMatrix,
    strike: u64,
    qty: u64,
    fee_basis: u64,
    is_start: bool,
    add: bool,
) {
    let (page_index, slot) = matrix.strike_to_coords(strike);
    if (!add) {
        assert!(matrix.pages.contains(page_index), EInsufficientQuantity);
        let page = &matrix.pages[page_index];
        let available_qty = if (is_start) { page[slot].q_start } else { page[slot].q_end };
        let available_fee_basis = if (is_start) {
            page[slot].fee_start
        } else {
            page[slot].fee_end
        };
        assert!(available_qty >= qty, EInsufficientQuantity);
        assert!(available_fee_basis >= fee_basis, EInsufficientQuantity);
    };
}

/// Apply one finite boundary delta, refresh the touched page summary, then
/// rebuild the ancestor path in the inline page tree.
fun apply_boundary_delta(
    matrix: &mut StrikeMatrix,
    strike: u64,
    qty: u64,
    fee_basis: u64,
    is_start: bool,
    add: bool,
) {
    let (page_index, slot) = matrix.strike_to_coords(strike);
    if (add && !matrix.pages.contains(page_index)) {
        matrix.pages.add(page_index, empty_page());
    };
    apply_delta_and_recompute_page(matrix, page_index, slot, qty, fee_basis, is_start, add);
    if (add) {
        matrix.minted_min_strike = matrix.minted_min_strike.min(strike);
        matrix.minted_max_strike = matrix.minted_max_strike.max(strike);
    };
    recompute_page_tree_path(matrix, page_index);
}

/// Apply a delta, aborting before underflow on removal.
fun apply_exact_delta(value: &mut u64, amount: u64, add: bool) {
    if (add) {
        *value = *value + amount;
    } else {
        assert!(*value >= amount, EInsufficientQuantity);
        *value = *value - amount;
    };
}

/// Update one start/end boundary and rebuild the touched page in a single
/// left-to-right pass.
fun apply_delta_and_recompute_page(
    matrix: &mut StrikeMatrix,
    page_index: u64,
    slot_index: u64,
    qty: u64,
    fee_basis: u64,
    is_start: bool,
    add: bool,
) {
    let tree_index = matrix.page_tree_leaf_count - 1 + page_index;
    let min_strike = matrix.min_strike;
    let tick_size = matrix.tick_size;
    let mut summary = empty_summary();
    let mut prefix_start = 0;
    let mut prefix_end = 0;
    let mut prefix_qk_start = 0;
    let mut prefix_qk_end = 0;
    let mut prefix_fee_start = 0;
    let mut prefix_fee_end = 0;

    {
        let page = matrix.pages.borrow_mut(page_index);
        if (is_start) {
            apply_exact_delta(&mut page[slot_index].q_start, qty, add);
            apply_exact_delta(&mut page[slot_index].fee_start, fee_basis, add);
        } else {
            apply_exact_delta(&mut page[slot_index].q_end, qty, add);
            apply_exact_delta(&mut page[slot_index].fee_end, fee_basis, add);
        };
        let mut i = 0;
        while (i < PAGE_SLOTS) {
            let node = &mut page[i];
            let strike = min_strike + (page_index * PAGE_SLOTS + i) * tick_size;
            prefix_start = prefix_start + node.q_start;
            prefix_end = prefix_end + node.q_end;
            prefix_qk_start = prefix_qk_start + math::mul(node.q_start, strike);
            prefix_qk_end = prefix_qk_end + math::mul(node.q_end, strike);
            prefix_fee_start = prefix_fee_start + node.fee_start;
            prefix_fee_end = prefix_fee_end + node.fee_end;

            node.agg_q_start = prefix_start;
            node.agg_qk_start = prefix_qk_start;
            node.agg_q_end = prefix_end;
            node.agg_qk_end = prefix_qk_end;

            if (
                prefix_is_better(
                    prefix_start,
                    prefix_end,
                    summary.best_prefix_start,
                    summary.best_prefix_end,
                )
            ) {
                summary.best_prefix_start = prefix_start;
                summary.best_prefix_end = prefix_end;
            };

            if (
                prefix_is_lower(
                    prefix_fee_start,
                    prefix_fee_end,
                    summary.min_fee_prefix_start,
                    summary.min_fee_prefix_end,
                )
            ) {
                summary.min_fee_prefix_start = prefix_fee_start;
                summary.min_fee_prefix_end = prefix_fee_end;
            };

            i = i + 1;
        };

        summary.total_q_start = prefix_start;
        summary.total_q_end = prefix_end;
        summary.total_fee_start = prefix_fee_start;
        summary.total_fee_end = prefix_fee_end;
    };

    *(&mut matrix.page_tree[tree_index]) = summary;
}

/// Recover exact `(qty, qty * strike)` start/end boundary totals for one
/// live-curve segment `(start, end]`.
fun accumulate_segment_values(
    matrix: &StrikeMatrix,
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
        if (matrix.pages.contains(page_key)) {
            let page = &matrix.pages[page_key];
            let start_exclusive = if (page_key == start_page) {
                start_slot
            } else {
                max_u64()
            };
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

            if (start_exclusive != max_u64()) {
                let start_node = &page[start_exclusive];
                q_start_delta = q_start_delta - start_node.agg_q_start;
                qk_start_delta = qk_start_delta - start_node.agg_qk_start;
                q_end_delta = q_end_delta - start_node.agg_q_end;
                qk_end_delta = qk_end_delta - start_node.agg_qk_end;
            };
        };

        if (page_key == end_page) break;
        page_key = page_key + 1;
    };

    (q_start_delta, qk_start_delta, q_end_delta, qk_end_delta)
}

/// Rebuild all ancestors of one page-summary leaf up to the root.
fun recompute_page_tree_path(matrix: &mut StrikeMatrix, page_index: u64) {
    let mut tree_index = matrix.page_tree_leaf_count - 1 + page_index;
    while (tree_index > 0) {
        let parent_index = (tree_index - 1) / 2;
        let left_index = parent_index * 2 + 1;
        let right_index = left_index + 1;
        let left_summary = matrix.page_tree[left_index];
        let right_summary = matrix.page_tree[right_index];
        let summary = merge_page_summaries(&left_summary, &right_summary);
        *(&mut matrix.page_tree[parent_index]) = summary;
        tree_index = parent_index;
    };
}

fun empty_page(): vector<StrikeNode> {
    vector::tabulate!(
        PAGE_SLOTS,
        |_| StrikeNode {
            q_start: 0,
            q_end: 0,
            fee_start: 0,
            fee_end: 0,
            agg_q_start: 0,
            agg_qk_start: 0,
            agg_q_end: 0,
            agg_qk_end: 0,
        },
    )
}

fun empty_summary(): PageSummary {
    PageSummary {
        total_q_start: 0,
        total_q_end: 0,
        best_prefix_start: 0,
        best_prefix_end: 0,
        total_fee_start: 0,
        total_fee_end: 0,
        min_fee_prefix_start: 0,
        min_fee_prefix_end: 0,
    }
}

/// The inline page tree uses a complete binary-tree layout, so the leaf layer
/// is padded to a power of two and the extra leaves remain zero summaries.
fun next_pow_2(n: u64): u64 {
    let mut p = 1;
    while (p < n) {
        p = p * 2;
    };
    p
}

/// Interpolate the average price implied by the segment endpoints and the
/// average strike of the inventory inside that segment.
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

/// Compare two unsigned prefix pairs without materializing a signed difference.
fun prefix_is_better(
    candidate_start: u64,
    candidate_end: u64,
    best_start: u64,
    best_end: u64,
): bool {
    candidate_start + best_end >= candidate_end + best_start
}

/// Compare unsigned prefix pairs for the lower signed difference.
fun prefix_is_lower(
    candidate_start: u64,
    candidate_end: u64,
    best_start: u64,
    best_end: u64,
): bool {
    candidate_start + best_end <= candidate_end + best_start
}

/// Merge two page summaries into the summary for their concatenated strike range.
fun merge_page_summaries(left: &PageSummary, right: &PageSummary): PageSummary {
    let total_q_start = left.total_q_start + right.total_q_start;
    let total_q_end = left.total_q_end + right.total_q_end;
    let total_fee_start = left.total_fee_start + right.total_fee_start;
    let total_fee_end = left.total_fee_end + right.total_fee_end;

    let right_prefix_start = left.total_q_start + right.best_prefix_start;
    let right_prefix_end = left.total_q_end + right.best_prefix_end;
    let (best_prefix_start, best_prefix_end) = if (
        prefix_is_better(
            left.best_prefix_start,
            left.best_prefix_end,
            right_prefix_start,
            right_prefix_end,
        )
    ) {
        (left.best_prefix_start, left.best_prefix_end)
    } else {
        (right_prefix_start, right_prefix_end)
    };

    let right_fee_prefix_start = left.total_fee_start + right.min_fee_prefix_start;
    let right_fee_prefix_end = left.total_fee_end + right.min_fee_prefix_end;
    let (min_fee_prefix_start, min_fee_prefix_end) = if (
        prefix_is_lower(
            left.min_fee_prefix_start,
            left.min_fee_prefix_end,
            right_fee_prefix_start,
            right_fee_prefix_end,
        )
    ) {
        (left.min_fee_prefix_start, left.min_fee_prefix_end)
    } else {
        (right_fee_prefix_start, right_fee_prefix_end)
    };

    PageSummary {
        total_q_start,
        total_q_end,
        best_prefix_start,
        best_prefix_end,
        total_fee_start,
        total_fee_end,
        min_fee_prefix_start,
        min_fee_prefix_end,
    }
}

/// Map an aligned strike into its backing page and in-page slot.
fun strike_to_coords(self: &StrikeMatrix, strike: u64): (u64, u64) {
    assert!(strike >= self.min_strike && strike <= self.max_strike, EInvalidStrikeRange);
    assert!((strike - self.min_strike) % self.tick_size == 0, EUnalignedStrike);
    let tick_index = (strike - self.min_strike) / self.tick_size;
    let page_key = tick_index / PAGE_SLOTS;
    let slot = tick_index % PAGE_SLOTS;
    (page_key, slot)
}

/// Recover the aligned strike stored at a given page/slot coordinate.
fun strike_from_coords(self: &StrikeMatrix, page_key: u64, slot: u64): u64 {
    self.min_strike + (page_key * PAGE_SLOTS + slot) * self.tick_size
}
