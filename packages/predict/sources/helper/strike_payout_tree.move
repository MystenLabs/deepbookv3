// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Sparse strike exposure index for payout-liability accounting.
///
/// This treap stores finite interval boundaries touched by positions. It tracks
/// only atomic payout terms: range quantity and floor shares. Live and settled
/// payout liability are derived by applying the relevant floor index at read
/// time.
module deepbook_predict::strike_payout_tree;

use deepbook_predict::{constants, math as predict_math};
use sui::{bcs, hash::blake2b256, table::{Self, Table}};

const EInvalidTickSize: u64 = 0;
const EInvalidStrikeRange: u64 = 1;
const EInsufficientQuantity: u64 = 2;
const EUnalignedStrike: u64 = 5;
const EZeroQuantity: u64 = 6;
const ETooManyStrikes: u64 = 7;
const EFloorExceedsQuantity: u64 = 8;

/// Sparse payout-liability tree for strike prefixes.
public struct StrikePayoutTree has store {
    root: Option<u64>,
    nodes: Table<u64, PayoutNode>,
    tick_size: u64,
    min_strike: u64,
    max_strike: u64,
    base: PayoutTerms,
}

/// Quantity and floor shares tracked together at each payout boundary.
public struct PayoutTerms has copy, drop, store {
    quantity: u64,
    floor_shares: u64,
}

/// Treap node keyed by finite boundary strike.
public struct PayoutNode has copy, drop, store {
    priority: u64,
    left: Option<u64>,
    right: Option<u64>,
    start: PayoutTerms,
    end: PayoutTerms,
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
        base: payout_terms(0, 0),
    }
}

/// Insert interval quantity/floor shares for `(lower, higher]`.
public(package) fun insert_range(
    tree: &mut StrikePayoutTree,
    lower: u64,
    higher: u64,
    qty: u64,
    floor_shares: u64,
) {
    tree.apply_range(lower, higher, payout_terms(qty, floor_shares), true);
}

/// Remove interval quantity/floor shares for `(lower, higher]`.
public(package) fun remove_range(
    tree: &mut StrikePayoutTree,
    lower: u64,
    higher: u64,
    qty: u64,
    floor_shares: u64,
) {
    tree.apply_range(lower, higher, payout_terms(qty, floor_shares), false);
}

/// Return current live max payout under aggregate floor rounding.
public(package) fun max_live_payout(tree: &StrikePayoutTree, floor_index: u64): u64 {
    let best = payout_amount(tree.base, floor_index);
    let (_, best) = scan_max_live_payout(
        &tree.nodes,
        tree.root,
        tree.base,
        floor_index,
        best,
    );
    best
}

/// Evaluate settled payout liability at one settlement price and floor index.
public(package) fun settled_value(tree: &StrikePayoutTree, settlement: u64, floor_index: u64): u64 {
    let terms = scan_settled_payout(
        &tree.nodes,
        tree.root,
        settlement,
        tree.base,
    );
    payout_amount(terms, floor_index)
}

/// Destroy all sparse payout storage without reading settlement liability.
public(package) fun destroy(tree: StrikePayoutTree) {
    let StrikePayoutTree {
        root,
        mut nodes,
        tick_size: _,
        min_strike: _,
        max_strike: _,
        base: _,
    } = tree;
    destroy_nodes(&mut nodes, root);
    nodes.destroy_empty();
}

fun apply_range(
    tree: &mut StrikePayoutTree,
    lower: u64,
    higher: u64,
    terms: PayoutTerms,
    add: bool,
) {
    tree.assert_range_boundaries(lower, higher, terms.quantity);

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
        assert!(add, EInsufficientQuantity);
        let leaf = new_leaf(strike, terms, is_start);
        nodes.add(strike, leaf);
        return strike
    };

    let root_strike = *root.borrow();
    let mut node = nodes[root_strike];
    if (strike == root_strike) {
        if (is_start) {
            apply_terms_delta(&mut node.start, terms, add);
        } else {
            apply_terms_delta(&mut node.end, terms, add);
        };
        write_node(nodes, root_strike, node);
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

    write_node(nodes, root_strike, node);
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
        start,
        end,
    }
}

fun rotate_right(
    nodes: &mut Table<u64, PayoutNode>,
    root_strike: u64,
    mut root_node: PayoutNode,
    left_strike: u64,
    mut left_node: PayoutNode,
): u64 {
    root_node.left = left_node.right;
    write_node(nodes, root_strike, root_node);

    left_node.right = option::some(root_strike);
    write_node(nodes, left_strike, left_node);
    left_strike
}

fun rotate_left(
    nodes: &mut Table<u64, PayoutNode>,
    root_strike: u64,
    mut root_node: PayoutNode,
    right_strike: u64,
    mut right_node: PayoutNode,
): u64 {
    root_node.right = right_node.left;
    write_node(nodes, root_strike, root_node);

    right_node.left = option::some(root_strike);
    write_node(nodes, right_strike, right_node);
    right_strike
}

fun scan_max_live_payout(
    nodes: &Table<u64, PayoutNode>,
    root: Option<u64>,
    running: PayoutTerms,
    floor_index: u64,
    best: u64,
): (PayoutTerms, u64) {
    if (root.is_none()) return (running, best);
    let node = nodes[*root.borrow()];
    let (mut running, mut best) = scan_max_live_payout(
        nodes,
        node.left,
        running,
        floor_index,
        best,
    );

    apply_terms_delta(&mut running, node.start, true);
    apply_terms_delta(&mut running, node.end, false);
    let candidate = payout_amount(running, floor_index);
    if (candidate > best) best = candidate;

    scan_max_live_payout(nodes, node.right, running, floor_index, best)
}

fun scan_settled_payout(
    nodes: &Table<u64, PayoutNode>,
    root: Option<u64>,
    settlement: u64,
    running: PayoutTerms,
): PayoutTerms {
    if (root.is_none()) return running;
    let strike = *root.borrow();
    let node = nodes[strike];
    let mut running = scan_settled_payout(
        nodes,
        node.left,
        settlement,
        running,
    );

    if (settlement <= strike) return running;

    apply_terms_delta(&mut running, node.start, true);
    apply_terms_delta(&mut running, node.end, false);

    scan_settled_payout(nodes, node.right, settlement, running)
}

fun write_node(nodes: &mut Table<u64, PayoutNode>, strike: u64, node: PayoutNode) {
    *(&mut nodes[strike]) = node;
}

fun payout_terms(quantity: u64, floor_shares: u64): PayoutTerms {
    PayoutTerms { quantity, floor_shares }
}

fun payout_amount(terms: PayoutTerms, floor_index: u64): u64 {
    let floor_amount = predict_math::mul_div_round_down(
        terms.floor_shares,
        floor_index,
        constants::float_scaling!(),
    );
    assert!(floor_amount <= terms.quantity, EFloorExceedsQuantity);
    terms.quantity - floor_amount
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

fun assert_range_boundaries(tree: &StrikePayoutTree, lower: u64, higher: u64, qty: u64) {
    assert_range_shape(lower, higher, qty);
    if (lower != constants::neg_inf!()) tree.assert_finite_boundary(lower);
    if (higher != constants::pos_inf!()) tree.assert_finite_boundary(higher);
}

fun assert_finite_boundary(tree: &StrikePayoutTree, strike: u64) {
    assert!(strike >= tree.min_strike && strike <= tree.max_strike, EInvalidStrikeRange);
    assert!((strike - tree.min_strike) % tree.tick_size == 0, EUnalignedStrike);
}

fun assert_range_shape(lower: u64, higher: u64, qty: u64) {
    assert!(lower < higher, EInvalidStrikeRange);
    assert!(
        !(lower == constants::neg_inf!() && higher == constants::pos_inf!()),
        EInvalidStrikeRange,
    );
    assert!(qty > 0, EZeroQuantity);
}

fun apply_terms_delta(value: &mut PayoutTerms, delta: PayoutTerms, add: bool) {
    if (add) {
        value.quantity = value.quantity + delta.quantity;
        value.floor_shares = value.floor_shares + delta.floor_shares;
    } else {
        assert_terms_available(*value, delta);
        value.quantity = value.quantity - delta.quantity;
        value.floor_shares = value.floor_shares - delta.floor_shares;
    };
}

fun assert_terms_available(available: PayoutTerms, required: PayoutTerms) {
    assert!(available.quantity >= required.quantity, EInsufficientQuantity);
    assert!(available.floor_shares >= required.floor_shares, EInsufficientQuantity);
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
