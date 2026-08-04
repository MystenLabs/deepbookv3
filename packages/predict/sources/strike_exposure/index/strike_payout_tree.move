// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Sparse strike exposure index for payout-liability accounting.
///
/// The tree keys finite interval boundaries by absolute tick, matching the tick
/// pair packed into the durable order ID. Raw strikes are recovered only at the
/// pricing/settlement boundary, where callers pass the owning market's `tick_size`
/// (`raw_strike = tick * tick_size`); the tree stores no grid geometry.
///
/// This height-balanced (AVL) tree stores finite interval boundaries touched by
/// positions. Boundary ticks are caller-chosen, so the balancing rule must not
/// read anything the caller supplies: rotations are driven by measured subtree
/// height, which bounds depth at `O(log n)` for *every* tick set rather than in
/// expectation over a random one. Depth is the cost model that matters — each node
/// is a dynamic-field child, and `apply_at` and `settlement_prefix_net_payout`
/// touch one per level against a per-transaction cached-object ceiling.
///
/// It tracks each order's quantity and its net payout (`Q - F`), converting the
/// packed static floor once at the write boundary so no aggregate read re-derives
/// it. Live cash backing is the max-point net payout plus a buffer over the
/// disjoint-book gap; the tree's max-point term is the floor anchor of that
/// enforced reserve.
///
/// Shape carries no value for a consistent index: `combine_summaries` is
/// associative over the in-order sequence, so any arrangement of the same
/// boundaries yields identical summaries, settlement prefixes, and linear-walk
/// totals. That holds only while every prefix is non-negative, which a consistent
/// book guarantees. Under a caller/index desync the settlement walk's underflow
/// abort depends on which prefixes a given shape happens to visit, so it is not a
/// desync detector — `apply_terms_delta`'s per-boundary assert is the authority.
module deepbook_predict::strike_payout_tree;

use deepbook_predict::{constants, pricing::{Pricer, PriceMemo}, range_codec};
use fixed_math::math;
use sui::table::{Self, Table};

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
    /// Never exceeds `net_start`, by construction in `boundary_summary` and
    /// `combine_summaries`. That bound is what makes `combine_summaries`
    /// associative at u64 scale — and therefore what makes the tree's shape
    /// irrelevant to every value it reports. A summary term that could outgrow
    /// `net_start` would break shape-independence with no test to catch it, and
    /// would also abort `strike_exposure`'s plain `total - max` subtraction.
    max_net_payout_prefix_gain: u64,
}

/// Height-balanced node keyed by finite boundary tick.
public struct PayoutNode has copy, drop, store {
    /// Longest root-to-leaf path in this subtree, counting this node. A leaf is 1;
    /// an absent child is 0. Maintained by `resummarize` alongside `summary`, and
    /// read only by `rebalance` — never by a caller, and never derived from a tick.
    height: u64,
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

/// Return the highest net-payout prefix reachable inside the tick range
/// `(lower_tick, higher_tick]` — the peak of the existing payout profile a new
/// order over that same range would stack onto.
///
/// The profile only steps at stored boundaries, so the candidates are the prefix
/// at `lower_tick` itself plus the prefix at every boundary strictly inside the
/// range; a boundary AT `higher_tick` is excluded because it closes the range
/// rather than paying inside it. Both are read as one absolute prefix plus the
/// window's own max prefix gain, which the stored subtree summaries already carry.
public(package) fun range_max_net_payout(
    tree: &StrikePayoutTree,
    lower_tick: u64,
    higher_tick: u64,
): u64 {
    // `settlement_prefix_net_payout` folds in boundaries with `tick < limit`, so
    // `lower_tick + 1` includes a start boundary sitting exactly at `lower_tick`.
    // At `lower_tick == 0` (`-inf`) no stored key qualifies and the prefix is `base`.
    let prefix_at_lower = settlement_prefix_net_payout(
        &tree.nodes,
        tree.root,
        lower_tick + 1,
        tree.base.net_payout,
    );
    let window = window_summary(
        &tree.nodes,
        tree.root,
        lower_tick,
        higher_tick,
        0,
        constants::pos_inf_tick!(),
    );
    // The gain is clamped at zero by `combine_summaries`, so the sum is
    // `max(prefix_at_lower, max in-window prefix)` and never exceeds the whole
    // tree's max prefix.
    prefix_at_lower + window.max_net_payout_prefix_gain
}

/// Return the highest net-payout prefix reachable *outside* `(lower_tick, higher_tick]`.
///
/// An order covers the half-open tick range `(lower, higher]`, so the complement
/// is `(-inf, lower] ∪ (higher, +inf]`: `lower_tick` itself is not covered and
/// belongs to the left arm, while `higher_tick` is covered and is excluded from
/// the right arm. Empty arms (open `-inf` lower or `+inf` higher) contribute 0
/// rather than calling `range_max_net_payout` on a degenerate window.
public(package) fun complement_max_net_payout(
    tree: &StrikePayoutTree,
    lower_tick: u64,
    higher_tick: u64,
): u64 {
    // Left arm `(0, lower_tick]`. Tick 0 is the `-inf` sentinel; a range that
    // already opens there has no left complement.
    let left = if (lower_tick == 0) {
        0
    } else {
        tree.range_max_net_payout(0, lower_tick)
    };
    // Right arm `(higher_tick, +inf]`. `pos_inf_tick` is the open upper sentinel;
    // a range that already closes there has no right complement.
    let right = if (higher_tick == constants::pos_inf_tick!()) {
        0
    } else {
        tree.range_max_net_payout(higher_tick, constants::pos_inf_tick!())
    };
    left.max(right)
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
    // Boundary products are rounded per node and the signed aggregate is floored
    // once. This can differ from pricing and flooring each order independently.
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
        let leaf = new_leaf(terms, is_start);
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
            return join_subtrees(nodes, node.left, node.right)
        };
        resummarize(nodes, root_tick, node);
        return option::some(root_tick)
    };

    // The descent is a plain BST insert; every structural decision is deferred to
    // `rebalance` on the way back up, which reads only measured heights.
    if (tick < root_tick) {
        node.left = apply_at(nodes, node.left, tick, terms, is_start, add);
    } else {
        node.right = apply_at(nodes, node.right, tick, terms, is_start, add);
    };

    option::some(rebalance(nodes, root_tick, node))
}

fun new_leaf(terms: PayoutTerms, is_start: bool): PayoutNode {
    let (start, end) = if (is_start) {
        (terms, payout_terms(0, 0))
    } else {
        (payout_terms(0, 0), terms)
    };

    PayoutNode {
        height: 1,
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
): u64 {
    let left_tick = *root_node.left.borrow();
    let mut left_node = nodes[left_tick];

    // Write the demoted node first so the new parent re-summarizes (and re-measures
    // its height) against it.
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
): u64 {
    let right_tick = *root_node.right.borrow();
    let mut right_node = nodes[right_tick];

    // Write the demoted node first so the new parent re-summarizes (and re-measures
    // its height) against it.
    root_node.right = right_node.left;
    resummarize(nodes, root_tick, root_node);

    right_node.left = option::some(root_tick);
    resummarize(nodes, right_tick, right_node);
    right_tick
}

/// Fill the hole left by a GC'd boundary with the in-order successor — the
/// leftmost node of the right subtree — then rebalance the joined subtree. The
/// successor keeps its own tick (the table is keyed by tick, so a node is never
/// re-keyed) and inherits the removed node's children.
fun join_subtrees(
    nodes: &mut Table<u64, PayoutNode>,
    left: Option<u64>,
    right: Option<u64>,
): Option<u64> {
    if (left.is_none()) return right;
    if (right.is_none()) return left;

    let (successor_tick, remainder) = take_min(nodes, *right.borrow());
    let mut successor = nodes[successor_tick];
    successor.left = left;
    successor.right = remainder;
    option::some(rebalance(nodes, successor_tick, successor))
}

/// Detach the leftmost node of the subtree rooted at `tick`. Returns that node's
/// tick and the rebalanced remainder. The detached node is left in the table for
/// `join_subtrees` to relink — it is never orphaned, because the only caller
/// immediately reinstalls it.
fun take_min(nodes: &mut Table<u64, PayoutNode>, tick: u64): (u64, Option<u64>) {
    let mut node = nodes[tick];
    if (node.left.is_none()) return (tick, node.right);

    let (min_tick, remainder) = take_min(nodes, *node.left.borrow());
    node.left = remainder;
    (min_tick, option::some(rebalance(nodes, tick, node)))
}

/// Write `node` back at `tick`, restoring the height invariant at that position.
/// Returns the tick now rooting the subtree. One rotation fixes an outside-heavy
/// child; an inside-heavy one needs its own rotation first so the taller
/// grandchild ends up on the outside.
fun rebalance(nodes: &mut Table<u64, PayoutNode>, tick: u64, mut node: PayoutNode): u64 {
    let left_height = subtree_height(nodes, node.left);
    let right_height = subtree_height(nodes, node.right);

    if (left_height > right_height + 1) {
        let left_tick = *node.left.borrow();
        let left_node = nodes[left_tick];
        if (subtree_height(nodes, left_node.right) > subtree_height(nodes, left_node.left)) {
            node.left = option::some(rotate_left(nodes, left_tick, left_node));
        };
        rotate_right(nodes, tick, node)
    } else if (right_height > left_height + 1) {
        let right_tick = *node.right.borrow();
        let right_node = nodes[right_tick];
        if (subtree_height(nodes, right_node.left) > subtree_height(nodes, right_node.right)) {
            node.right = option::some(rotate_right(nodes, right_tick, right_node));
        };
        rotate_left(nodes, tick, node)
    } else {
        resummarize(nodes, tick, node);
        tick
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

/// Combine the summaries of every boundary strictly inside `(lower, higher)`.
///
/// `subtree_low`/`subtree_high` are the exclusive key bounds this subtree is
/// already known to lie within, which is what makes the walk `O(log n)`: a subtree
/// entirely inside the window is read from its stored summary in one load instead
/// of being descended. `combine_summaries` is associative over the in-order
/// sequence, so combining the pieces left-to-right yields the same summary the
/// window's boundaries would produce as one contiguous run.
fun window_summary(
    nodes: &Table<u64, PayoutNode>,
    root: Option<u64>,
    lower: u64,
    higher: u64,
    subtree_low: u64,
    subtree_high: u64,
): PayoutSummary {
    if (root.is_none()) return zero_summary();
    if (subtree_low >= lower && subtree_high <= higher) return subtree_summary(nodes, root);

    let tick = *root.borrow();
    let node = nodes[tick];
    if (tick <= lower) {
        return window_summary(nodes, node.right, lower, higher, tick, subtree_high)
    };
    if (tick >= higher) {
        return window_summary(nodes, node.left, lower, higher, subtree_low, tick)
    };

    let left = window_summary(nodes, node.left, lower, higher, subtree_low, tick);
    let right = window_summary(nodes, node.right, lower, higher, tick, subtree_high);
    let boundary = boundary_summary(node.local_start, node.local_end);
    combine_summaries(combine_summaries(left, boundary), right)
}

/// Accumulate start and end boundary products separately during an in-order walk.
/// Every node is cached even when its equal local start and end quantities cancel,
/// because leveraged-order correction lookups require every finite boundary.
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
        start_total = math::mul_down(price, node.local_start.quantity);
        end_total = math::mul_down(price, node.local_end.quantity);
    };

    let (right_start, right_end) = walk_linear_subtree(nodes, node.right, pricer, tick_size, memo);
    (start_total + left_start + right_start, end_total + left_end + right_end)
}

fun resummarize(nodes: &mut Table<u64, PayoutNode>, tick: u64, mut node: PayoutNode) {
    let (left, left_height) = subtree_facts(nodes, node.left);
    let (right, right_height) = subtree_facts(nodes, node.right);
    let boundary = boundary_summary(node.local_start, node.local_end);
    node.summary = combine_summaries(combine_summaries(left, boundary), right);
    node.height = 1 + left_height.max(right_height);
    *nodes.borrow_mut(tick) = node;
}

/// Summary and height of one child in a single table read. Every re-summarize
/// needs both, and each child load is a dynamic-field access — reading the two
/// fields separately doubled the loads on the hottest path in the module.
fun subtree_facts(nodes: &Table<u64, PayoutNode>, root: Option<u64>): (PayoutSummary, u64) {
    if (root.is_none()) return (zero_summary(), 0);
    let node = nodes[*root.borrow()];
    (node.summary, node.height)
}

fun subtree_summary(nodes: &Table<u64, PayoutNode>, root: Option<u64>): PayoutSummary {
    if (root.is_none()) return zero_summary();
    nodes[*root.borrow()].summary
}

fun subtree_height(nodes: &Table<u64, PayoutNode>, root: Option<u64>): u64 {
    if (root.is_none()) return 0;
    nodes[*root.borrow()].height
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
    // Net payout can never exceed quantity (floor_shares = quantity - net_payout
    // >= 0). A remove that breaks this subtracted a floor component that was never
    // inserted -- a caller/index desync -- so abort rather than leave the boundary
    // holding a phantom net payout above zero quantity.
    assert!(value.net_payout <= value.quantity, EInsufficientPayoutTerms);
}

fun apply_net_delta(value: &mut u64, delta: u64, add: bool) {
    if (add) {
        *value = *value + delta;
    } else {
        assert!(*value >= delta, EInsufficientPayoutTerms);
        *value = *value - delta;
    };
}

// === Test-Only Functions ===

#[test_only]
/// Seed the stored count so tests can exercise the node-cap boundary directly.
public(package) fun set_node_count_for_testing(tree: &mut StrikePayoutTree, node_count: u64) {
    tree.node_count = node_count;
}

#[test_only]
/// Assert the whole tree invariant, recomputing every stored field from the
/// children rather than trusting it: search order, AVL balance, each node's
/// `height`, each node's `summary`, and that no node is stranded outside the tree.
///
/// Balance alone is not the property that protects money here. A splice that
/// mislinks a child, or leaves a stale `summary`, yields a perfectly balanced tree
/// whose settled liability is silently wrong — no abort, no height violation, and
/// `node_count` still agreeing with the table. Only recomputation catches that.
///
/// Returns the tree's height, which is the guarantee this module now makes and
/// which no evaluator output reveals — so callers get the depth assertion from the
/// same seam rather than needing a second one.
public(package) fun assert_tree_invariant_for_testing(tree: &StrikePayoutTree): u64 {
    let (height, _, reachable) = assert_subtree_invariant(
        &tree.nodes,
        tree.root,
        0,
        constants::pos_inf_tick!(),
    );
    assert!(reachable == tree.node_count);
    height
}

#[test_only]
/// Returns `(height, summary, node count)` for the subtree, asserting every
/// invariant on the way. `lower`/`upper` are the exclusive key bounds this subtree
/// must lie within — that is what makes a mislinked child detectable.
fun assert_subtree_invariant(
    nodes: &Table<u64, PayoutNode>,
    root: Option<u64>,
    lower: u64,
    upper: u64,
): (u64, PayoutSummary, u64) {
    if (root.is_none()) return (0, zero_summary(), 0);

    let tick = *root.borrow();
    assert!(tick > lower && tick < upper);
    let node = nodes[tick];

    let (left_height, left_summary, left_count) = assert_subtree_invariant(
        nodes,
        node.left,
        lower,
        tick,
    );
    let (right_height, right_summary, right_count) = assert_subtree_invariant(
        nodes,
        node.right,
        tick,
        upper,
    );

    let taller = left_height.max(right_height);
    assert!(taller - left_height.min(right_height) <= 1);
    assert!(node.height == 1 + taller);

    let boundary = boundary_summary(node.local_start, node.local_end);
    let summary = combine_summaries(combine_summaries(left_summary, boundary), right_summary);
    assert!(node.summary.net_start == summary.net_start);
    assert!(node.summary.net_end == summary.net_end);
    assert!(node.summary.max_net_payout_prefix_gain == summary.max_net_payout_prefix_gain);

    (1 + taller, summary, left_count + right_count + 1)
}
