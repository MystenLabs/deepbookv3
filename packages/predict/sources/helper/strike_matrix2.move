// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook_predict::strike_matrix2;

use deepbook::{constants::max_u64, math};
use sui::table::{Self, Table};

const PAGE_SLOTS: u64 = 512;

const EInvalidTickSize: u64 = 0;
const EInvalidStrikeRange: u64 = 1;
const EInsufficientQuantity: u64 = 2;

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
    total_qk_up: u64,
    total_q_dn: u64,
    total_qk_dn: u64,
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
    let (page_index, slot) = validate_strike_coords(matrix, strike);
    apply_delta_and_recompute_page(matrix, page_index, slot, strike, qty, is_up, true);
    matrix.minted_min_strike = matrix.minted_min_strike.min(strike);
    matrix.minted_max_strike = matrix.minted_max_strike.max(strike);
    recompute_page_tree_path(matrix, page_index);
}

public(package) fun remove(matrix: &mut StrikeMatrix2, strike: u64, qty: u64, is_up: bool) {
    let (page_index, slot) = validate_strike_coords(matrix, strike);
    apply_delta_and_recompute_page(matrix, page_index, slot, strike, qty, is_up, false);
    recompute_page_tree_path(matrix, page_index);
}

public(package) fun max_payout(matrix: &StrikeMatrix2): u64 {
    let root = matrix.page_tree[0];
    root.total_q_dn + root.best_prefix_up - root.best_prefix_dn
}

fun validate_strike_coords(matrix: &StrikeMatrix2, strike: u64): (u64, u64) {
    assert!(strike >= matrix.min_strike && strike <= matrix.max_strike, EInvalidStrikeRange);
    assert!((strike - matrix.min_strike) % matrix.tick_size == 0, EInvalidStrikeRange);

    let tick_index = (strike - matrix.min_strike) / matrix.tick_size;
    let page_index = tick_index / PAGE_SLOTS;
    let slot = tick_index % PAGE_SLOTS;
    assert!(matrix.pages.contains(page_index), EInvalidStrikeRange);

    (page_index, slot)
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
    let min_strike = matrix.min_strike;
    let tick_size = matrix.tick_size;
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
                    if (add) {
                        node.q_up = node.q_up + qty;
                    } else {
                        assert!(node.q_up >= qty, EInsufficientQuantity);
                        node.q_up = node.q_up - qty;
                    };
                } else {
                    if (add) {
                        node.q_dn = node.q_dn + qty;
                    } else {
                        assert!(node.q_dn >= qty, EInsufficientQuantity);
                        node.q_dn = node.q_dn - qty;
                    };
                };
            };

            if (is_up && i >= slot_index) {
                if (add) {
                    node.agg_q_up = node.agg_q_up + qty;
                    node.agg_qk_up = node.agg_qk_up + delta_qk;
                } else {
                    node.agg_q_up = node.agg_q_up - qty;
                    node.agg_qk_up = node.agg_qk_up - delta_qk;
                };
            };

            if (!is_up && i <= slot_index) {
                if (add) {
                    node.agg_q_dn = node.agg_q_dn + qty;
                    node.agg_qk_dn = node.agg_qk_dn + delta_qk;
                } else {
                    node.agg_q_dn = node.agg_q_dn - qty;
                    node.agg_qk_dn = node.agg_qk_dn - delta_qk;
                };
            };

            let slot_strike = min_strike + (page_index * PAGE_SLOTS + i) * tick_size;
            summary.total_q_up = summary.total_q_up + node.q_up;
            summary.total_qk_up = summary.total_qk_up + math::mul(node.q_up, slot_strike);
            summary.total_q_dn = summary.total_q_dn + node.q_dn;
            summary.total_qk_dn = summary.total_qk_dn + math::mul(node.q_dn, slot_strike);

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
    };

    *(&mut matrix.page_tree[tree_index]) = summary;
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
    let empty = StrikeNode {
        q_up: 0,
        q_dn: 0,
        agg_q_up: 0,
        agg_qk_up: 0,
        agg_q_dn: 0,
        agg_qk_dn: 0,
    };
    vector::tabulate!(PAGE_SLOTS, |_| empty)
}

fun empty_summary(): PageSummary {
    PageSummary {
        total_q_up: 0,
        total_qk_up: 0,
        total_q_dn: 0,
        total_qk_dn: 0,
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

fun prefix_is_better(candidate_up: u64, candidate_dn: u64, best_up: u64, best_dn: u64): bool {
    candidate_up + best_dn >= candidate_dn + best_up
}

fun merge_page_summaries(left: &PageSummary, right: &PageSummary): PageSummary {
    let total_q_up = left.total_q_up + right.total_q_up;
    let total_qk_up = left.total_qk_up + right.total_qk_up;
    let total_q_dn = left.total_q_dn + right.total_q_dn;
    let total_qk_dn = left.total_qk_dn + right.total_qk_dn;

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
        total_qk_up,
        total_q_dn,
        total_qk_dn,
        best_prefix_up,
        best_prefix_dn,
    }
}
