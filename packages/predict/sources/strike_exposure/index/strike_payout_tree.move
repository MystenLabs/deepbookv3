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
/// each order's quantity and static floor shares, deriving net payout (`quantity -
/// floor_shares = Q - F`) for settled liability and max single-point payout. Live
/// cash backing is the max-point net payout plus a buffer over the disjoint-book
/// gap; the tree's max-point term is the floor anchor of that enforced reserve.
module deepbook_predict::strike_payout_tree;

use deepbook_predict::{constants, pricing::{Pricer, PriceMemo}, range_codec};
use fixed_math::math;
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
    /// Aggregate static floor shares over the prefix. Net payout is derived as
    /// `quantity - floor_shares` for settled liability and max-point reserve reads.
    floor_shares: u64,
}

/// Subtree totals and max static net-payout prefix gain.
public struct PayoutSummary has copy, drop, store {
    total_start: PayoutTerms,
    total_end: PayoutTerms,
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

/// Return the total quantity of all live orders in the tree. Every order
/// contributes its quantity to exactly one start side (`base` for `-inf`
/// lower boundaries, a node otherwise), so the root summary's start total plus
/// the base is the whole book's face outstanding — an O(1) read of state the
/// treap already maintains.
public(package) fun total_quantity(tree: &StrikePayoutTree): u64 {
    let mut total = tree.base.quantity;
    if (tree.root.is_some()) {
        total = total + tree.nodes[*tree.root.borrow()].summary.total_start.quantity;
    };
    total
}

/// Return `(max_net_payout, total_net_payout)` for pre-settlement reserve math.
public(package) fun net_payout_reserve_terms(tree: &StrikePayoutTree): (u64, u64) {
    let mut max_net_payout = net_payout(tree.base);
    let mut total_terms = tree.base;
    if (tree.root.is_some()) {
        let summary = tree.nodes[*tree.root.borrow()].summary;
        max_net_payout = max_net_payout + summary.max_net_payout_prefix_gain;
        total_terms = add_terms(total_terms, summary.total_start);
    };
    (max_net_payout, net_payout(total_terms))
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
    net_payout(terms)
}

/// Value the NAV linear term — `Σ_orders qty·P(strike)` — by walking the whole
/// tree and pricing each distinct boundary once through `pricer` (converting its
/// tick to a raw strike with `tick_size`). Every priced tick is recorded into
/// `memo` in ascending order so the correction walk can read boundary prices back
/// by binary search instead of re-pricing each leveraged order.
///
/// The start and end sides accumulate as two non-negative totals: a node's net
/// `local_start - local_end` quantity is signed, so a single running `u64` would
/// underflow mid-walk. They combine once at the top:
/// `base.quantity + start_total - end_total`. `tree.base` is the `P(-inf) = 1`
/// anchor for `(-inf, h]` ranges (its quantity enters at face value); `+inf` ends
/// are never stored (`P = 0`).
public(package) fun walk_linear(
    tree: &StrikePayoutTree,
    pricer: &Pricer,
    memo: &mut PriceMemo,
    tick_size: u64,
): u64 {
    let (start_total, end_total) = walk_linear_subtree(
        &tree.nodes,
        tree.root,
        pricer,
        tick_size,
        memo,
    );
    // Range liability cannot be negative. Floor the aggregate once to keep valuation
    // reads live when fixed-point dust or an admitted butterfly-arbitrageable SVI
    // surface makes signed boundary netting invert. Predeploy P-11 tracks that the
    // latter can materially diverge from per-order range pricing, which floors each
    // order independently.
    (tree.base.quantity + start_total).saturating_sub(end_total)
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
    let terms = payout_terms(quantity, floor_shares);
    if (terms.is_zero_terms()) return;

    // Cap pre-count. `(0, pos_inf]` (the whole line) is rejected upstream at `order` shape validation,
    // so `lower_tick == 0` here always implies a FINITE `higher_tick`, for which this pre-count and
    // `apply_range` agree (both create the higher node). The pos_inf-skip below would undercount only
    // for that unreachable `(0, pos_inf]` case; if the upstream shape guard ever changes, count the
    // higher boundary in the `lower == 0` branch here too.
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
        payout_terms(quantity, floor_shares),
        false,
    );
}

#[test_only]
public(package) fun debug_contains_node(tree: &StrikePayoutTree, tick: u64): bool {
    tree.nodes.contains(tick)
}

#[test_only]
public(package) fun debug_node_count(tree: &StrikePayoutTree): u64 {
    tree.node_count
}

// Seed `node_count` for the exact 1000-node cap-BOUNDARY tests. Genuinely irreducible (unit-tests.md
// Rule 18): ~1000 REAL treap inserts (each hashes a priority + rebalances a growing Table) time out
// the Move test framework, so the boundary tests fake the count to reach the cap fast, then insert one
// more to assert `EMaxPayoutTreeNodes`. `node_count_tracks_real_boundary_accumulation` inserts a
// moderate REAL batch to prove the counter tracks genuine accumulation, not just this setter.
#[test_only]
public(package) fun debug_set_node_count(tree: &mut StrikePayoutTree, node_count: u64) {
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
/// quantity·price).
///
/// Traversal is in-order (left, node, right): the tree is a BST keyed by tick, so
/// this caches ascending ticks into `memo` for the correction walk's binary search.
/// Every node is priced exactly once and recorded UNCONDITIONALLY, so the memo
/// covers every leveraged boundary the correction can look up; the start/end muls
/// are still skipped when `local_start.quantity == local_end.quantity`, since equal
/// `P·q` on both sides cancels in `walk_linear`'s top-level subtraction (exact).
fun walk_linear_subtree(
    nodes: &Table<u64, PayoutNode>,
    root: Option<u64>,
    pricer: &Pricer,
    tick_size: u64,
    memo: &mut PriceMemo,
): (u64, u64) {
    if (root.is_none()) return (0, 0);
    let tick = *root.borrow();
    let node = nodes[tick];

    let (left_start, left_end) = walk_linear_subtree(nodes, node.left, pricer, tick_size, memo);

    let price = memo.price_and_cache(pricer, tick, tick_size);
    let mut start_total = 0;
    let mut end_total = 0;
    if (node.local_start.quantity != node.local_end.quantity) {
        start_total = math::mul(price, node.local_start.quantity);
        end_total = math::mul(price, node.local_end.quantity);
    };

    let (right_start, right_end) = walk_linear_subtree(nodes, node.right, pricer, tick_size, memo);
    (start_total + left_start + right_start, end_total + left_end + right_end)
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
        total_start: start,
        total_end: end,
        max_net_payout_prefix_gain: positive_net_delta(start, end, 0),
    }
}

fun zero_summary(): PayoutSummary {
    PayoutSummary {
        total_start: payout_terms(0, 0),
        total_end: payout_terms(0, 0),
        max_net_payout_prefix_gain: 0,
    }
}

fun combine_summaries(left: PayoutSummary, right: PayoutSummary): PayoutSummary {
    let right_gain_after_left = positive_net_delta(
        left.total_start,
        left.total_end,
        right.max_net_payout_prefix_gain,
    );

    PayoutSummary {
        total_start: add_terms(left.total_start, right.total_start),
        total_end: add_terms(left.total_end, right.total_end),
        max_net_payout_prefix_gain: left.max_net_payout_prefix_gain.max(right_gain_after_left),
    }
}

fun positive_net_delta(start: PayoutTerms, end: PayoutTerms, gain: u64): u64 {
    (net_payout(start) + gain).saturating_sub(net_payout(end))
}

fun add_terms(left: PayoutTerms, right: PayoutTerms): PayoutTerms {
    payout_terms(
        left.quantity + right.quantity,
        left.floor_shares + right.floor_shares,
    )
}

fun net_payout(terms: PayoutTerms): u64 {
    terms.quantity - terms.floor_shares
}

fun payout_terms(quantity: u64, floor_shares: u64): PayoutTerms {
    PayoutTerms { quantity, floor_shares }
}

fun is_zero_terms(terms: PayoutTerms): bool {
    terms.quantity == 0 && terms.floor_shares == 0
}

fun is_empty_node(node: PayoutNode): bool {
    is_zero_terms(node.local_start) && is_zero_terms(node.local_end)
}

fun apply_terms_delta(value: &mut PayoutTerms, delta: PayoutTerms, add: bool) {
    if (add) {
        value.quantity = value.quantity + delta.quantity;
        value.floor_shares = value.floor_shares + delta.floor_shares;
    } else {
        assert!(value.quantity >= delta.quantity, EInsufficientPayoutTerms);
        assert!(value.floor_shares >= delta.floor_shares, EInsufficientPayoutTerms);
        value.quantity = value.quantity - delta.quantity;
        value.floor_shares = value.floor_shares - delta.floor_shares;
    };
}

fun tick_priority(tick: u64): u64 {
    let bytes = bcs::to_bytes(&tick);
    let hash = blake2b256(&bytes);
    let mut out = 0;
    8u64.do!(|i| out = (out << 8) | (hash[i] as u64));
    out
}
