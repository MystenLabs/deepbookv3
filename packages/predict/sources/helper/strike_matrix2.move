// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

// This module exists to balance three competing requirements:
// 1. MTM evaluation needs fast strike-range queries against a sampled curve.
//    That favors dense page-local aggregates so one segment can recover exact
//    `qty` and `qty * strike` without scanning every strike slot.
// 2. Exact max-payout needs a global prefix-maximum over `(q_up - q_dn)`.
//    That favors a tree of range summaries whose root can answer the query in
//    O(1) after each update.
// 3. Sui dynamic-field lookups are expensive when every tree node or every
//    strike is its own field. A fully pointer-based tree would make updates
//    and reads pay too many table borrows.
//
// The layout here is therefore hybrid:
// - `pages` stays in `Table`, but each entry owns a wide `vector` of 512
//   contiguous strikes. That keeps dynamic-field usage at one lookup per page
//   instead of one lookup per strike.
// - Each `StrikeNode` stores exact `q_up` / `q_dn` plus cached directional
//   aggregates. MTM uses those aggregates for the same fast segment reads as
//   the original dense strike matrix.
// - `page_tree` is an inline vector-backed tree over page summaries, not a
//   second dynamic-field structure. Updates rewrite one touched page in O(512)
//   and then bubble one summary path in O(log pages). `max_payout()` then
//   reads the root summary directly.
//
// The result is intentionally asymmetric:
// - MTM is optimized through dense page-local aggregate caches.
// - Max payout is optimized through the inline page-summary tree.
// - Dynamic-field pressure is minimized by keeping only the leaf pages in
//   `Table` and storing higher-level summaries inline.

module deepbook_predict::strike_matrix2;

use deepbook::{constants::max_u64, math};
use deepbook_predict::{constants, oracle_config::CurvePoint};
use sui::table::{Self, Table};

const PAGE_SLOTS: u64 = 512;

const EInvalidTickSize: u64 = 0;
const EInvalidStrikeRange: u64 = 1;
const EInsufficientQuantity: u64 = 2;
const ENonMonotoneCurve: u64 = 3;
const EInvalidCurveRange: u64 = 4;

/// Dense strike-indexed book with page-level summaries stored in an inline tree.
public struct StrikeMatrix2 has store {
    pages: Table<u64, vector<StrikeNode>>,
    page_tree: vector<PageSummary>,
    page_tree_leaf_count: u64,
    tick_size: u64,
    min_strike: u64,
    max_strike: u64,
    minted_min_strike: u64,
    minted_max_strike: u64,
    mtm: u64,
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

/// Allocate all strike pages for the oracle grid and a zeroed page-summary tree.
public(package) fun new(
    ctx: &mut TxContext,
    tick_size: u64,
    min_strike: u64,
    max_strike: u64,
): StrikeMatrix2 {
    assert!(tick_size > 0, EInvalidTickSize);
    assert!(
        min_strike <= max_strike
        && min_strike % tick_size == 0
        && max_strike % tick_size == 0,
        EInvalidStrikeRange,
    );

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

    StrikeMatrix2 {
        pages,
        page_tree,
        page_tree_leaf_count,
        tick_size,
        min_strike,
        max_strike,
        minted_min_strike: max_u64(),
        minted_max_strike: 0,
        mtm: 0,
    }
}

public(package) fun insert(matrix: &mut StrikeMatrix2, strike: u64, qty: u64, is_up: bool) {
    apply_position(matrix, strike, qty, is_up, true);
}

public(package) fun remove(matrix: &mut StrikeMatrix2, strike: u64, qty: u64, is_up: bool) {
    apply_position(matrix, strike, qty, is_up, false);
}

public(package) fun evaluate(matrix: &StrikeMatrix2, curve: &vector<CurvePoint>): u64 {
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

public(package) fun evaluate_settled(matrix: &StrikeMatrix2, settlement: u64): u64 {
    if (matrix.minted_max_strike < matrix.minted_min_strike) return 0;

    let (min_page, min_slot) = matrix.strike_to_coords(matrix.minted_min_strike);
    let (max_page, max_slot) = matrix.strike_to_coords(matrix.minted_max_strike);
    let mut value = 0u64;
    let mut page_key = min_page;
    while (true) {
        let page = &matrix.pages[page_key];
        let start_slot = if (page_key == min_page) { min_slot } else { 0 };
        let end_slot = if (page_key == max_page) {
            max_slot
        } else {
            PAGE_SLOTS - 1
        };
        let mut slot = start_slot;
        while (true) {
            let strike = matrix.strike_from_coords(page_key, slot);
            if (strike < settlement) {
                value = value + page[slot].q_up;
            } else {
                value = value + page[slot].q_dn;
            };

            if (slot == end_slot) break;
            slot = slot + 1;
        };

        if (page_key == max_page) break;
        page_key = page_key + 1;
    };

    value
}

public(package) fun max_payout(matrix: &StrikeMatrix2): u64 {
    let root = matrix.page_tree[0];
    root.total_q_dn + root.best_prefix_up - root.best_prefix_dn
}

public(package) fun mtm(matrix: &StrikeMatrix2): u64 {
    matrix.mtm
}

public(package) fun set_mtm(matrix: &mut StrikeMatrix2, value: u64) {
    matrix.mtm = value;
}

public(package) fun minted_strike_range(matrix: &StrikeMatrix2): (u64, u64) {
    if (matrix.minted_min_strike > matrix.minted_max_strike) (0, 0) else (
        matrix.minted_min_strike,
        matrix.minted_max_strike,
    )
}

fun apply_position(matrix: &mut StrikeMatrix2, strike: u64, qty: u64, is_up: bool, add: bool) {
    let (page_index, slot) = matrix.strike_to_coords(strike);
    apply_delta_and_recompute_page(matrix, page_index, slot, strike, qty, is_up, add);
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

fun apply_delta_and_recompute_page(
    matrix: &mut StrikeMatrix2,
    page_index: u64,
    slot_index: u64,
    strike: u64,
    qty: u64,
    is_up: bool,
    add: bool,
) {
    let tree_index = matrix.page_tree_leaf_count - 1 + page_index;
    let delta_qk = math::mul(qty, strike);
    let mut summary = empty_summary();
    let mut prefix_up = 0;
    let mut prefix_dn = 0;

    {
        let page = matrix.pages.borrow_mut(page_index);
        let mut i = 0;
        while (i < PAGE_SLOTS) {
            let node = &mut page[i];
            if (i == slot_index) {
                if (is_up) {
                    apply_exact_delta(&mut node.q_up, qty, add);
                } else {
                    apply_exact_delta(&mut node.q_dn, qty, add);
                };
            };

            if (is_up && i >= slot_index) {
                apply_delta(&mut node.agg_q_up, qty, add);
                apply_delta(&mut node.agg_qk_up, delta_qk, add);
            };

            if (!is_up && i <= slot_index) {
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

fun accumulate_segment_qty_qk(
    matrix: &StrikeMatrix2,
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

fun recompute_page_tree_path(matrix: &mut StrikeMatrix2, page_index: u64) {
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

fun next_pow_2(n: u64): u64 {
    let mut p = 1;
    while (p < n) {
        p = p * 2;
    };
    p
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

fun prefix_is_better(candidate_up: u64, candidate_dn: u64, best_up: u64, best_dn: u64): bool {
    candidate_up + best_dn >= candidate_dn + best_up
}

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

fun strike_to_coords(self: &StrikeMatrix2, strike: u64): (u64, u64) {
    assert!(strike >= self.min_strike && strike <= self.max_strike, EInvalidStrikeRange);
    assert!((strike - self.min_strike) % self.tick_size == 0, EInvalidStrikeRange);
    let tick_index = (strike - self.min_strike) / self.tick_size;
    let page_key = tick_index / PAGE_SLOTS;
    let slot = tick_index % PAGE_SLOTS;
    (page_key, slot)
}

fun strike_from_coords(self: &StrikeMatrix2, page_key: u64, slot: u64): u64 {
    self.min_strike + (page_key * PAGE_SLOTS + slot) * self.tick_size
}
