// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Sparse strike exposure index for payout-liability accounting.
///
/// The parent `StrikeExposure` owns the expiry `StrikeGrid`; callers must pass
/// that same grid into mutation APIs. The tree stores finite boundary strikes
/// directly and does not duplicate grid geometry in storage.
///
/// This treap stores finite interval boundaries touched by positions. It tracks
/// atomic payout terms: each order's exact terminal payout and maximum future
/// live payout. Live backing uses the static max-live term for an instant
/// conservative lookup. Settled liability uses exact terminal-payout prefixes.
module deepbook_predict::strike_payout_tree;

use deepbook_predict::{constants, strike_grid::StrikeGrid};
use sui::{bcs, hash::blake2b256, table::{Self, Table}};

const EInsufficientPayoutTerms: u64 = 2;
const EInvalidPayoutTerms: u64 = 5;

/// Sparse payout-liability tree for strike prefixes.
public struct StrikePayoutTree has store {
    root: Option<u64>,
    nodes: Table<u64, PayoutNode>,
    base: PayoutTerms,
}

/// Atomic payout terms used for boundary deltas and subtree totals.
public struct PayoutTerms has copy, drop, store {
    terminal_payout: u64,
    live_backing_payout: u64,
}

/// Subtree totals and max static live backing prefix gain.
public struct PayoutSummary has copy, drop, store {
    total_start: PayoutTerms,
    total_end: PayoutTerms,
    max_live_backing_prefix_gain: u64,
}

/// Treap node keyed by finite boundary strike.
public struct PayoutNode has copy, drop, store {
    priority: u64,
    left: Option<u64>,
    right: Option<u64>,
    /// This node's own boundary terms, stored so the subtree `summary` can be
    /// recomputed without deriving locals by subtracting child summaries.
    local_start: PayoutTerms,
    local_end: PayoutTerms,
    summary: PayoutSummary,
}

/// Return the static conservative live backing requirement.
public(package) fun max_live_backing_payout(tree: &StrikePayoutTree): u64 {
    let mut max_payout = tree.base.live_backing_payout;
    if (tree.root.is_some()) {
        max_payout =
            max_payout + tree.nodes[*tree.root.borrow()].summary.max_live_backing_prefix_gain;
    };
    max_payout
}

/// Evaluate exact settled payout liability at one settlement price.
public(package) fun settled_payout_liability(tree: &StrikePayoutTree, settlement: u64): u64 {
    let terms = settlement_prefix_terms(
        &tree.nodes,
        tree.root,
        settlement,
        tree.base,
    );
    terms.terminal_payout
}

/// Create an empty sparse payout tree for the oracle strike grid.
public(package) fun new(ctx: &mut TxContext): StrikePayoutTree {
    StrikePayoutTree {
        root: option::none(),
        nodes: table::new(ctx),
        base: payout_terms(0, 0),
    }
}

/// Insert interval payout terms for `(lower, higher]`.
public(package) fun insert_range(
    tree: &mut StrikePayoutTree,
    grid: &StrikeGrid,
    lower: u64,
    higher: u64,
    terminal_payout: u64,
    live_backing_payout: u64,
) {
    tree.apply_range(grid, lower, higher, payout_terms(terminal_payout, live_backing_payout), true);
}

/// Remove interval payout terms for `(lower, higher]`.
public(package) fun remove_range(
    tree: &mut StrikePayoutTree,
    grid: &StrikeGrid,
    lower: u64,
    higher: u64,
    terminal_payout: u64,
    live_backing_payout: u64,
) {
    tree.apply_range(
        grid,
        lower,
        higher,
        payout_terms(terminal_payout, live_backing_payout),
        false,
    );
}

/// Destroy all sparse payout storage without reading settlement liability.
public(package) fun destroy(tree: StrikePayoutTree) {
    let StrikePayoutTree {
        root,
        mut nodes,
        base: _,
    } = tree;
    destroy_nodes(&mut nodes, root);
    nodes.destroy_empty();
}

fun apply_range(
    tree: &mut StrikePayoutTree,
    grid: &StrikeGrid,
    lower: u64,
    higher: u64,
    terms: PayoutTerms,
    add: bool,
) {
    grid.assert_range_boundaries(lower, higher);
    if (terms.terminal_payout == 0 && terms.live_backing_payout == 0) return;
    assert!(terms.terminal_payout <= terms.live_backing_payout, EInvalidPayoutTerms);

    if (lower == constants::neg_inf!()) {
        apply_terms_delta(&mut tree.base, terms, add);
        tree.apply_boundary_delta(higher, terms, false, add);
    } else {
        tree.apply_boundary_delta(lower, terms, true, add);
        if (higher != constants::pos_inf!()) {
            tree.apply_boundary_delta(higher, terms, false, add);
        };
    };
}

fun apply_boundary_delta(
    tree: &mut StrikePayoutTree,
    strike: u64,
    terms: PayoutTerms,
    is_start: bool,
    add: bool,
) {
    let new_root = apply_at(
        &mut tree.nodes,
        tree.root,
        strike,
        terms,
        is_start,
        add,
    );
    tree.root = option::some(new_root);
}

fun apply_at(
    nodes: &mut Table<u64, PayoutNode>,
    root: Option<u64>,
    strike: u64,
    terms: PayoutTerms,
    is_start: bool,
    add: bool,
): u64 {
    if (root.is_none()) {
        assert!(add, EInsufficientPayoutTerms);
        let leaf = new_leaf(strike, terms, is_start);
        nodes.add(strike, leaf);
        return strike
    };

    let root_strike = *root.borrow();
    let mut node = nodes[root_strike];

    if (strike == root_strike) {
        if (is_start) {
            apply_terms_delta(&mut node.local_start, terms, add);
        } else {
            apply_terms_delta(&mut node.local_end, terms, add);
        };
        resummarize(nodes, root_strike, node);
        return root_strike
    };

    if (strike < root_strike) {
        let new_left = apply_at(
            nodes,
            node.left,
            strike,
            terms,
            is_start,
            add,
        );
        let left_node = nodes[new_left];
        if (left_node.priority > node.priority) {
            return rotate_right(nodes, root_strike, node, new_left, left_node)
        };
        node.left = option::some(new_left);
    } else {
        let new_right = apply_at(
            nodes,
            node.right,
            strike,
            terms,
            is_start,
            add,
        );
        let right_node = nodes[new_right];
        if (right_node.priority > node.priority) {
            return rotate_left(nodes, root_strike, node, new_right, right_node)
        };
        node.right = option::some(new_right);
    };

    resummarize(nodes, root_strike, node);
    root_strike
}

fun new_leaf(strike: u64, terms: PayoutTerms, is_start: bool): PayoutNode {
    let (start, end) = if (is_start) {
        (terms, payout_terms(0, 0))
    } else {
        (payout_terms(0, 0), terms)
    };

    PayoutNode {
        priority: strike_priority(strike),
        left: option::none(),
        right: option::none(),
        local_start: start,
        local_end: end,
        summary: boundary_summary(start, end),
    }
}

fun rotate_right(
    nodes: &mut Table<u64, PayoutNode>,
    root_strike: u64,
    mut root_node: PayoutNode,
    left_strike: u64,
    mut left_node: PayoutNode,
): u64 {
    // Write the demoted node first so the new parent re-summarizes against it.
    root_node.left = left_node.right;
    resummarize(nodes, root_strike, root_node);

    left_node.right = option::some(root_strike);
    resummarize(nodes, left_strike, left_node);
    left_strike
}

fun rotate_left(
    nodes: &mut Table<u64, PayoutNode>,
    root_strike: u64,
    mut root_node: PayoutNode,
    right_strike: u64,
    mut right_node: PayoutNode,
): u64 {
    // Write the demoted node first so the new parent re-summarizes against it.
    root_node.right = right_node.left;
    resummarize(nodes, root_strike, root_node);

    right_node.left = option::some(root_strike);
    resummarize(nodes, right_strike, right_node);
    right_strike
}

fun settlement_prefix_terms(
    nodes: &Table<u64, PayoutNode>,
    root: Option<u64>,
    settlement: u64,
    running: PayoutTerms,
): PayoutTerms {
    if (root.is_none()) return running;
    let strike = *root.borrow();
    let node = nodes[strike];
    if (settlement <= strike) {
        return settlement_prefix_terms(nodes, node.left, settlement, running)
    };

    let mut running = running;
    let left_summary = subtree_summary(nodes, node.left);
    apply_terms_delta(&mut running, left_summary.total_start, true);
    apply_terms_delta(&mut running, left_summary.total_end, false);
    apply_terms_delta(&mut running, node.local_start, true);
    apply_terms_delta(&mut running, node.local_end, false);
    settlement_prefix_terms(nodes, node.right, settlement, running)
}

fun resummarize(nodes: &mut Table<u64, PayoutNode>, strike: u64, mut node: PayoutNode) {
    let left = subtree_summary(nodes, node.left);
    let right = subtree_summary(nodes, node.right);
    let boundary = boundary_summary(node.local_start, node.local_end);
    node.summary = combine_summaries(combine_summaries(left, boundary), right);
    *nodes.borrow_mut(strike) = node;
}

fun subtree_summary(nodes: &Table<u64, PayoutNode>, root: Option<u64>): PayoutSummary {
    if (root.is_none()) return zero_summary();
    nodes[*root.borrow()].summary
}

fun boundary_summary(start: PayoutTerms, end: PayoutTerms): PayoutSummary {
    PayoutSummary {
        total_start: start,
        total_end: end,
        max_live_backing_prefix_gain: positive_live_delta(
            start.live_backing_payout,
            end.live_backing_payout,
            0,
        ),
    }
}

fun zero_summary(): PayoutSummary {
    PayoutSummary {
        total_start: payout_terms(0, 0),
        total_end: payout_terms(0, 0),
        max_live_backing_prefix_gain: 0,
    }
}

fun combine_summaries(left: PayoutSummary, right: PayoutSummary): PayoutSummary {
    let right_gain_after_left = positive_live_delta(
        left.total_start.live_backing_payout,
        left.total_end.live_backing_payout,
        right.max_live_backing_prefix_gain,
    );

    PayoutSummary {
        total_start: add_terms(left.total_start, right.total_start),
        total_end: add_terms(left.total_end, right.total_end),
        max_live_backing_prefix_gain: left.max_live_backing_prefix_gain.max(right_gain_after_left),
    }
}

fun positive_live_delta(start: u64, end: u64, gain: u64): u64 {
    let positive = start + gain;
    if (positive > end) positive - end else 0
}

fun add_terms(left: PayoutTerms, right: PayoutTerms): PayoutTerms {
    payout_terms(
        left.terminal_payout + right.terminal_payout,
        left.live_backing_payout + right.live_backing_payout,
    )
}

fun payout_terms(terminal_payout: u64, live_backing_payout: u64): PayoutTerms {
    PayoutTerms { terminal_payout, live_backing_payout }
}

fun destroy_nodes(nodes: &mut Table<u64, PayoutNode>, root: Option<u64>) {
    if (root.is_none()) return;
    let strike = *root.borrow();
    let node = nodes.remove(strike);
    destroy_nodes(nodes, node.left);
    destroy_nodes(nodes, node.right);
}

fun apply_terms_delta(value: &mut PayoutTerms, delta: PayoutTerms, add: bool) {
    if (add) {
        value.terminal_payout = value.terminal_payout + delta.terminal_payout;
        value.live_backing_payout = value.live_backing_payout + delta.live_backing_payout;
    } else {
        assert_terms_available(*value, delta);
        value.terminal_payout = value.terminal_payout - delta.terminal_payout;
        value.live_backing_payout = value.live_backing_payout - delta.live_backing_payout;
    };
}

fun assert_terms_available(available: PayoutTerms, required: PayoutTerms) {
    assert!(available.terminal_payout >= required.terminal_payout, EInsufficientPayoutTerms);
    assert!(
        available.live_backing_payout >= required.live_backing_payout,
        EInsufficientPayoutTerms,
    );
}

fun strike_priority(strike: u64): u64 {
    let bytes = bcs::to_bytes(&strike);
    let hash = blake2b256(&bytes);
    let mut out = 0;
    let mut i = 0;
    while (i < 8) {
        out = (out << 8) | (hash[i] as u64);
        i = i + 1;
    };
    out
}
