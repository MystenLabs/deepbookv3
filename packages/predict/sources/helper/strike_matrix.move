// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// This module stores one oracle's exposure on a fixed strike grid.
//
// It serves two different queries:
// 1. MTM against a sampled live-price curve
// 2. exact worst-case settled payout (`max_payout`)
//
// MTM needs fast strike-range reads. For that, each page stores directional
// aggregates so a segment can recover exact `qty` and `qty * strike` without
// scanning every strike in the range.
//
// Exact `max_payout` is a different problem. For a settlement boundary `s`:
// - UP wins for strikes `< s`
// - DN wins for strikes `>= s`
//
// So:
//     payout(s) = sum_up_below(s) + sum_dn_at_or_above(s)
//               = total_q_dn + prefix_sum(q_up - q_dn)
//
// That means exact `max_payout` is the maximum prefix score over strikes in
// sorted order. A single total is not enough; after each update we need enough
// structure to recover the best prefix over the whole book.
//
// The layout is therefore hybrid:
// - `pages` is a `Table<u64, vector<StrikeNode>>`, with one dynamic-field lookup
//   per 512-strike page instead of one lookup per strike.
// - Each `StrikeNode` stores exact `q_up` / `q_dn` plus page-local aggregates
//   used by MTM range reads.
// - `page_tree` is an inline vector-backed tree of page summaries. Each summary
//   keeps:
//     * `total_q_up`
//     * `total_q_dn`
//     * the best prefix in that page/range, encoded as
//       `(best_prefix_up, best_prefix_dn)`
//
// The best prefix is stored as an unsigned pair instead of a signed scalar
// because Move has no native signed integers.
//
// Update algorithm:
// - rewrite the touched 512-slot page
// - recompute that page's summary
// - merge summaries up the inline tree
//
// Merge rule:
// - totals add componentwise
// - the best prefix of `left + right` is either:
//     * the best prefix entirely inside `left`, or
//     * all of `left` plus the best prefix of `right`
//
// After that path is rebuilt, the root summary is enough to answer:
//     max_payout = root.total_q_dn + root.best_prefix_up - root.best_prefix_dn
//
// So the design is intentionally asymmetric:
// - page-local aggregates optimize MTM
// - the inline summary tree optimizes exact `max_payout`
// - dynamic-field pressure stays bounded because only leaf pages live in `Table`

module deepbook_predict::strike_matrix;

use deepbook::{constants::max_u64, math};
use deepbook_predict::{constants, i64::{Self, I64}, oracle_config::CurvePoint};
use sui::table::{Self, Table};

const PAGE_SLOTS: u64 = 512;

const EInvalidTickSize: u64 = 0;
const EInvalidStrikeRange: u64 = 1;
const EUnalignedStrike: u64 = 5;
const EInsufficientQuantity: u64 = 2;
const ENonMonotoneCurve: u64 = 3;
const EInvalidCurveRange: u64 = 4;

// === Structs ===
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
    mtm: u64,
    /// Aggregate `$1`-per-unit cash obligation accumulated by range mints.
    /// Each range mint of a `(lower, higher)` band records `q_up[lower] += qty`,
    /// `q_dn[higher] += qty`, and `range_qty += qty`. Callers subtract `range_qty`
    /// from `evaluate(curve)`, `evaluate_settled(s)`, and `max_payout()` to
    /// recover the actual vault liability for ranges.
    range_qty: u64,
    /// Bernoulli-weighted signed inventory `Σ (q_up − q_dn) · √(p · (1 − p))`,
    /// updated on every insert/remove at the fair price of that leg. The
    /// inventory-aware mid shift reads this field to gauge directional risk.
    directional_aggregate: I64,
}

/// Exact per-strike inventory stored in dense page slots.
public struct StrikeNode has copy, drop, store {
    q_up: u64,
    q_dn: u64,
    agg_q_up: u64,
    agg_qk_up: u64,
    agg_q_dn: u64,
    agg_qk_dn: u64,
}

/// Aggregate summary for one page or one internal page-range node.
public struct PageSummary has copy, drop, store {
    total_q_up: u64,
    total_q_dn: u64,
    best_prefix_up: u64,
    best_prefix_dn: u64,
}

// === Public-Package Functions ===
/// Allocate all strike pages for the oracle grid and a zeroed page-summary tree.
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
    let page_count = (total_strikes - 1) / PAGE_SLOTS + 1;
    let page_tree_leaf_count = next_pow_2(page_count);
    let page_tree_len = 2 * page_tree_leaf_count - 1;

    let mut pages = table::new(ctx);
    let mut page_key = 0;
    while (page_key < page_count) {
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
        mtm: 0,
        range_qty: 0,
        directional_aggregate: i64::zero(),
    }
}

/// Insert a position at `strike` for `qty` units on the `is_up` side.
///
/// `weight` is the per-strike risk weight `n(d₂)` at the touched strike, in
/// FLOAT_SCALING. The caller is responsible for computing and passing it; the
/// matrix folds it into `directional_aggregate` so readers see the post-trade
/// inventory risk.
public(package) fun insert(
    matrix: &mut StrikeMatrix,
    strike: u64,
    qty: u64,
    is_up: bool,
    weight: u64,
) {
    apply_position(matrix, strike, qty, is_up, true);
    apply_aggregate_delta(matrix, qty, weight, is_up, true);
}

public(package) fun remove(
    matrix: &mut StrikeMatrix,
    strike: u64,
    qty: u64,
    is_up: bool,
    weight: u64,
) {
    apply_position(matrix, strike, qty, is_up, false);
    apply_aggregate_delta(matrix, qty, weight, is_up, false);
}

/// Insert a vertical range `(lower, higher)`. Equivalent to a long UP@lower,
/// a long DN@higher, and a `qty` increment to `range_qty`.
///
/// `lower_weight` and `higher_weight` are the per-strike risk weights `n(d₂)`
/// at the lower and higher strikes, used to fold the range's two legs into
/// `directional_aggregate`.
public(package) fun insert_range(
    matrix: &mut StrikeMatrix,
    lower: u64,
    higher: u64,
    qty: u64,
    lower_weight: u64,
    higher_weight: u64,
) {
    matrix.apply_range(lower, higher, qty, true);
    apply_aggregate_delta(matrix, qty, lower_weight, true, true);
    apply_aggregate_delta(matrix, qty, higher_weight, false, true);
}

/// Remove a vertical range `(lower, higher)`. Symmetric to `insert_range`.
public(package) fun remove_range(
    matrix: &mut StrikeMatrix,
    lower: u64,
    higher: u64,
    qty: u64,
    lower_weight: u64,
    higher_weight: u64,
) {
    matrix.apply_range(lower, higher, qty, false);
    apply_aggregate_delta(matrix, qty, lower_weight, true, false);
    apply_aggregate_delta(matrix, qty, higher_weight, false, false);
}

/// Evaluate the current book against a sampled live curve.
///
/// Each segment uses the page-local aggregates to recover:
/// - UP quantity in `(strike_i, strike_{i+1}]`
/// - DN quantity in `[strike_i, strike_{i+1})`
///
/// The first strike contributes its exact UP quantity, and the last strike
/// contributes its exact DN quantity, so the full minted range is covered once.
public(package) fun evaluate(matrix: &StrikeMatrix, curve: &vector<CurvePoint>): u64 {
    let len = curve.length();
    if (len == 0) return 0;
    assert!(
        curve[0].strike() <= matrix.minted_min_strike
        && curve[len - 1].strike() >= matrix.minted_max_strike,
        EInvalidCurveRange,
    );

    let mut value = 0;
    let (mut page_lo, mut slot_lo) = matrix.strike_to_coords(curve[0].strike());
    let (mut page_hi, mut slot_hi) = matrix.strike_to_coords(curve[len - 1].strike());

    let page = &matrix.pages[page_lo];
    value = value + math::mul(page[slot_lo].q_up, curve[0].up_price());
    let page = &matrix.pages[page_hi];
    value =
        value +
        math::mul(page[slot_hi].q_dn, constants::float_scaling!() - curve[len - 1].up_price());

    let mut ci = 1;
    while (ci < len) {
        let ci_strike = curve[ci].strike();
        let ci_strike_prev = curve[ci - 1].strike();
        let ci_up_price = curve[ci].up_price();
        let ci_dn_price = constants::float_scaling!() - curve[ci].up_price();
        let ci_up_price_prev = curve[ci - 1].up_price();
        let ci_dn_price_prev = constants::float_scaling!() - curve[ci - 1].up_price();
        (page_hi, slot_hi) = matrix.strike_to_coords(ci_strike);
        let (q_up_delta, qk_up_delta, q_dn_delta, qk_dn_delta) = matrix.accumulate_segment_qty_qk(
            page_lo,
            slot_lo,
            page_hi,
            slot_hi,
        );

        if (q_up_delta > 0) {
            assert!(ci_up_price_prev >= ci_up_price, ENonMonotoneCurve);
            let p_avg = interpolate_price_at_avg_strike(
                q_up_delta,
                qk_up_delta,
                ci_strike_prev,
                ci_strike,
                ci_up_price_prev,
                ci_up_price,
            );
            value = value + math::mul(q_up_delta, p_avg);
        };

        if (q_dn_delta > 0) {
            assert!(ci_dn_price >= ci_dn_price_prev, ENonMonotoneCurve);
            let p_dn_avg = interpolate_price_at_avg_strike(
                q_dn_delta,
                qk_dn_delta,
                ci_strike_prev,
                ci_strike,
                ci_dn_price_prev,
                ci_dn_price,
            );
            value = value + math::mul(q_dn_delta, p_dn_avg);
        };

        page_lo = page_hi;
        slot_lo = slot_hi;
        ci = ci + 1;
    };

    value
}

public(package) fun evaluate_settled(matrix: &StrikeMatrix, settlement: u64): u64 {
    if (matrix.minted_max_strike < matrix.minted_min_strike) return 0;

    let (min_page, min_slot) = matrix.strike_to_coords(matrix.minted_min_strike);
    let (max_page, max_slot) = matrix.strike_to_coords(matrix.minted_max_strike);
    let mut value = 0u64;
    let mut page_key = min_page;
    while (page_key <= max_page) {
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
                value = value + page[slot].q_up;
            } else {
                value = value + page[slot].q_dn;
            };

            slot = slot + 1;
        };

        page_key = page_key + 1;
    };

    value
}

public(package) fun max_payout(matrix: &StrikeMatrix): u64 {
    let root = matrix.page_tree[0];
    root.total_q_dn + root.best_prefix_up - root.best_prefix_dn
}

/// Aggregate `$1`-per-unit range quantity contributed by range mints.
public(package) fun range_qty(matrix: &StrikeMatrix): u64 {
    matrix.range_qty
}

/// Bernoulli-weighted signed inventory accumulated over all insert/remove
/// operations at their trade-time fair prices.
public(package) fun directional_aggregate(matrix: &StrikeMatrix): I64 {
    matrix.directional_aggregate
}

/// Cached mark-to-market value stored by the vault after oracle refresh.
public(package) fun mtm(matrix: &StrikeMatrix): u64 {
    matrix.mtm
}

/// Overwrite the cached mark-to-market value after recomputing it from a curve.
public(package) fun set_mtm(matrix: &mut StrikeMatrix, value: u64) {
    matrix.mtm = value;
}

/// Return the historical minted strike bounds, or `(0, 0)` for an untouched
/// book. These bounds only expand on insert and never contract on remove.
public(package) fun minted_strike_range(matrix: &StrikeMatrix): (u64, u64) {
    if (matrix.minted_min_strike > matrix.minted_max_strike) (0, 0) else (
        matrix.minted_min_strike,
        matrix.minted_max_strike,
    )
}

// === Private Functions ===
/// Apply a vertical range `(lower, higher)` as `long UP@lower + long DN@higher`
/// plus a `qty` range_qty delta. The matrix writes are byte-identical to two
/// separate longs; `range_qty` is the algebraic constant from the dominance
/// identity (`short X@k ≡ long ~X@k − $1`) that callers subtract from
/// `evaluate`/`evaluate_settled`/`max_payout` to recover the range payoff.
fun apply_range(matrix: &mut StrikeMatrix, lower: u64, higher: u64, qty: u64, add: bool) {
    matrix.apply_position(lower, qty, true, add);
    matrix.apply_position(higher, qty, false, add);
    apply_exact_delta(&mut matrix.range_qty, qty, add);
}

/// Fold one leg's risk-weighted quantity into the signed directional aggregate.
/// UP legs contribute positively, DN legs negatively; removes flip the sign so
/// that an insert+remove pair cancels exactly.
fun apply_aggregate_delta(
    matrix: &mut StrikeMatrix,
    qty: u64,
    weight: u64,
    is_up: bool,
    add: bool,
) {
    if (qty == 0 || weight == 0) return;
    let magnitude = math::mul(qty, weight);
    if (magnitude == 0) return;
    let is_negative = if (add) !is_up else is_up;
    let delta = i64::from_parts(magnitude, is_negative);
    matrix.directional_aggregate = i64::add(&matrix.directional_aggregate, &delta);
}

/// Apply one position delta, refresh the touched page summary, then rebuild the
/// ancestor path in the inline page tree.
fun apply_position(matrix: &mut StrikeMatrix, strike: u64, qty: u64, is_up: bool, add: bool) {
    let (page_index, slot) = matrix.strike_to_coords(strike);
    if (is_up) {
        apply_up_delta_and_recompute_page(matrix, page_index, slot, strike, qty, add);
    } else {
        apply_dn_delta_and_recompute_page(matrix, page_index, slot, strike, qty, add);
    };
    if (add) {
        matrix.minted_min_strike = matrix.minted_min_strike.min(strike);
        matrix.minted_max_strike = matrix.minted_max_strike.max(strike);
    };
    recompute_page_tree_path(matrix, page_index);
}

fun apply_delta(value: &mut u64, qty: u64, add: bool) {
    if (add) {
        *value = *value + qty;
    } else {
        *value = *value - qty;
    };
}

fun apply_exact_delta(value: &mut u64, qty: u64, add: bool) {
    if (!add) assert!(*value >= qty, EInsufficientQuantity);
    apply_delta(value, qty, add);
}

/// Update one UP strike and rebuild the touched page in a single left-to-right pass.
///
/// The UP cached aggregates are prefix-style, so every slot at or to the right
/// of `slot_index` must be updated. The same pass also recomputes the page's
/// best prefix for exact `max_payout`.
fun apply_up_delta_and_recompute_page(
    matrix: &mut StrikeMatrix,
    page_index: u64,
    slot_index: u64,
    strike: u64,
    qty: u64,
    add: bool,
) {
    let tree_index = matrix.page_tree_leaf_count - 1 + page_index;
    let delta_qk = math::mul(qty, strike);
    let mut summary = empty_summary();
    let mut prefix_up = 0;
    let mut prefix_dn = 0;

    {
        let page = matrix.pages.borrow_mut(page_index);
        apply_exact_delta(&mut page[slot_index].q_up, qty, add);
        let mut i = 0;
        while (i < PAGE_SLOTS) {
            let node = &mut page[i];
            // `agg_q_up` / `agg_qk_up` are prefix aggregates, so the delta
            // affects every slot on or after the edited strike.
            if (i >= slot_index) {
                apply_delta(&mut node.agg_q_up, qty, add);
                apply_delta(&mut node.agg_qk_up, delta_qk, add);
            };

            // Exact `max_payout` is a maximum prefix problem, so each page leaf
            // stores the best prefix seen during this left-to-right sweep.
            prefix_up = prefix_up + node.q_up;
            prefix_dn = prefix_dn + node.q_dn;
            if (
                prefix_is_better(
                    prefix_up,
                    prefix_dn,
                    summary.best_prefix_up,
                    summary.best_prefix_dn,
                )
            ) {
                summary.best_prefix_up = prefix_up;
                summary.best_prefix_dn = prefix_dn;
            };

            i = i + 1;
        };

        summary.total_q_up = page[PAGE_SLOTS - 1].agg_q_up;
        summary.total_q_dn = page[0].agg_q_dn;
    };

    *(&mut matrix.page_tree[tree_index]) = summary;
}

/// Update one DN strike and rebuild the touched page in a single left-to-right pass.
///
/// The DN cached aggregates are suffix-style, so every slot at or to the left
/// of `slot_index` must be updated. The page summary is rebuilt in the same pass.
fun apply_dn_delta_and_recompute_page(
    matrix: &mut StrikeMatrix,
    page_index: u64,
    slot_index: u64,
    strike: u64,
    qty: u64,
    add: bool,
) {
    let tree_index = matrix.page_tree_leaf_count - 1 + page_index;
    let delta_qk = math::mul(qty, strike);
    let mut summary = empty_summary();
    let mut prefix_up = 0;
    let mut prefix_dn = 0;

    {
        let page = matrix.pages.borrow_mut(page_index);
        apply_exact_delta(&mut page[slot_index].q_dn, qty, add);
        let mut i = 0;
        while (i < PAGE_SLOTS) {
            let node = &mut page[i];
            // `agg_q_dn` / `agg_qk_dn` are suffix aggregates, so the delta
            // affects every slot on or before the edited strike.
            if (i <= slot_index) {
                apply_delta(&mut node.agg_q_dn, qty, add);
                apply_delta(&mut node.agg_qk_dn, delta_qk, add);
            };

            prefix_up = prefix_up + node.q_up;
            prefix_dn = prefix_dn + node.q_dn;
            if (
                prefix_is_better(
                    prefix_up,
                    prefix_dn,
                    summary.best_prefix_up,
                    summary.best_prefix_dn,
                )
            ) {
                summary.best_prefix_up = prefix_up;
                summary.best_prefix_dn = prefix_dn;
            };

            i = i + 1;
        };

        summary.total_q_up = page[PAGE_SLOTS - 1].agg_q_up;
        summary.total_q_dn = page[0].agg_q_dn;
    };

    *(&mut matrix.page_tree[tree_index]) = summary;
}

/// Recover exact `(qty, qty * strike)` totals for one live-curve segment.
///
/// The returned range semantics match `evaluate()`:
/// - UP covers `(start, end]`
/// - DN covers `[start, end)`
fun accumulate_segment_qty_qk(
    matrix: &StrikeMatrix,
    start_page: u64,
    start_slot: u64,
    end_page: u64,
    end_slot: u64,
): (u64, u64, u64, u64) {
    let mut page_lo = start_page;
    let mut slot_lo = start_slot;
    let mut q_up_delta = 0;
    let mut qk_up_delta = 0;
    let mut q_up_chk = 0;
    let mut qk_up_chk = 0;
    let mut q_dn_delta = 0;
    let mut qk_dn_delta = 0;
    while (page_lo < end_page) {
        let page = &matrix.pages[page_lo];
        let start_node = &page[slot_lo];
        let end_node = &page[PAGE_SLOTS - 1];

        q_up_delta = q_up_delta + end_node.agg_q_up - start_node.agg_q_up + q_up_chk;
        qk_up_delta = qk_up_delta + end_node.agg_qk_up - start_node.agg_qk_up + qk_up_chk;

        let end_q_dn = page[PAGE_SLOTS - 1].q_dn;
        q_dn_delta = q_dn_delta + start_node.agg_q_dn - end_node.agg_q_dn + end_q_dn;
        qk_dn_delta =
            qk_dn_delta + start_node.agg_qk_dn - end_node.agg_qk_dn +
            math::mul(end_q_dn, matrix.strike_from_coords(page_lo, PAGE_SLOTS - 1));

        page_lo = page_lo + 1;
        slot_lo = 0;
        let next_page = &matrix.pages[page_lo];
        q_up_chk = next_page[slot_lo].q_up;
        qk_up_chk = math::mul(q_up_chk, matrix.strike_from_coords(page_lo, slot_lo));
    };

    let page = &matrix.pages[end_page];
    let start_node = &page[slot_lo];
    let end_node = &page[end_slot];

    q_up_delta = q_up_delta + end_node.agg_q_up - start_node.agg_q_up + q_up_chk;
    qk_up_delta = qk_up_delta + end_node.agg_qk_up - start_node.agg_qk_up + qk_up_chk;
    q_dn_delta = q_dn_delta + start_node.agg_q_dn - end_node.agg_q_dn;
    qk_dn_delta = qk_dn_delta + start_node.agg_qk_dn - end_node.agg_qk_dn;

    (q_up_delta, qk_up_delta, q_dn_delta, qk_dn_delta)
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
            q_up: 0,
            q_dn: 0,
            agg_q_up: 0,
            agg_qk_up: 0,
            agg_q_dn: 0,
            agg_qk_dn: 0,
        },
    )
}

fun empty_summary(): PageSummary {
    PageSummary {
        total_q_up: 0,
        total_q_dn: 0,
        best_prefix_up: 0,
        best_prefix_dn: 0,
    }
}

/// Return the smallest power of two that is at least `n`.
///
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
fun prefix_is_better(candidate_up: u64, candidate_dn: u64, best_up: u64, best_dn: u64): bool {
    candidate_up + best_dn >= candidate_dn + best_up
}

/// Merge two page summaries into the summary for their concatenated strike range.
fun merge_page_summaries(left: &PageSummary, right: &PageSummary): PageSummary {
    let total_q_up = left.total_q_up + right.total_q_up;
    let total_q_dn = left.total_q_dn + right.total_q_dn;

    let right_prefix_up = left.total_q_up + right.best_prefix_up;
    let right_prefix_dn = left.total_q_dn + right.best_prefix_dn;
    let (best_prefix_up, best_prefix_dn) = if (
        prefix_is_better(
            left.best_prefix_up,
            left.best_prefix_dn,
            right_prefix_up,
            right_prefix_dn,
        )
    ) {
        (left.best_prefix_up, left.best_prefix_dn)
    } else {
        (right_prefix_up, right_prefix_dn)
    };

    PageSummary {
        total_q_up,
        total_q_dn,
        best_prefix_up,
        best_prefix_dn,
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
