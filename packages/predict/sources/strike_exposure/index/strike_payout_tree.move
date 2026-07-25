// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Sparse strike exposure index for payout-liability accounting.
///
/// The tree keys finite interval boundaries by absolute tick, matching the tick
/// pair packed into the durable order ID. Raw strikes are recovered only at the
/// pricing/settlement boundary, where callers pass the owning market's `tick_size`
/// (`raw_strike = tick * tick_size`); the tree stores no grid geometry.
///
/// This treap stores finite interval boundaries touched by positions. It tracks
/// each order's quantity and its net payout (`Q - F`), converting the packed
/// static floor once at the write boundary so no aggregate read re-derives it.
/// Live cash backing is the max-point net payout plus a buffer over the
/// disjoint-book gap; the tree's max-point term is the floor anchor of that
/// enforced reserve.
module deepbook_predict::strike_payout_tree;

use deepbook_predict::{constants, pricing::{Pricer, PriceMemo}, range_codec};
use fixed_math::{approx::{Self, Approx}, i64};
use sui::{bcs, hash::blake2b256, table::{Self, Table}};

const EInsufficientPayoutTerms: u64 = 0;
const EMaxPayoutTreeNodes: u64 = 1;

/// Sparse payout-liability tree keyed by finite strike tick.
public struct StrikePayoutTree has store {
    root: Option<u64>,
    nodes: Table<u64, PayoutNode>,
    node_count: u64,
    base: PayoutTerms,
}

/// Atomic payout terms used for boundary deltas and subtree totals.
public struct PayoutTerms has copy, drop, store {
    /// Aggregate order quantity over the prefix. Read by the NAV linear walk
    /// (`walk_linear`), which prices each boundary's start/end quantity.
    quantity: u64,
    /// Aggregate net payout (`Q - F`) over the prefix — the basis for settled
    /// liability and max-point reserve reads. Stored rather than derived so a
    /// negative aggregate net payout is unrepresentable instead of relying on the
    /// per-order `F <= Q` invariant surviving every summation.
    net_payout: u64,
}

/// Subtree net-payout totals and max static net-payout prefix gain. No consumer
/// reads a subtree's aggregate quantity, so only the net terms are summarized.
public struct PayoutSummary has copy, drop, store {
    net_start: u64,
    net_end: u64,
    max_net_payout_prefix_gain: u64,
}

/// Treap node keyed by finite boundary tick.
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

/// Return `(max_net_payout, total_net_payout)` for pre-settlement reserve math.
public(package) fun net_payout_reserve_terms(tree: &StrikePayoutTree): (u64, u64) {
    let mut max_net_payout = tree.base.net_payout;
    let mut total_net_payout = tree.base.net_payout;
    if (tree.root.is_some()) {
        let summary = tree.nodes[*tree.root.borrow()].summary;
        max_net_payout = max_net_payout + summary.max_net_payout_prefix_gain;
        total_net_payout = total_net_payout + summary.net_start;
    };
    (max_net_payout, total_net_payout)
}

/// Evaluate payout liability at one positive normalized settlement price.
/// Open-lower ranges live in `base`; finite boundaries below
/// `ceil(settlement / tick_size)` are folded into that prefix.
public(package) fun settled_payout_liability(
    tree: &StrikePayoutTree,
    settlement: u64,
    tick_size: u64,
): u64 {
    let limit_tick = range_codec::prefix_limit_tick(settlement, tick_size);
    settlement_prefix_net_payout(
        &tree.nodes,
        tree.root,
        limit_tick,
        tree.base.net_payout,
    )
}

/// Value the quantity-weighted linear liability by pricing each distinct boundary
/// once. The in-order walk records boundary prices in `memo` for the leveraged
/// correction scan.
///
/// Each boundary's exact signed net quantity is multiplied by its shared price
/// certificate once, then accumulated into one signed approximate total. The
/// signed result retains any boundary-rounding residue; `marked_live_liability`
/// subtracts the leveraged correction and projects the final economic liability
/// to nonnegative once. `tree.base` is the `P(-inf) = 1` anchor for
/// `(-inf, h]` ranges (its quantity enters at face value); `+inf` ends are never
/// stored (`P = 0`).
public(package) fun walk_linear(
    tree: &StrikePayoutTree,
    pricer: &Pricer,
    memo: &mut PriceMemo,
    tick_size: u64,
): Approx {
    let running = walk_linear_subtree(
        &tree.nodes,
        tree.root,
        pricer,
        tick_size,
        memo,
    );
    let base = approx::exact_u64(tree.base.quantity);
    base.add(&running)
}

/// Create an empty sparse payout tree.
public(package) fun new(ctx: &mut TxContext): StrikePayoutTree {
    StrikePayoutTree {
        root: option::none(),
        nodes: table::new(ctx),
        node_count: 0,
        base: payout_terms(0, 0),
    }
}

/// Insert interval payout terms for the order tick range `(lower_tick, higher_tick]`.
public(package) fun insert_range(
    tree: &mut StrikePayoutTree,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    floor_shares: u64,
) {
    let terms = payout_terms_from_order(quantity, floor_shares);
    if (terms.is_zero_terms()) return;

    // Whole-line ranges are rejected by `order`, so this pre-count matches the
    // finite boundaries `apply_range` can create.
    let mut new_nodes = 0;
    if (lower_tick != 0 && !tree.nodes.contains(lower_tick)) {
        new_nodes = new_nodes + 1;
    };
    if (
        higher_tick != constants::pos_inf_tick!()
            && higher_tick != lower_tick
            && !tree.nodes.contains(higher_tick)
    ) {
        new_nodes = new_nodes + 1;
    };

    assert!(
        tree.node_count + new_nodes <= constants::max_payout_tree_nodes!(),
        EMaxPayoutTreeNodes,
    );

    tree.apply_range(lower_tick, higher_tick, terms, true);
}

/// Remove interval payout terms for the order tick range `(lower_tick, higher_tick]`.
public(package) fun remove_range(
    tree: &mut StrikePayoutTree,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    floor_shares: u64,
) {
    tree.apply_range(
        lower_tick,
        higher_tick,
        payout_terms_from_order(quantity, floor_shares),
        false,
    );
}

#[test_only]
/// Seed the stored count so tests can exercise the node-cap boundary directly.
public(package) fun set_node_count_for_testing(tree: &mut StrikePayoutTree, node_count: u64) {
    tree.node_count = node_count;
}

fun apply_range(
    tree: &mut StrikePayoutTree,
    lower_tick: u64,
    higher_tick: u64,
    terms: PayoutTerms,
    add: bool,
) {
    // Skip a fully-zero delta; index any order with nonzero quantity.
    if (terms.is_zero_terms()) return;

    if (lower_tick == 0) {
        apply_terms_delta(&mut tree.base, terms, add);
        tree.apply_boundary_delta(higher_tick, terms, false, add);
    } else {
        tree.apply_boundary_delta(lower_tick, terms, true, add);
        if (higher_tick != constants::pos_inf_tick!()) {
            tree.apply_boundary_delta(higher_tick, terms, false, add);
        };
    };
}

fun apply_boundary_delta(
    tree: &mut StrikePayoutTree,
    tick: u64,
    terms: PayoutTerms,
    is_start: bool,
    add: bool,
) {
    let had_node = tree.nodes.contains(tick);
    let new_root = apply_at(
        &mut tree.nodes,
        tree.root,
        tick,
        terms,
        is_start,
        add,
    );
    tree.root = new_root;

    let has_node = tree.nodes.contains(tick);
    if (!had_node && has_node) {
        tree.node_count = tree.node_count + 1;
    } else if (had_node && !has_node) {
        tree.node_count = tree.node_count - 1;
    };
}

fun apply_at(
    nodes: &mut Table<u64, PayoutNode>,
    root: Option<u64>,
    tick: u64,
    terms: PayoutTerms,
    is_start: bool,
    add: bool,
): Option<u64> {
    if (root.is_none()) {
        assert!(add, EInsufficientPayoutTerms);
        let leaf = new_leaf(tick, terms, is_start);
        nodes.add(tick, leaf);
        return option::some(tick)
    };

    let root_tick = *root.borrow();
    let mut node = nodes[root_tick];

    if (tick == root_tick) {
        if (is_start) {
            apply_terms_delta(&mut node.local_start, terms, add);
        } else {
            apply_terms_delta(&mut node.local_end, terms, add);
        };
        if (is_empty_node(node)) {
            let _removed = nodes.remove(root_tick);
            return merge_subtrees(nodes, node.left, node.right)
        };
        resummarize(nodes, root_tick, node);
        return option::some(root_tick)
    };

    if (tick < root_tick) {
        let new_left = apply_at(
            nodes,
            node.left,
            tick,
            terms,
            is_start,
            add,
        );
        if (add && new_left.is_some()) {
            let left_tick = *new_left.borrow();
            let left_node = nodes[left_tick];
            if (left_node.priority > node.priority) {
                let rotated = rotate_right(nodes, root_tick, node, left_tick, left_node);
                return option::some(rotated)
            };
        };
        node.left = new_left;
    } else {
        let new_right = apply_at(
            nodes,
            node.right,
            tick,
            terms,
            is_start,
            add,
        );
        if (add && new_right.is_some()) {
            let right_tick = *new_right.borrow();
            let right_node = nodes[right_tick];
            if (right_node.priority > node.priority) {
                let rotated = rotate_left(nodes, root_tick, node, right_tick, right_node);
                return option::some(rotated)
            };
        };
        node.right = new_right;
    };

    resummarize(nodes, root_tick, node);
    option::some(root_tick)
}

fun new_leaf(tick: u64, terms: PayoutTerms, is_start: bool): PayoutNode {
    let (start, end) = if (is_start) {
        (terms, payout_terms(0, 0))
    } else {
        (payout_terms(0, 0), terms)
    };

    PayoutNode {
        priority: tick_priority(tick),
        left: option::none(),
        right: option::none(),
        local_start: start,
        local_end: end,
        summary: boundary_summary(start, end),
    }
}

fun rotate_right(
    nodes: &mut Table<u64, PayoutNode>,
    root_tick: u64,
    mut root_node: PayoutNode,
    left_tick: u64,
    mut left_node: PayoutNode,
): u64 {
    // Write the demoted node first so the new parent re-summarizes against it.
    root_node.left = left_node.right;
    resummarize(nodes, root_tick, root_node);

    left_node.right = option::some(root_tick);
    resummarize(nodes, left_tick, left_node);
    left_tick
}

fun rotate_left(
    nodes: &mut Table<u64, PayoutNode>,
    root_tick: u64,
    mut root_node: PayoutNode,
    right_tick: u64,
    mut right_node: PayoutNode,
): u64 {
    // Write the demoted node first so the new parent re-summarizes against it.
    root_node.right = right_node.left;
    resummarize(nodes, root_tick, root_node);

    right_node.left = option::some(root_tick);
    resummarize(nodes, right_tick, right_node);
    right_tick
}

fun merge_subtrees(
    nodes: &mut Table<u64, PayoutNode>,
    left: Option<u64>,
    right: Option<u64>,
): Option<u64> {
    if (left.is_none()) return right;
    if (right.is_none()) return left;

    let left_tick = *left.borrow();
    let right_tick = *right.borrow();
    let mut left_node = nodes[left_tick];
    let mut right_node = nodes[right_tick];
    if (left_node.priority > right_node.priority) {
        left_node.right = merge_subtrees(nodes, left_node.right, right);
        resummarize(nodes, left_tick, left_node);
        option::some(left_tick)
    } else {
        right_node.left = merge_subtrees(nodes, left, right_node.left);
        resummarize(nodes, right_tick, right_node);
        option::some(right_tick)
    }
}

fun settlement_prefix_net_payout(
    nodes: &Table<u64, PayoutNode>,
    root: Option<u64>,
    limit_tick: u64,
    running: u64,
): u64 {
    if (root.is_none()) return running;
    let tick = *root.borrow();
    let node = nodes[tick];
    // A boundary is active in the prefix iff `tick < limit_tick`
    // (`tick * tick_size < settlement`); otherwise exclude it and its right subtree.
    if (limit_tick <= tick) {
        return settlement_prefix_net_payout(nodes, node.left, limit_tick, running)
    };

    let mut running = running;
    let left_summary = subtree_summary(nodes, node.left);
    apply_net_delta(&mut running, left_summary.net_start, true);
    apply_net_delta(&mut running, left_summary.net_end, false);
    apply_net_delta(&mut running, node.local_start.net_payout, true);
    apply_net_delta(&mut running, node.local_end.net_payout, false);
    settlement_prefix_net_payout(nodes, node.right, limit_tick, running)
}

/// Accumulate signed net-boundary products during an in-order walk. Every node
/// is cached even when its equal local start and end quantities cancel, because
/// leveraged-order correction lookups require every finite boundary.
fun walk_linear_subtree(
    nodes: &Table<u64, PayoutNode>,
    root: Option<u64>,
    pricer: &Pricer,
    tick_size: u64,
    memo: &mut PriceMemo,
): Approx {
    if (root.is_none()) return approx::exact_u64(0);
    let tick = *root.borrow();
    let node = nodes[tick];

    let left = walk_linear_subtree(
        nodes,
        node.left,
        pricer,
        tick_size,
        memo,
    );

    let price = memo.price_and_cache(pricer, tick, tick_size);
    let start_quantity = node.local_start.quantity;
    let end_quantity = node.local_end.quantity;
    let net_quantity = i64::from_parts(
        start_quantity.diff(end_quantity),
        start_quantity < end_quantity,
    );
    let local = price.mul_exact(&net_quantity);

    let right = walk_linear_subtree(
        nodes,
        node.right,
        pricer,
        tick_size,
        memo,
    );
    left.add(&local).add(&right)
}

fun resummarize(nodes: &mut Table<u64, PayoutNode>, tick: u64, mut node: PayoutNode) {
    let left = subtree_summary(nodes, node.left);
    let right = subtree_summary(nodes, node.right);
    let boundary = boundary_summary(node.local_start, node.local_end);
    node.summary = combine_summaries(combine_summaries(left, boundary), right);
    *nodes.borrow_mut(tick) = node;
}

fun subtree_summary(nodes: &Table<u64, PayoutNode>, root: Option<u64>): PayoutSummary {
    if (root.is_none()) return zero_summary();
    nodes[*root.borrow()].summary
}

fun boundary_summary(start: PayoutTerms, end: PayoutTerms): PayoutSummary {
    PayoutSummary {
        net_start: start.net_payout,
        net_end: end.net_payout,
        max_net_payout_prefix_gain: positive_net_delta(start.net_payout, end.net_payout, 0),
    }
}

fun zero_summary(): PayoutSummary {
    PayoutSummary {
        net_start: 0,
        net_end: 0,
        max_net_payout_prefix_gain: 0,
    }
}

fun combine_summaries(left: PayoutSummary, right: PayoutSummary): PayoutSummary {
    let right_gain_after_left = positive_net_delta(
        left.net_start,
        left.net_end,
        right.max_net_payout_prefix_gain,
    );

    PayoutSummary {
        net_start: left.net_start + right.net_start,
        net_end: left.net_end + right.net_end,
        max_net_payout_prefix_gain: left.max_net_payout_prefix_gain.max(right_gain_after_left),
    }
}

fun positive_net_delta(start: u64, end: u64, gain: u64): u64 {
    (start + gain).saturating_sub(end)
}

/// Convert the packed order atoms into stored terms. `order::assert_valid` is the
/// `F <= Q` authority, so this is the one site where a floor becomes a net payout.
fun payout_terms_from_order(quantity: u64, floor_shares: u64): PayoutTerms {
    PayoutTerms { quantity, net_payout: quantity - floor_shares }
}

fun payout_terms(quantity: u64, net_payout: u64): PayoutTerms {
    PayoutTerms { quantity, net_payout }
}

fun is_zero_terms(terms: PayoutTerms): bool {
    terms.quantity == 0 && terms.net_payout == 0
}

fun is_empty_node(node: PayoutNode): bool {
    is_zero_terms(node.local_start) && is_zero_terms(node.local_end)
}

fun apply_terms_delta(value: &mut PayoutTerms, delta: PayoutTerms, add: bool) {
    apply_net_delta(&mut value.quantity, delta.quantity, add);
    apply_net_delta(&mut value.net_payout, delta.net_payout, add);
}

fun apply_net_delta(value: &mut u64, delta: u64, add: bool) {
    if (add) {
        *value = *value + delta;
    } else {
        assert!(*value >= delta, EInsufficientPayoutTerms);
        *value = *value - delta;
    };
}

fun tick_priority(tick: u64): u64 {
    let bytes = bcs::to_bytes(&tick);
    let hash = blake2b256(&bytes);
    let mut out = 0;
    8u64.do!(|i| out = (out << 8) | (hash[i] as u64));
    out
}
