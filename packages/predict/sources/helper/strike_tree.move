// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Sparse treap-backed exposure store for one oracle.
///
/// This module mirrors the `strike_matrix` package API, but stores only finite
/// interval boundary strikes that have been touched. It keeps subtree summaries
/// for live valuation, exact max-payout calculation, and conservative
/// settlement-loss rebate valuation. Removed nodes are left as structural
/// tombstones; their local quantities and fees become zero, and active subtree
/// bounds are derived only from nonzero inventory.
module deepbook_predict::strike_tree;

use deepbook::{constants::max_u64, math};
use deepbook_predict::{constants, pricing::CurvePoint};
use sui::{bcs, hash::blake2b256, table::{Self, Table}};

const EInvalidTickSize: u64 = 0;
const EInvalidStrikeRange: u64 = 1;
const EInsufficientQuantity: u64 = 2;
const EInvalidCurveRange: u64 = 4;
const EUnalignedStrike: u64 = 5;
const EZeroQuantity: u64 = 6;
const ETooManyStrikes: u64 = 7;

/// Sparse interval-boundary book with treap balancing and cached root liability.
public struct StrikeTree has store {
    root: Option<u64>,
    nodes: Table<u64, TreeNode>,
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

/// Internal treap node keyed by finite boundary strike.
public struct TreeNode has copy, drop, store {
    priority: u64,
    left: Option<u64>,
    right: Option<u64>,
    q_start: u64,
    q_end: u64,
    fee_start: u64,
    fee_end: u64,
    total_q_start: u64,
    total_q_end: u64,
    total_qk_start: u64,
    total_qk_end: u64,
    total_fee_start: u64,
    total_fee_end: u64,
    best_prefix_start: u64,
    best_prefix_end: u64,
    min_fee_prefix_start: u64,
    min_fee_prefix_end: u64,
    sub_min: u64,
    sub_max: u64,
}

/// Cached aggregate for a subtree while recomputing treap nodes.
public struct NodeSummary has copy, drop {
    total_q_start: u64,
    total_q_end: u64,
    total_qk_start: u64,
    total_qk_end: u64,
    total_fee_start: u64,
    total_fee_end: u64,
    best_prefix_start: u64,
    best_prefix_end: u64,
    min_fee_prefix_start: u64,
    min_fee_prefix_end: u64,
    sub_min: u64,
    sub_max: u64,
}

// === Public-Package Functions ===

/// Create an empty sparse tree for the oracle strike grid.
public(package) fun new(
    ctx: &mut TxContext,
    tick_size: u64,
    min_strike: u64,
    max_strike: u64,
): StrikeTree {
    assert!(tick_size > 0, EInvalidTickSize);
    assert!(min_strike <= max_strike, EInvalidStrikeRange);
    assert!(min_strike % tick_size == 0 && max_strike % tick_size == 0, EUnalignedStrike);

    let total_strikes = (max_strike - min_strike) / tick_size + 1;
    assert!(total_strikes <= constants::oracle_strike_grid_ticks!() + 1, ETooManyStrikes);

    StrikeTree {
        root: option::none(),
        nodes: table::new(ctx),
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
    tree: &mut StrikeTree,
    lower: u64,
    higher: u64,
    qty: u64,
    fee_basis: u64,
) {
    tree.apply_range(lower, higher, qty, fee_basis, true);
}

/// Remove interval quantity for `(lower, higher]`.
public(package) fun remove_range(
    tree: &mut StrikeTree,
    lower: u64,
    higher: u64,
    qty: u64,
    fee_basis: u64,
) {
    tree.apply_range(lower, higher, qty, fee_basis, false);
}

/// Return the exact worst-case settled payout across all settlement prices.
public(package) fun max_payout(tree: &StrikeTree): u64 {
    tree.max_payout
}

/// Evaluate live option value and conservative maximum losing fee basis.
public(package) fun live_values(tree: &StrikeTree, curve: &vector<CurvePoint>): (u64, u64) {
    let option_value = tree.evaluate(curve);
    let (min_fee_start, min_fee_end) = if (tree.root.is_some()) {
        let root = tree.nodes[*tree.root.borrow()];
        (root.min_fee_prefix_start, root.min_fee_prefix_end)
    } else {
        (0, 0)
    };
    let min_winning_fee_basis = tree.base_fee_basis + min_fee_start - min_fee_end;
    let conservative_losing_fee_basis = tree.total_fee_basis - min_winning_fee_basis;
    (option_value, conservative_losing_fee_basis)
}

/// Evaluate settled liability and exact losing fee basis.
public(package) fun settled_values(tree: &StrikeTree, settlement: u64): (u64, u64) {
    let (prefix_q_start, prefix_q_end, prefix_fee_start, prefix_fee_end) = prefix_before(
        &tree.nodes,
        tree.root,
        settlement,
    );
    let settled_liability = tree.base_qty + prefix_q_start - prefix_q_end;
    let winning_fee_basis = tree.base_fee_basis + prefix_fee_start - prefix_fee_end;
    (settled_liability, tree.total_fee_basis - winning_fee_basis)
}

/// Return the strike grid this tree was created with.
public(package) fun strike_grid(tree: &StrikeTree): (u64, u64, u64) {
    (tree.min_strike, tree.tick_size, tree.max_strike)
}

/// Return the historical minted strike bounds, or `(0, 0)` for an untouched
/// book. These bounds only expand on insert and never contract on remove.
public(package) fun minted_strike_range(tree: &StrikeTree): (u64, u64) {
    if (tree.minted_min_strike > tree.minted_max_strike) (0, 0) else (
        tree.minted_min_strike,
        tree.minted_max_strike,
    )
}

/// Consume a sparse tree after settlement and return exact settled liability.
public(package) fun into_settled_liability(tree: StrikeTree, settlement: u64): u64 {
    let (settled_liability, _) = tree.settled_values(settlement);
    let StrikeTree {
        root,
        mut nodes,
        tick_size: _,
        min_strike: _,
        max_strike: _,
        minted_min_strike: _,
        minted_max_strike: _,
        max_payout: _,
        total_fee_basis: _,
        base_qty: _,
        base_fee_basis: _,
    } = tree;

    destroy_nodes(&mut nodes, root);
    nodes.destroy_empty();
    settled_liability
}

// === Private Functions ===

/// Evaluate the current interval book against a sampled live curve.
fun evaluate(tree: &StrikeTree, curve: &vector<CurvePoint>): u64 {
    let len = curve.length();
    if (len == 0) return 0;

    let mut start_value = 0;
    let mut end_value = 0;
    if (tree.root.is_some()) {
        let root = tree.nodes[*tree.root.borrow()];
        if (root.total_q_start > 0 || root.total_q_end > 0) {
            assert!(
                curve[0].strike() <= root.sub_min && curve[len - 1].strike() >= root.sub_max,
                EInvalidCurveRange,
            );
            let (starts, ends, _) = eval_inorder(&tree.nodes, *tree.root.borrow(), curve, 0);
            start_value = starts;
            end_value = ends;
        };
    };

    math::mul(tree.base_qty, constants::float_scaling!()) + start_value - end_value
}

/// Apply interval quantity as start/end boundary deltas.
fun apply_range(
    tree: &mut StrikeTree,
    lower: u64,
    higher: u64,
    qty: u64,
    fee_basis: u64,
    add: bool,
) {
    tree.assert_can_apply_range(lower, higher, qty, fee_basis, add);

    apply_exact_delta(&mut tree.total_fee_basis, fee_basis, add);
    let mut root_summary = empty_summary();
    let mut touched_boundary = false;

    if (lower == constants::neg_inf!()) {
        apply_exact_delta(&mut tree.base_qty, qty, add);
        apply_exact_delta(&mut tree.base_fee_basis, fee_basis, add);
    } else {
        root_summary = tree.apply_boundary_delta(lower, qty, fee_basis, true, add);
        touched_boundary = true;
    };

    if (higher != constants::pos_inf!()) {
        root_summary = tree.apply_boundary_delta(higher, qty, fee_basis, false, add);
        touched_boundary = true;
    };

    tree.max_payout = if (touched_boundary) {
        tree.base_qty + root_summary.best_prefix_start - root_summary.best_prefix_end
    } else {
        tree.base_qty
    };
}

fun assert_can_apply_range(
    tree: &StrikeTree,
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
    if (!add) assert!(tree.total_fee_basis >= fee_basis, EInsufficientQuantity);

    if (lower == constants::neg_inf!()) {
        if (!add) {
            assert!(tree.base_qty >= qty, EInsufficientQuantity);
            assert!(tree.base_fee_basis >= fee_basis, EInsufficientQuantity);
        };
    } else {
        tree.assert_boundary_update_allowed(lower, qty, fee_basis, true, add);
    };

    if (higher != constants::pos_inf!()) {
        tree.assert_boundary_update_allowed(higher, qty, fee_basis, false, add);
    };
}

fun assert_boundary_update_allowed(
    tree: &StrikeTree,
    strike: u64,
    qty: u64,
    fee_basis: u64,
    is_start: bool,
    add: bool,
) {
    tree.assert_finite_strike(strike);
    if (!add) {
        assert!(tree.nodes.contains(strike), EInsufficientQuantity);
        let node = tree.nodes[strike];
        let available_qty = if (is_start) { node.q_start } else { node.q_end };
        let available_fee_basis = if (is_start) { node.fee_start } else { node.fee_end };
        assert!(available_qty >= qty, EInsufficientQuantity);
        assert!(available_fee_basis >= fee_basis, EInsufficientQuantity);
    };
}

fun assert_finite_strike(tree: &StrikeTree, strike: u64) {
    assert!(strike >= tree.min_strike && strike <= tree.max_strike, EInvalidStrikeRange);
    assert!((strike - tree.min_strike) % tree.tick_size == 0, EUnalignedStrike);
}

fun apply_boundary_delta(
    tree: &mut StrikeTree,
    strike: u64,
    qty: u64,
    fee_basis: u64,
    is_start: bool,
    add: bool,
): NodeSummary {
    let (new_root, root_node) = apply_at(
        &mut tree.nodes,
        tree.root,
        strike,
        qty,
        fee_basis,
        is_start,
        add,
    );
    tree.root = option::some(new_root);
    if (add) {
        tree.minted_min_strike = tree.minted_min_strike.min(strike);
        tree.minted_max_strike = tree.minted_max_strike.max(strike);
    };
    node_summary(&root_node)
}

fun apply_at(
    nodes: &mut Table<u64, TreeNode>,
    root: Option<u64>,
    strike: u64,
    qty: u64,
    fee_basis: u64,
    is_start: bool,
    add: bool,
): (u64, TreeNode) {
    if (root.is_none()) {
        assert!(add, EInsufficientQuantity);
        let leaf = new_leaf(strike, qty, fee_basis, is_start);
        nodes.add(strike, leaf);
        return (strike, leaf)
    };

    let root_strike = *root.borrow();
    let mut node = nodes[root_strike];
    if (strike == root_strike) {
        if (is_start) {
            apply_exact_delta(&mut node.q_start, qty, add);
            apply_exact_delta(&mut node.fee_start, fee_basis, add);
        } else {
            apply_exact_delta(&mut node.q_end, qty, add);
            apply_exact_delta(&mut node.fee_end, fee_basis, add);
        };
        recompute_node_value(nodes, root_strike, &mut node, false, false, empty_summary());
        write_node(nodes, root_strike, node);
        return (root_strike, node)
    };

    if (strike < root_strike) {
        let (new_left, left_node) = apply_at(
            nodes,
            node.left,
            strike,
            qty,
            fee_basis,
            is_start,
            add,
        );
        if (left_node.priority > node.priority) {
            return rotate_right(nodes, root_strike, node, new_left, left_node)
        };
        node.left = option::some(new_left);
        let left_summary = node_summary(&left_node);
        recompute_node_value(nodes, root_strike, &mut node, true, false, left_summary);
    } else {
        let (new_right, right_node) = apply_at(
            nodes,
            node.right,
            strike,
            qty,
            fee_basis,
            is_start,
            add,
        );
        if (right_node.priority > node.priority) {
            return rotate_left(nodes, root_strike, node, new_right, right_node)
        };
        node.right = option::some(new_right);
        let right_summary = node_summary(&right_node);
        recompute_node_value(nodes, root_strike, &mut node, false, true, right_summary);
    };

    write_node(nodes, root_strike, node);
    (root_strike, node)
}

fun apply_exact_delta(value: &mut u64, amount: u64, add: bool) {
    if (add) {
        *value = *value + amount;
    } else {
        assert!(*value >= amount, EInsufficientQuantity);
        *value = *value - amount;
    };
}

fun new_leaf(strike: u64, qty: u64, fee_basis: u64, is_start: bool): TreeNode {
    let (q_start, q_end) = if (is_start) { (qty, 0) } else { (0, qty) };
    let (fee_start, fee_end) = if (is_start) { (fee_basis, 0) } else { (0, fee_basis) };
    let summary = local_summary(strike, q_start, q_end, fee_start, fee_end);

    TreeNode {
        priority: strike_priority(strike),
        left: option::none(),
        right: option::none(),
        q_start,
        q_end,
        fee_start,
        fee_end,
        total_q_start: summary.total_q_start,
        total_q_end: summary.total_q_end,
        total_qk_start: summary.total_qk_start,
        total_qk_end: summary.total_qk_end,
        total_fee_start: summary.total_fee_start,
        total_fee_end: summary.total_fee_end,
        best_prefix_start: summary.best_prefix_start,
        best_prefix_end: summary.best_prefix_end,
        min_fee_prefix_start: summary.min_fee_prefix_start,
        min_fee_prefix_end: summary.min_fee_prefix_end,
        sub_min: summary.sub_min,
        sub_max: summary.sub_max,
    }
}

fun write_node(nodes: &mut Table<u64, TreeNode>, strike: u64, node: TreeNode) {
    *(&mut nodes[strike]) = node;
}

fun write_summary(node: &mut TreeNode, summary: NodeSummary) {
    node.total_q_start = summary.total_q_start;
    node.total_q_end = summary.total_q_end;
    node.total_qk_start = summary.total_qk_start;
    node.total_qk_end = summary.total_qk_end;
    node.total_fee_start = summary.total_fee_start;
    node.total_fee_end = summary.total_fee_end;
    node.best_prefix_start = summary.best_prefix_start;
    node.best_prefix_end = summary.best_prefix_end;
    node.min_fee_prefix_start = summary.min_fee_prefix_start;
    node.min_fee_prefix_end = summary.min_fee_prefix_end;
    node.sub_min = summary.sub_min;
    node.sub_max = summary.sub_max;
}

fun recompute_node_value(
    nodes: &Table<u64, TreeNode>,
    strike: u64,
    node: &mut TreeNode,
    changed_left: bool,
    changed_right: bool,
    changed_summary: NodeSummary,
): NodeSummary {
    let mut summary = local_summary(strike, node.q_start, node.q_end, node.fee_start, node.fee_end);
    if (node.left.is_some()) {
        let left_summary = if (changed_left) {
            changed_summary
        } else {
            node_summary(&nodes[*node.left.borrow()])
        };
        summary = merge_summary_values(left_summary, summary);
    };
    if (node.right.is_some()) {
        let right_summary = if (changed_right) {
            changed_summary
        } else {
            node_summary(&nodes[*node.right.borrow()])
        };
        summary = merge_summary_values(summary, right_summary);
    };

    write_summary(node, summary);
    summary
}

fun rotate_right(
    nodes: &mut Table<u64, TreeNode>,
    root_strike: u64,
    mut root_node: TreeNode,
    left_strike: u64,
    mut left_node: TreeNode,
): (u64, TreeNode) {
    root_node.left = left_node.right;
    let root_summary = recompute_node_value(
        nodes,
        root_strike,
        &mut root_node,
        false,
        false,
        empty_summary(),
    );
    write_node(nodes, root_strike, root_node);

    left_node.right = option::some(root_strike);
    recompute_node_value(nodes, left_strike, &mut left_node, false, true, root_summary);
    write_node(nodes, left_strike, left_node);
    (left_strike, left_node)
}

fun rotate_left(
    nodes: &mut Table<u64, TreeNode>,
    root_strike: u64,
    mut root_node: TreeNode,
    right_strike: u64,
    mut right_node: TreeNode,
): (u64, TreeNode) {
    root_node.right = right_node.left;
    let root_summary = recompute_node_value(
        nodes,
        root_strike,
        &mut root_node,
        false,
        false,
        empty_summary(),
    );
    write_node(nodes, root_strike, root_node);

    right_node.left = option::some(root_strike);
    recompute_node_value(nodes, right_strike, &mut right_node, true, false, root_summary);
    write_node(nodes, right_strike, right_node);
    (right_strike, right_node)
}

fun empty_summary(): NodeSummary {
    NodeSummary {
        total_q_start: 0,
        total_q_end: 0,
        total_qk_start: 0,
        total_qk_end: 0,
        total_fee_start: 0,
        total_fee_end: 0,
        best_prefix_start: 0,
        best_prefix_end: 0,
        min_fee_prefix_start: 0,
        min_fee_prefix_end: 0,
        sub_min: max_u64(),
        sub_max: 0,
    }
}

fun local_summary(
    strike: u64,
    q_start: u64,
    q_end: u64,
    fee_start: u64,
    fee_end: u64,
): NodeSummary {
    let mut best_prefix_start = 0;
    let mut best_prefix_end = 0;
    if (prefix_is_better(q_start, q_end, best_prefix_start, best_prefix_end)) {
        best_prefix_start = q_start;
        best_prefix_end = q_end;
    };

    let mut min_fee_prefix_start = 0;
    let mut min_fee_prefix_end = 0;
    if (prefix_is_lower(fee_start, fee_end, min_fee_prefix_start, min_fee_prefix_end)) {
        min_fee_prefix_start = fee_start;
        min_fee_prefix_end = fee_end;
    };

    let has_inventory = q_start > 0 || q_end > 0;
    NodeSummary {
        total_q_start: q_start,
        total_q_end: q_end,
        total_qk_start: math::mul(q_start, strike),
        total_qk_end: math::mul(q_end, strike),
        total_fee_start: fee_start,
        total_fee_end: fee_end,
        best_prefix_start,
        best_prefix_end,
        min_fee_prefix_start,
        min_fee_prefix_end,
        sub_min: if (has_inventory) { strike } else { max_u64() },
        sub_max: if (has_inventory) { strike } else { 0 },
    }
}

fun node_summary(node: &TreeNode): NodeSummary {
    NodeSummary {
        total_q_start: node.total_q_start,
        total_q_end: node.total_q_end,
        total_qk_start: node.total_qk_start,
        total_qk_end: node.total_qk_end,
        total_fee_start: node.total_fee_start,
        total_fee_end: node.total_fee_end,
        best_prefix_start: node.best_prefix_start,
        best_prefix_end: node.best_prefix_end,
        min_fee_prefix_start: node.min_fee_prefix_start,
        min_fee_prefix_end: node.min_fee_prefix_end,
        sub_min: node.sub_min,
        sub_max: node.sub_max,
    }
}

fun merge_summary_values(left: NodeSummary, right: NodeSummary): NodeSummary {
    let total_q_start = left.total_q_start + right.total_q_start;
    let total_q_end = left.total_q_end + right.total_q_end;
    let total_qk_start = left.total_qk_start + right.total_qk_start;
    let total_qk_end = left.total_qk_end + right.total_qk_end;
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

    NodeSummary {
        total_q_start,
        total_q_end,
        total_qk_start,
        total_qk_end,
        total_fee_start,
        total_fee_end,
        best_prefix_start,
        best_prefix_end,
        min_fee_prefix_start,
        min_fee_prefix_end,
        sub_min: left.sub_min.min(right.sub_min),
        sub_max: left.sub_max.max(right.sub_max),
    }
}

fun prefix_is_better(
    candidate_start: u64,
    candidate_end: u64,
    best_start: u64,
    best_end: u64,
): bool {
    candidate_start + best_end >= candidate_end + best_start
}

fun prefix_is_lower(
    candidate_start: u64,
    candidate_end: u64,
    best_start: u64,
    best_end: u64,
): bool {
    candidate_start + best_end <= candidate_end + best_start
}

fun prefix_before(
    nodes: &Table<u64, TreeNode>,
    root: Option<u64>,
    settlement: u64,
): (u64, u64, u64, u64) {
    if (root.is_none()) return (0, 0, 0, 0);

    let strike = *root.borrow();
    let node = nodes[strike];
    if (settlement <= strike) {
        return prefix_before(nodes, node.left, settlement)
    };

    let (mut q_start, mut q_end, mut fee_start, mut fee_end) = if (node.left.is_some()) {
        node_prefix(&nodes[*node.left.borrow()])
    } else {
        (0, 0, 0, 0)
    };
    q_start = q_start + node.q_start;
    q_end = q_end + node.q_end;
    fee_start = fee_start + node.fee_start;
    fee_end = fee_end + node.fee_end;

    let (right_q_start, right_q_end, right_fee_start, right_fee_end) = prefix_before(
        nodes,
        node.right,
        settlement,
    );
    (
        q_start + right_q_start,
        q_end + right_q_end,
        fee_start + right_fee_start,
        fee_end + right_fee_end,
    )
}

fun node_prefix(node: &TreeNode): (u64, u64, u64, u64) {
    (node.total_q_start, node.total_q_end, node.total_fee_start, node.total_fee_end)
}

fun eval_inorder(
    nodes: &Table<u64, TreeNode>,
    strike: u64,
    curve: &vector<CurvePoint>,
    mut cursor: u64,
): (u64, u64, u64) {
    let node = nodes[strike];
    if (node.total_q_start == 0 && node.total_q_end == 0) return (0, 0, cursor);

    let len = curve.length();
    while (cursor < len && curve[cursor].strike() <= node.sub_min) {
        cursor = cursor + 1;
    };

    let has_interior =
        node.sub_min < node.sub_max
        && cursor < len
        && curve[cursor].strike() < node.sub_max;

    if (!has_interior) {
        let mut start_value = 0;
        let mut end_value = 0;
        if (node.total_q_start > 0) {
            let start_avg = math::div(node.total_qk_start, node.total_q_start);
            start_value = math::mul(node.total_q_start, interp_at(curve, cursor, start_avg));
        };
        if (node.total_q_end > 0) {
            let end_avg = math::div(node.total_qk_end, node.total_q_end);
            end_value = math::mul(node.total_q_end, interp_at(curve, cursor, end_avg));
        };
        while (cursor < len && curve[cursor].strike() <= node.sub_max) {
            cursor = cursor + 1;
        };
        return (start_value, end_value, cursor)
    };

    let mut start_value = 0;
    let mut end_value = 0;
    if (node.left.is_some()) {
        let (starts, ends, c) = eval_inorder(nodes, *node.left.borrow(), curve, cursor);
        start_value = start_value + starts;
        end_value = end_value + ends;
        cursor = c;
    };

    while (cursor < len && curve[cursor].strike() <= strike) {
        cursor = cursor + 1;
    };

    let price = interp_at(curve, cursor, strike);
    if (node.q_start > 0) {
        start_value = start_value + math::mul(node.q_start, price);
    };
    if (node.q_end > 0) {
        end_value = end_value + math::mul(node.q_end, price);
    };

    if (node.right.is_some()) {
        let (starts, ends, c) = eval_inorder(nodes, *node.right.borrow(), curve, cursor);
        start_value = start_value + starts;
        end_value = end_value + ends;
        cursor = c;
    };

    (start_value, end_value, cursor)
}

fun interp_at(curve: &vector<CurvePoint>, cursor: u64, strike: u64): u64 {
    let len = curve.length();

    if (cursor == 0) return curve[0].up_price();
    if (cursor >= len) return curve[len - 1].up_price();

    let k_lo = curve[cursor - 1].strike();
    let k_hi = curve[cursor].strike();
    let p_lo = curve[cursor - 1].up_price();
    let p_hi = curve[cursor].up_price();

    if (strike <= k_lo) return p_lo;
    if (strike >= k_hi) return p_hi;

    let range = k_hi - k_lo;
    if (range == 0) return p_lo;

    let offset = strike - k_lo;
    let ratio = math::div(offset, range);
    if (p_hi >= p_lo) {
        p_lo + math::mul(p_hi - p_lo, ratio)
    } else {
        p_lo - math::mul(p_lo - p_hi, ratio)
    }
}

fun destroy_nodes(nodes: &mut Table<u64, TreeNode>, root: Option<u64>) {
    if (root.is_none()) return;
    let strike = *root.borrow();
    let node = nodes.remove(strike);
    destroy_nodes(nodes, node.left);
    destroy_nodes(nodes, node.right);
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
