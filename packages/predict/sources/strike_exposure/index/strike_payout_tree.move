// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Sparse strike exposure index for payout-liability accounting.
///
/// The tree keys finite interval boundaries by absolute tick, aligning its keys
/// with the packed order ID and the public range key. Raw strikes are recovered
/// only at the pricing/settlement boundary, where callers pass the owning market's
/// `tick_size` (`raw_strike = tick * tick_size`); the tree stores no grid geometry.
///
/// This treap stores finite interval boundaries touched by positions. It tracks
/// each order's exact terminal payout — summed at a settlement price for settled
/// liability — and a static max-live backing term. Live cash backing is now the
/// max-live settlement floor plus a buffer over the disjoint-book gap; the
/// tree's max-live term is the floor anchor of that enforced reserve.
module deepbook_predict::strike_payout_tree;

use deepbook_predict::{constants, pricing::Pricer, range_codec};
use fixed_math::math;
use sui::{bcs, hash::blake2b256, table::{Self, Table}};

const EInsufficientPayoutTerms: u64 = 0;
const EInvalidPayoutTerms: u64 = 1;

/// Sparse payout-liability tree keyed by finite strike tick.
public struct StrikePayoutTree has store {
    root: Option<u64>,
    nodes: Table<u64, PayoutNode>,
    base: PayoutTerms,
}

/// Atomic payout terms used for boundary deltas and subtree totals.
public struct PayoutTerms has copy, drop, store {
    /// Aggregate order quantity over the prefix. Read by the NAV linear walk
    /// (`walk_linear`), which prices each boundary's start/end quantity.
    quantity: u64,
    terminal_payout: u64,
    live_backing_payout: u64,
}

/// Subtree totals and max static live backing prefix gain.
public struct PayoutSummary has copy, drop, store {
    total_start: PayoutTerms,
    total_end: PayoutTerms,
    max_live_backing_prefix_gain: u64,
    /// Exact tick span of this subtree (BST invariant: leftmost / rightmost node
    /// key). `up_price` is monotone decreasing in strike, so
    /// `[up_price(max_tick·ts), up_price(min_tick·ts)]` bounds every node price in
    /// the subtree — the basis for `walk_linear`'s bounded interpolation. Set in
    /// `new_leaf` / `resummarize`; the `combine_summaries` / `zero_summary` outputs
    /// leave these `0` (the owning node overwrites them).
    min_tick: u64,
    max_tick: u64,
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

/// Return the static max-live backing term: the maximum liability at a single
/// settlement point — the settlement floor that anchors the enforced live reserve.
public(package) fun max_live_backing_payout(tree: &StrikePayoutTree): u64 {
    let mut max_payout = tree.base.live_backing_payout;
    if (tree.root.is_some()) {
        max_payout =
            max_payout + tree.nodes[*tree.root.borrow()].summary.max_live_backing_prefix_gain;
    };
    max_payout
}

/// Evaluate exact settled payout liability at one settlement price. `settlement` is
/// a raw oracle price; finite boundaries with `tick < ceil(settlement / tick_size)`
/// are active in the prefix, preserving the half-open `(lower, higher]` payoff.
public(package) fun settled_payout_liability(
    tree: &StrikePayoutTree,
    settlement: u64,
    tick_size: u64,
): u64 {
    let limit_tick = range_codec::prefix_limit_tick(settlement, tick_size);
    let terms = settlement_prefix_terms(
        &tree.nodes,
        tree.root,
        limit_tick,
        tree.base,
    );
    terms.terminal_payout
}

/// Value the NAV linear term — `Σ_orders qty·P(strike)` — by walking the whole
/// tree and pricing each distinct boundary once through `pricer` (converting its
/// tick to a raw strike with `tick_size`).
///
/// The start and end sides accumulate as two non-negative totals: a node's net
/// `local_start - local_end` quantity is signed, so a single running `u64` would
/// underflow mid-walk. They combine once at the top:
/// `base.quantity + start_total - end_total`. `tree.base` is the `P(-inf) = 1`
/// anchor for `(-inf, h]` ranges (its quantity enters at face value); `+inf` ends
/// are never stored (`P = 0`).
///
/// `tolerance == 0` is the fully exact walk (interpolation off, zero extra
/// pricing). `tolerance > 0` enables bounded subtree interpolation for the linear
/// term only — see `walk_linear_subtree`; the per-order floor (correction) term is
/// always priced exactly elsewhere.
public(package) fun walk_linear(
    tree: &StrikePayoutTree,
    pricer: &Pricer,
    tick_size: u64,
    tolerance: u64,
): u64 {
    let (start_total, end_total) = walk_linear_subtree(
        &tree.nodes,
        tree.root,
        pricer,
        tick_size,
        tolerance,
    );
    // For any mint-admitted book the start side dominates the end side by a wide
    // margin: each order's min net premium forces P(lower) well above P(higher), so
    // its start contribution exceeds its end contribution by >> the per-boundary
    // rounding. saturating_sub floors the residual valuation ulp dust (<= ~1 ulp per
    // shared higher boundary) that thin partial-close survivors clustered in a flat
    // price region could otherwise drive negative — §8.4 dust, re-floored by the
    // caller — instead of aborting the read.
    (tree.base.quantity + start_total).saturating_sub(end_total)
}

/// Create an empty sparse payout tree.
public(package) fun new(ctx: &mut TxContext): StrikePayoutTree {
    StrikePayoutTree {
        root: option::none(),
        nodes: table::new(ctx),
        base: payout_terms(0, 0, 0),
    }
}

/// Insert interval payout terms for the order tick range `(lower_tick, higher_tick]`.
public(package) fun insert_range(
    tree: &mut StrikePayoutTree,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    terminal_payout: u64,
    live_backing_payout: u64,
) {
    tree.apply_range(
        lower_tick,
        higher_tick,
        payout_terms(quantity, terminal_payout, live_backing_payout),
        true,
    );
}

/// Remove interval payout terms for the order tick range `(lower_tick, higher_tick]`.
public(package) fun remove_range(
    tree: &mut StrikePayoutTree,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    terminal_payout: u64,
    live_backing_payout: u64,
) {
    tree.apply_range(
        lower_tick,
        higher_tick,
        payout_terms(quantity, terminal_payout, live_backing_payout),
        false,
    );
}

#[test_only]
public(package) fun destroy(tree: StrikePayoutTree) {
    let StrikePayoutTree {
        root,
        mut nodes,
        base: _,
    } = tree;
    destroy_nodes_for_testing(&mut nodes, root);
    nodes.destroy_empty();
}

fun apply_range(
    tree: &mut StrikePayoutTree,
    lower_tick: u64,
    higher_tick: u64,
    terms: PayoutTerms,
    add: bool,
) {
    // Index any order with nonzero quantity even when both payout terms are 0
    // (e.g. a fully-floored leveraged order with terminal_payout == 0), so the
    // NAV walk never silently skips it.
    if (terms.quantity == 0 && terms.terminal_payout == 0 && terms.live_backing_payout == 0) return;
    assert!(terms.terminal_payout <= terms.live_backing_payout, EInvalidPayoutTerms);

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
    let new_root = apply_at(
        &mut tree.nodes,
        tree.root,
        tick,
        terms,
        is_start,
        add,
    );
    tree.root = option::some(new_root);
}

fun apply_at(
    nodes: &mut Table<u64, PayoutNode>,
    root: Option<u64>,
    tick: u64,
    terms: PayoutTerms,
    is_start: bool,
    add: bool,
): u64 {
    if (root.is_none()) {
        assert!(add, EInsufficientPayoutTerms);
        let leaf = new_leaf(tick, terms, is_start);
        nodes.add(tick, leaf);
        return tick
    };

    let root_tick = *root.borrow();
    let mut node = nodes[root_tick];

    if (tick == root_tick) {
        if (is_start) {
            apply_terms_delta(&mut node.local_start, terms, add);
        } else {
            apply_terms_delta(&mut node.local_end, terms, add);
        };
        resummarize(nodes, root_tick, node);
        return root_tick
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
        let left_node = nodes[new_left];
        if (left_node.priority > node.priority) {
            return rotate_right(nodes, root_tick, node, new_left, left_node)
        };
        node.left = option::some(new_left);
    } else {
        let new_right = apply_at(
            nodes,
            node.right,
            tick,
            terms,
            is_start,
            add,
        );
        let right_node = nodes[new_right];
        if (right_node.priority > node.priority) {
            return rotate_left(nodes, root_tick, node, new_right, right_node)
        };
        node.right = option::some(new_right);
    };

    resummarize(nodes, root_tick, node);
    root_tick
}

fun new_leaf(tick: u64, terms: PayoutTerms, is_start: bool): PayoutNode {
    let (start, end) = if (is_start) {
        (terms, payout_terms(0, 0, 0))
    } else {
        (payout_terms(0, 0, 0), terms)
    };

    let mut summary = boundary_summary(start, end);
    summary.min_tick = tick;
    summary.max_tick = tick;
    PayoutNode {
        priority: tick_priority(tick),
        left: option::none(),
        right: option::none(),
        local_start: start,
        local_end: end,
        summary,
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

fun settlement_prefix_terms(
    nodes: &Table<u64, PayoutNode>,
    root: Option<u64>,
    limit_tick: u64,
    running: PayoutTerms,
): PayoutTerms {
    if (root.is_none()) return running;
    let tick = *root.borrow();
    let node = nodes[tick];
    // A boundary is active in the prefix iff `tick < limit_tick`
    // (`tick * tick_size < settlement`); otherwise exclude it and its right subtree.
    if (limit_tick <= tick) {
        return settlement_prefix_terms(nodes, node.left, limit_tick, running)
    };

    let mut running = running;
    let left_summary = subtree_summary(nodes, node.left);
    apply_terms_delta(&mut running, left_summary.total_start, true);
    apply_terms_delta(&mut running, left_summary.total_end, false);
    apply_terms_delta(&mut running, node.local_start, true);
    apply_terms_delta(&mut running, node.local_end, false);
    settlement_prefix_terms(nodes, node.right, limit_tick, running)
}

/// Accumulate `(start_total, end_total)` over a subtree for `walk_linear`: each
/// node adds `P(tick·ts)·local_start.quantity` to the start side and
/// `P(tick·ts)·local_end.quantity` to the end side. Visits every node and recurses
/// both children — a node is priced at its own strike, so a subtree summary cannot
/// stand in for pricing each boundary (the summary aggregates quantity, not
/// quantity·price). Integer addition is associative, so traversal order is
/// irrelevant.
///
/// Two collapses keep the eval count down:
/// - skip-zero-delta: when `local_start.quantity == local_end.quantity` the two
///   sides contribute the same `P·q` and cancel in `walk_linear`'s top-level
///   subtraction, so the `up_price` eval is skipped (exact; also drops the
///   fully-redeemed boundaries the treap never GCs).
/// - bounded interpolation, only when `tolerance > 0`: if the subtree's exact
///   price span (`up_price(min_tick·ts) - up_price(max_tick·ts)`, monotone so
///   non-negative) is within `tolerance`, the whole subtree is priced at the
///   midpoint and collapsed via its quantity totals, bounding the error by
///   `tolerance·subtree_quantity`. A failing gate spends 2 extreme evals at that
///   node before recursing into both children, so a fully-failing interpolated
///   walk costs up to ~2x the node count in extra evals; exact mode (`tolerance ==
///   0`, the production default) skips the gate and prices nothing extra.
fun walk_linear_subtree(
    nodes: &Table<u64, PayoutNode>,
    root: Option<u64>,
    pricer: &Pricer,
    tick_size: u64,
    tolerance: u64,
): (u64, u64) {
    if (root.is_none()) return (0, 0);
    let tick = *root.borrow();
    let node = nodes[tick];

    if (tolerance > 0) {
        let high_price = pricer.up_price(node.summary.min_tick * tick_size);
        let low_price = pricer.up_price(node.summary.max_tick * tick_size);
        // saturating_sub tolerates a sub-ulp price inversion at adjacent strikes
        // (a collapse there is exact anyway) instead of aborting the read.
        if (high_price.saturating_sub(low_price) <= tolerance) {
            let avg_price = (high_price + low_price) / 2;
            return (
                math::mul(avg_price, node.summary.total_start.quantity),
                math::mul(avg_price, node.summary.total_end.quantity),
            )
        };
    };

    let mut start_total = 0;
    let mut end_total = 0;
    if (node.local_start.quantity != node.local_end.quantity) {
        let price = pricer.up_price(tick * tick_size);
        start_total = math::mul(price, node.local_start.quantity);
        end_total = math::mul(price, node.local_end.quantity);
    };

    let (left_start, left_end) = walk_linear_subtree(
        nodes,
        node.left,
        pricer,
        tick_size,
        tolerance,
    );
    let (right_start, right_end) = walk_linear_subtree(
        nodes,
        node.right,
        pricer,
        tick_size,
        tolerance,
    );
    (start_total + left_start + right_start, end_total + left_end + right_end)
}

fun resummarize(nodes: &mut Table<u64, PayoutNode>, tick: u64, mut node: PayoutNode) {
    let left = subtree_summary(nodes, node.left);
    let right = subtree_summary(nodes, node.right);
    let boundary = boundary_summary(node.local_start, node.local_end);
    let mut summary = combine_summaries(combine_summaries(left, boundary), right);
    // BST span: the subtree's min/max tick is the leftmost/rightmost node key.
    summary.min_tick = if (node.left.is_some()) left.min_tick else tick;
    summary.max_tick = if (node.right.is_some()) right.max_tick else tick;
    node.summary = summary;
    *nodes.borrow_mut(tick) = node;
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
        // The boundary alone carries no tick span; the owning node sets it.
        min_tick: 0,
        max_tick: 0,
    }
}

fun zero_summary(): PayoutSummary {
    PayoutSummary {
        total_start: payout_terms(0, 0, 0),
        total_end: payout_terms(0, 0, 0),
        max_live_backing_prefix_gain: 0,
        min_tick: 0,
        max_tick: 0,
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
        // Tick span depends on which children exist; set by the owning node.
        min_tick: 0,
        max_tick: 0,
    }
}

fun positive_live_delta(start: u64, end: u64, gain: u64): u64 {
    (start + gain).saturating_sub(end)
}

fun add_terms(left: PayoutTerms, right: PayoutTerms): PayoutTerms {
    payout_terms(
        left.quantity + right.quantity,
        left.terminal_payout + right.terminal_payout,
        left.live_backing_payout + right.live_backing_payout,
    )
}

fun payout_terms(quantity: u64, terminal_payout: u64, live_backing_payout: u64): PayoutTerms {
    PayoutTerms { quantity, terminal_payout, live_backing_payout }
}

#[test_only]
fun destroy_nodes_for_testing(nodes: &mut Table<u64, PayoutNode>, root: Option<u64>) {
    if (root.is_none()) return;
    let tick = *root.borrow();
    let node = nodes.remove(tick);
    destroy_nodes_for_testing(nodes, node.left);
    destroy_nodes_for_testing(nodes, node.right);
}

fun apply_terms_delta(value: &mut PayoutTerms, delta: PayoutTerms, add: bool) {
    if (add) {
        value.quantity = value.quantity + delta.quantity;
        value.terminal_payout = value.terminal_payout + delta.terminal_payout;
        value.live_backing_payout = value.live_backing_payout + delta.live_backing_payout;
    } else {
        assert_terms_available(*value, delta);
        value.quantity = value.quantity - delta.quantity;
        value.terminal_payout = value.terminal_payout - delta.terminal_payout;
        value.live_backing_payout = value.live_backing_payout - delta.live_backing_payout;
    };
}

fun assert_terms_available(available: PayoutTerms, required: PayoutTerms) {
    assert!(available.quantity >= required.quantity, EInsufficientPayoutTerms);
    assert!(available.terminal_payout >= required.terminal_payout, EInsufficientPayoutTerms);
    assert!(
        available.live_backing_payout >= required.live_backing_payout,
        EInsufficientPayoutTerms,
    );
}

fun tick_priority(tick: u64): u64 {
    let bytes = bcs::to_bytes(&tick);
    let hash = blake2b256(&bytes);
    let mut out = 0;
    let mut i = 0;
    while (i < 8) {
        out = (out << 8) | (hash[i] as u64);
        i = i + 1;
    };
    out
}
