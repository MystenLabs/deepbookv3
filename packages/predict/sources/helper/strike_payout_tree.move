// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Sparse strike exposure index for settlement-oriented payout accounting.
///
/// This treap stores only finite interval boundaries touched by positions. It
/// returns exact max-payout updates and settled-liability queries without
/// storing NAV-specific strike-weighted quantities.
module deepbook_predict::strike_payout_tree;

use deepbook_predict::constants;
use sui::{bcs, hash::blake2b256, table::{Self, Table}};

const EInvalidTickSize: u64 = 0;
const EInvalidStrikeRange: u64 = 1;
const EInsufficientQuantity: u64 = 2;
const EUnalignedStrike: u64 = 5;
const EZeroQuantity: u64 = 6;
const ETooManyStrikes: u64 = 7;

/// Sparse settlement-oriented tree for payout prefixes.
public struct StrikePayoutTree has store {
    root: Option<u64>,
    nodes: Table<u64, PayoutNode>,
    tick_size: u64,
    min_strike: u64,
    max_strike: u64,
    base_qty: u64,
}

/// Treap node keyed by finite boundary strike.
public struct PayoutNode has copy, drop, store {
    priority: u64,
    left: Option<u64>,
    right: Option<u64>,
    q_start: u64,
    q_end: u64,
    summary: PayoutSummary,
}

/// Subtree aggregate stored on each payout tree node.
public struct PayoutSummary has copy, drop, store {
    total_q_start: u64,
    total_q_end: u64,
    best_prefix_start: u64,
    best_prefix_end: u64,
}

/// Create an empty sparse payout tree for the oracle strike grid.
public(package) fun new(
    tick_size: u64,
    min_strike: u64,
    max_strike: u64,
    ctx: &mut TxContext,
): StrikePayoutTree {
    assert_valid_grid(tick_size, min_strike, max_strike);

    StrikePayoutTree {
        root: option::none(),
        nodes: table::new(ctx),
        tick_size,
        min_strike,
        max_strike,
        base_qty: 0,
    }
}

/// Insert interval quantity for `(lower, higher]` and return new max payout.
public(package) fun insert_range(
    tree: &mut StrikePayoutTree,
    lower: u64,
    higher: u64,
    qty: u64,
): u64 {
    tree.apply_range(lower, higher, qty, true)
}

/// Remove interval quantity for `(lower, higher]` and return new max payout.
public(package) fun remove_range(
    tree: &mut StrikePayoutTree,
    lower: u64,
    higher: u64,
    qty: u64,
): u64 {
    tree.apply_range(lower, higher, qty, false)
}

/// Evaluate settled payout liability.
public(package) fun settled_value(tree: &StrikePayoutTree, settlement: u64): u64 {
    let (prefix_q_start, prefix_q_end) = prefix_before(&tree.nodes, tree.root, settlement);
    tree.base_qty + prefix_q_start - prefix_q_end
}

/// Destroy all sparse payout storage without reading settlement liability.
public(package) fun destroy(tree: StrikePayoutTree) {
    let StrikePayoutTree {
        root,
        mut nodes,
        tick_size: _,
        min_strike: _,
        max_strike: _,
        base_qty: _,
    } = tree;
    destroy_nodes(&mut nodes, root);
    nodes.destroy_empty();
}

fun apply_range(tree: &mut StrikePayoutTree, lower: u64, higher: u64, qty: u64, add: bool): u64 {
    tree.assert_can_apply_range(lower, higher, qty, add);

    let root_summary = if (lower == constants::neg_inf!()) {
        apply_exact_delta(&mut tree.base_qty, qty, add);
        tree.apply_boundary_delta(higher, qty, false, add)
    } else {
        let mut summary = tree.apply_boundary_delta(lower, qty, true, add);
        if (higher != constants::pos_inf!()) {
            summary = tree.apply_boundary_delta(higher, qty, false, add);
        };
        summary
    };

    tree.base_qty + root_summary.best_prefix_start - root_summary.best_prefix_end
}

fun assert_can_apply_range(tree: &StrikePayoutTree, lower: u64, higher: u64, qty: u64, add: bool) {
    assert_range_shape(lower, higher, qty);

    if (lower == constants::neg_inf!()) {
        if (!add) {
            assert!(tree.base_qty >= qty, EInsufficientQuantity);
        };
    } else {
        tree.assert_boundary_update_allowed(lower, qty, true, add);
    };

    if (higher != constants::pos_inf!()) {
        tree.assert_boundary_update_allowed(higher, qty, false, add);
    };
}

fun assert_boundary_update_allowed(
    tree: &StrikePayoutTree,
    strike: u64,
    qty: u64,
    is_start: bool,
    add: bool,
) {
    assert!(strike >= tree.min_strike && strike <= tree.max_strike, EInvalidStrikeRange);
    assert!((strike - tree.min_strike) % tree.tick_size == 0, EUnalignedStrike);

    if (!add) {
        assert!(tree.nodes.contains(strike), EInsufficientQuantity);
        let node = tree.nodes[strike];
        let available_qty = if (is_start) { node.q_start } else { node.q_end };
        assert!(available_qty >= qty, EInsufficientQuantity);
    };
}

fun apply_boundary_delta(
    tree: &mut StrikePayoutTree,
    strike: u64,
    qty: u64,
    is_start: bool,
    add: bool,
): PayoutSummary {
    let (new_root, root_node) = apply_at(&mut tree.nodes, tree.root, strike, qty, is_start, add);
    tree.root = option::some(new_root);
    root_node.summary
}

fun apply_at(
    nodes: &mut Table<u64, PayoutNode>,
    root: Option<u64>,
    strike: u64,
    qty: u64,
    is_start: bool,
    add: bool,
): (u64, PayoutNode) {
    if (root.is_none()) {
        assert!(add, EInsufficientQuantity);
        let leaf = new_leaf(strike, qty, is_start);
        nodes.add(strike, leaf);
        return (strike, leaf)
    };

    let root_strike = *root.borrow();
    let mut node = nodes[root_strike];
    if (strike == root_strike) {
        if (is_start) {
            apply_exact_delta(&mut node.q_start, qty, add);
        } else {
            apply_exact_delta(&mut node.q_end, qty, add);
        };
        recompute_node_value(nodes, &mut node, false, false, empty_summary());
        write_node(nodes, root_strike, node);
        return (root_strike, node)
    };

    if (strike < root_strike) {
        let (new_left, left_node) = apply_at(
            nodes,
            node.left,
            strike,
            qty,
            is_start,
            add,
        );
        if (left_node.priority > node.priority) {
            return rotate_right(nodes, root_strike, node, new_left, left_node)
        };
        node.left = option::some(new_left);
        let left_summary = left_node.summary;
        recompute_node_value(nodes, &mut node, true, false, left_summary);
    } else {
        let (new_right, right_node) = apply_at(
            nodes,
            node.right,
            strike,
            qty,
            is_start,
            add,
        );
        if (right_node.priority > node.priority) {
            return rotate_left(nodes, root_strike, node, new_right, right_node)
        };
        node.right = option::some(new_right);
        let right_summary = right_node.summary;
        recompute_node_value(nodes, &mut node, false, true, right_summary);
    };

    write_node(nodes, root_strike, node);
    (root_strike, node)
}

fun new_leaf(strike: u64, qty: u64, is_start: bool): PayoutNode {
    let (q_start, q_end) = if (is_start) { (qty, 0) } else { (0, qty) };
    let summary = local_summary(q_start, q_end);

    PayoutNode {
        priority: strike_priority(strike),
        left: option::none(),
        right: option::none(),
        q_start,
        q_end,
        summary,
    }
}

fun recompute_node_value(
    nodes: &Table<u64, PayoutNode>,
    node: &mut PayoutNode,
    changed_left: bool,
    changed_right: bool,
    changed_summary: PayoutSummary,
): PayoutSummary {
    let mut summary = local_summary(node.q_start, node.q_end);
    if (node.left.is_some()) {
        let left_summary = if (changed_left) {
            changed_summary
        } else {
            nodes[*node.left.borrow()].summary
        };
        summary = merge_summary_values(left_summary, summary);
    };
    if (node.right.is_some()) {
        let right_summary = if (changed_right) {
            changed_summary
        } else {
            nodes[*node.right.borrow()].summary
        };
        summary = merge_summary_values(summary, right_summary);
    };

    node.summary = summary;
    summary
}

fun rotate_right(
    nodes: &mut Table<u64, PayoutNode>,
    root_strike: u64,
    mut root_node: PayoutNode,
    left_strike: u64,
    mut left_node: PayoutNode,
): (u64, PayoutNode) {
    root_node.left = left_node.right;
    let root_summary = recompute_node_value(
        nodes,
        &mut root_node,
        false,
        false,
        empty_summary(),
    );
    write_node(nodes, root_strike, root_node);

    left_node.right = option::some(root_strike);
    recompute_node_value(nodes, &mut left_node, false, true, root_summary);
    write_node(nodes, left_strike, left_node);
    (left_strike, left_node)
}

fun rotate_left(
    nodes: &mut Table<u64, PayoutNode>,
    root_strike: u64,
    mut root_node: PayoutNode,
    right_strike: u64,
    mut right_node: PayoutNode,
): (u64, PayoutNode) {
    root_node.right = right_node.left;
    let root_summary = recompute_node_value(
        nodes,
        &mut root_node,
        false,
        false,
        empty_summary(),
    );
    write_node(nodes, root_strike, root_node);

    right_node.left = option::some(root_strike);
    recompute_node_value(nodes, &mut right_node, true, false, root_summary);
    write_node(nodes, right_strike, right_node);
    (right_strike, right_node)
}

fun prefix_before(nodes: &Table<u64, PayoutNode>, root: Option<u64>, settlement: u64): (u64, u64) {
    let mut q_start = 0;
    let mut q_end = 0;
    let mut cursor = root;

    while (cursor.is_some()) {
        let strike = *cursor.borrow();
        let node = nodes[strike];

        if (settlement <= strike) {
            cursor = node.left;
        } else {
            if (node.left.is_some()) {
                let left = nodes[*node.left.borrow()];
                q_start = q_start + left.summary.total_q_start;
                q_end = q_end + left.summary.total_q_end;
            };

            q_start = q_start + node.q_start;
            q_end = q_end + node.q_end;

            cursor = node.right;
        };
    };

    (q_start, q_end)
}

fun write_node(nodes: &mut Table<u64, PayoutNode>, strike: u64, node: PayoutNode) {
    *(&mut nodes[strike]) = node;
}

fun empty_summary(): PayoutSummary {
    PayoutSummary {
        total_q_start: 0,
        total_q_end: 0,
        best_prefix_start: 0,
        best_prefix_end: 0,
    }
}

fun local_summary(q_start: u64, q_end: u64): PayoutSummary {
    let (best_prefix_start, best_prefix_end) = if (q_start >= q_end) {
        (q_start, q_end)
    } else {
        (0, 0)
    };

    PayoutSummary {
        total_q_start: q_start,
        total_q_end: q_end,
        best_prefix_start,
        best_prefix_end,
    }
}

fun merge_summary_values(left: PayoutSummary, right: PayoutSummary): PayoutSummary {
    let total_q_start = left.total_q_start + right.total_q_start;
    let total_q_end = left.total_q_end + right.total_q_end;

    let right_prefix_start = left.total_q_start + right.best_prefix_start;
    let right_prefix_end = left.total_q_end + right.best_prefix_end;
    let (best_prefix_start, best_prefix_end) = if (
        left.best_prefix_start + right_prefix_end >= left.best_prefix_end + right_prefix_start
    ) {
        (left.best_prefix_start, left.best_prefix_end)
    } else {
        (right_prefix_start, right_prefix_end)
    };

    PayoutSummary {
        total_q_start,
        total_q_end,
        best_prefix_start,
        best_prefix_end,
    }
}

fun destroy_nodes(nodes: &mut Table<u64, PayoutNode>, root: Option<u64>) {
    if (root.is_none()) return;
    let strike = *root.borrow();
    let node = nodes.remove(strike);
    destroy_nodes(nodes, node.left);
    destroy_nodes(nodes, node.right);
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

fun apply_exact_delta(value: &mut u64, amount: u64, add: bool) {
    if (add) {
        *value = *value + amount;
    } else {
        assert!(*value >= amount, EInsufficientQuantity);
        *value = *value - amount;
    };
}

fun strike_priority(strike: u64): u64 {
    let hash = blake2b256(&bcs::to_bytes(&strike));
    let mut value = 0u64;
    let mut i = 0;
    while (i < 8) {
        value = (value << 8) | (hash[i] as u64);
        i = i + 1;
    };
    value
}
