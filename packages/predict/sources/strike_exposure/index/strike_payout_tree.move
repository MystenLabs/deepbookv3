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
/// is a dynamic-field child, and `apply_at` and `settlement_prefix_payout`
/// touch one per level against a per-transaction cached-object ceiling.
///
/// It tracks each order's quantity, which is also its settled payout: a winning
/// order pays its full quantity. Live cash backing is the max-point payout plus a
/// buffer over the disjoint-book gap; the tree's max-point term is the floor
/// anchor of that enforced reserve.
///
/// Shape carries no value for a consistent index: `combine_summaries` is
/// associative over the in-order sequence, so any arrangement of the same
/// boundaries yields identical summaries, settlement prefixes, and linear-walk
/// totals. That holds only while every prefix is non-negative, which a consistent
/// book guarantees. Under a caller/index desync the settlement walk's underflow
/// abort depends on which prefixes a given shape happens to visit, so it is not a
/// desync detector — the per-boundary underflow in `apply_net_delta` is the
/// authority.
///
/// The module also owns the valuation snapshot for the resumable flush: while a
/// flush generation is active, each node lazily captures its boundary quantities
/// immediately before its first mutation under that generation (an untouched node
/// is its own snapshot), and `walk_linear_frozen` prices the tree exactly as it
/// stood at the snapshot instant through the same walk the live read uses.
module deepbook_predict::strike_payout_tree;

use deepbook_predict::{constants, pricing::Pricer, range_codec};
use fixed_math::math;
use sui::table::{Self, Table};

const EInsufficientPayoutQuantity: u64 = 0;
const EMaxPayoutTreeNodes: u64 = 1;
const ENonMonotonePrice: u64 = 2;
const EStaleValuationSnapshot: u64 = 3;
const ESnapshotSeqNotIncreasing: u64 = 4;

/// Sparse payout-liability tree keyed by finite strike tick.
public struct StrikePayoutTree has store {
    root: Option<u64>,
    nodes: Table<u64, PayoutNode>,
    node_count: u64,
    /// Aggregate order quantity over the open-lower prefix, which is also its
    /// aggregate settled payout.
    base: u64,
    /// Flush generation whose snapshot this tree holds. Node shadows are valid
    /// only against this value; monotonically increasing, 0 = never snapshotted.
    snapshot_seq: u64,
    /// True from `activate_snapshot` until `release_snapshot`/`deactivate_snapshot`.
    /// While set, mutations capture shadows and emptied nodes with shadow
    /// quantities are retained for the frozen walk instead of removed.
    snapshot_active: bool,
    /// `base` as of the snapshot instant, captured eagerly at activation.
    snapshot_base: u64,
}

/// Subtree payout totals and max static payout prefix gain.
public struct PayoutSummary has copy, drop, store {
    start: u64,
    end: u64,
    /// Never exceeds `start`, by construction in `boundary_summary` and
    /// `combine_summaries`. That bound is what makes `combine_summaries`
    /// associative at u64 scale — and therefore what makes the tree's shape
    /// irrelevant to every value it reports. A summary term that could outgrow
    /// `start` would break shape-independence with no test to catch it, and
    /// would also abort `strike_exposure`'s plain `total - max` subtraction.
    max_payout_prefix_gain: u64,
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
    local_start: u64,
    local_end: u64,
    /// Boundary terms as of generation `snapshot_seq`'s snapshot instant,
    /// captured lazily before this node's first mutation under that generation.
    /// A node stamped with the active generation but zero shadows was created
    /// after the snapshot; a node stamped with an older generation is untouched
    /// since the snapshot, so its live terms ARE its shadow.
    snapshot_local_start: u64,
    snapshot_local_end: u64,
    snapshot_seq: u64,
    summary: PayoutSummary,
}

/// Return `(max_payout, total_payout)` for pre-settlement reserve math.
public(package) fun payout_reserve_terms(tree: &StrikePayoutTree): (u64, u64) {
    let mut max_payout = tree.base;
    let mut total_payout = tree.base;
    if (tree.root.is_some()) {
        let summary = tree.nodes[*tree.root.borrow()].summary;
        max_payout = max_payout + summary.max_payout_prefix_gain;
        total_payout = total_payout + summary.start;
    };
    (max_payout, total_payout)
}

/// Return the highest payout prefix reachable inside `(lower_tick, higher_tick]`.
/// This is the existing payout peak a candidate over the same range would stack
/// onto.
public(package) fun range_max_payout(
    tree: &StrikePayoutTree,
    lower_tick: u64,
    higher_tick: u64,
): u64 {
    // Prefix evaluation folds boundaries with `tick < limit`, so `lower + 1`
    // includes a start boundary exactly at `lower`. Tick zero is the open-lower
    // sentinel and lives in `base`, not in the node table.
    let prefix_at_lower = settlement_prefix_payout(
        &tree.nodes,
        tree.root,
        lower_tick + 1,
        tree.base,
    );
    let window = window_summary(
        &tree.nodes,
        tree.root,
        lower_tick,
        higher_tick,
        0,
        constants::pos_inf_tick!(),
    );
    prefix_at_lower + window.max_payout_prefix_gain
}

/// Return the highest payout prefix outside `(lower_tick, higher_tick]`.
public(package) fun complement_max_payout(
    tree: &StrikePayoutTree,
    lower_tick: u64,
    higher_tick: u64,
): u64 {
    let left = if (lower_tick == 0) {
        0
    } else {
        tree.range_max_payout(0, lower_tick)
    };
    let right = if (higher_tick == constants::pos_inf_tick!()) {
        0
    } else {
        tree.range_max_payout(higher_tick, constants::pos_inf_tick!())
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
    settlement_prefix_payout(
        &tree.nodes,
        tree.root,
        limit_tick,
        tree.base,
    )
}

/// Value the quantity-weighted linear liability by pricing each distinct boundary
/// once.
///
/// The start and end sides accumulate as two non-negative totals: a node's net
/// `local_start - local_end` quantity is signed, so a single running `u64` would
/// underflow mid-walk. They combine once at the top:
/// `base + start_total - end_total`. `tree.base` is the `P(-inf) = 1`
/// anchor for `(-inf, h]` ranges (its quantity enters at face value); `+inf` ends
/// are never stored (`P = 0`).
public(package) fun walk_linear(tree: &StrikePayoutTree, pricer: &Pricer, tick_size: u64): u64 {
    let mut previous_price = option::none();
    let (start_total, end_total) = walk_linear_subtree(
        &tree.nodes,
        tree.root,
        pricer,
        tick_size,
        0,
        &mut previous_price,
    );
    // Boundary products are rounded per node and the signed aggregate is floored
    // once. This can differ from pricing and flooring each order independently.
    (tree.base + start_total).saturating_sub(end_total)
}

/// Value the liability the tree held at generation `snapshot_seq`'s snapshot
/// instant. This is `walk_linear` — the same traversal, per-node rounding,
/// two-sided accumulation, single floor, and monotonicity observation — over each
/// node's shadow terms where the active generation captured them and its live
/// terms where it did not (untouched since the snapshot means live IS the
/// snapshot). A boundary created after the snapshot carries zero shadows and is
/// not part of the frozen surface, so it is neither priced nor observed here; the
/// live walk observes it on every live NAV read.
public(package) fun walk_linear_frozen(
    tree: &StrikePayoutTree,
    pricer: &Pricer,
    tick_size: u64,
    snapshot_seq: u64,
): u64 {
    assert!(
        tree.snapshot_active && tree.snapshot_seq == snapshot_seq && snapshot_seq != 0,
        EStaleValuationSnapshot,
    );
    let mut previous_price = option::none();
    let (start_total, end_total) = walk_linear_subtree(
        &tree.nodes,
        tree.root,
        pricer,
        tick_size,
        snapshot_seq,
        &mut previous_price,
    );
    (tree.snapshot_base + start_total).saturating_sub(end_total)
}

/// Create an empty sparse payout tree.
public(package) fun new(ctx: &mut TxContext): StrikePayoutTree {
    StrikePayoutTree {
        root: option::none(),
        nodes: table::new(ctx),
        node_count: 0,
        base: 0,
        snapshot_seq: 0,
        snapshot_active: false,
        snapshot_base: 0,
    }
}

/// Insert interval payout quantity for the order tick range `(lower_tick, higher_tick]`.
public(package) fun insert_range(
    tree: &mut StrikePayoutTree,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
) {
    if (quantity == 0) return;

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

    tree.apply_range(lower_tick, higher_tick, quantity, true);
}

/// Remove interval payout quantity for the order tick range `(lower_tick, higher_tick]`.
public(package) fun remove_range(
    tree: &mut StrikePayoutTree,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
) {
    tree.apply_range(lower_tick, higher_tick, quantity, false);
}

/// Begin holding generation `snapshot_seq`'s snapshot: the tree state at this
/// instant becomes readable through `walk_linear_frozen` while live mutations
/// continue. O(1) — `base` is captured eagerly and nodes capture themselves
/// lazily on first mutation. The generation is the flush ordinal, minted
/// strictly increasing by `protocol_config::begin_valuation`, so a stale
/// activation (an aborted flush's) is always superseded, never re-entered.
public(package) fun activate_snapshot(tree: &mut StrikePayoutTree, snapshot_seq: u64) {
    assert!(snapshot_seq > tree.snapshot_seq, ESnapshotSeqNotIncreasing);
    tree.snapshot_seq = snapshot_seq;
    tree.snapshot_active = true;
    tree.snapshot_base = tree.base;
}

/// Stop holding the snapshot without walking the tree: shadows stop being
/// captured and emptied nodes stop being retained. For the trade-path discard of
/// a stale (aborted-flush) snapshot; nodes already retained for it stay until
/// `release_snapshot` at the next consumed generation, or until a mutation
/// empties them again with no current-generation shadow.
public(package) fun deactivate_snapshot(tree: &mut StrikePayoutTree) {
    tree.snapshot_active = false;
}

/// Consume the snapshot after its frozen walk has been read: deactivate, then
/// remove every node with zero live quantities — exactly the nodes retained for
/// a snapshot (this generation's, or a stale generation's never consumed because
/// its flush aborted). Runs in the market's own valuation transaction, whose
/// budget already covers every node (`constants::max_payout_tree_nodes`), so
/// retention never outlives the one flush window that read it.
public(package) fun release_snapshot(tree: &mut StrikePayoutTree) {
    tree.snapshot_active = false;
    let mut husks = vector[];
    collect_husks(&tree.nodes, tree.root, &mut husks);
    husks.do!(|tick| {
        tree.root = detach_tick(&mut tree.nodes, tree.root, tick);
        tree.node_count = tree.node_count - 1;
    });
}

fun apply_range(
    tree: &mut StrikePayoutTree,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    add: bool,
) {
    // Skip a fully-zero delta; index any order with nonzero quantity.
    if (quantity == 0) return;

    if (lower_tick == 0) {
        apply_net_delta(&mut tree.base, quantity, add);
        tree.apply_boundary_delta(higher_tick, quantity, false, add);
    } else {
        tree.apply_boundary_delta(lower_tick, quantity, true, add);
        if (higher_tick != constants::pos_inf_tick!()) {
            tree.apply_boundary_delta(higher_tick, quantity, false, add);
        };
    };
}

fun apply_boundary_delta(
    tree: &mut StrikePayoutTree,
    tick: u64,
    quantity: u64,
    is_start: bool,
    add: bool,
) {
    let had_node = tree.nodes.contains(tick);
    // 0 encodes "no active snapshot": active generations are flush ordinals,
    // which start at 1.
    let snapshot_seq = if (tree.snapshot_active) tree.snapshot_seq else 0;
    let new_root = apply_at(
        &mut tree.nodes,
        tree.root,
        tick,
        quantity,
        is_start,
        add,
        snapshot_seq,
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
    quantity: u64,
    is_start: bool,
    add: bool,
    snapshot_seq: u64,
): Option<u64> {
    if (root.is_none()) {
        assert!(add, EInsufficientPayoutQuantity);
        let leaf = new_leaf(quantity, is_start, snapshot_seq);
        nodes.add(tick, leaf);
        return option::some(tick)
    };

    let root_tick = *root.borrow();
    let mut node = nodes[root_tick];

    if (tick == root_tick) {
        capture_snapshot_if_stale(&mut node, snapshot_seq);
        if (is_start) {
            apply_net_delta(&mut node.local_start, quantity, add);
        } else {
            apply_net_delta(&mut node.local_end, quantity, add);
        };
        // An emptied node whose shadow the active generation still needs is
        // retained as a live-zero husk; `release_snapshot` removes it once the
        // frozen walk has been read.
        if (is_empty_node(node) && !retains_snapshot(&node, snapshot_seq)) {
            let _removed = nodes.remove(root_tick);
            return join_subtrees(nodes, node.left, node.right)
        };
        resummarize(nodes, root_tick, node);
        return option::some(root_tick)
    };

    // The descent is a plain BST insert; every structural decision is deferred to
    // `rebalance` on the way back up, which reads only measured heights.
    if (tick < root_tick) {
        node.left = apply_at(nodes, node.left, tick, quantity, is_start, add, snapshot_seq);
    } else {
        node.right = apply_at(nodes, node.right, tick, quantity, is_start, add, snapshot_seq);
    };

    option::some(rebalance(nodes, root_tick, node))
}

fun new_leaf(quantity: u64, is_start: bool, snapshot_seq: u64): PayoutNode {
    let (start, end) = if (is_start) {
        (quantity, 0)
    } else {
        (0, quantity)
    };

    PayoutNode {
        height: 1,
        left: option::none(),
        right: option::none(),
        local_start: start,
        local_end: end,
        // Stamped with the active generation and zero shadows: created after
        // the snapshot, so the frozen walk excludes it.
        snapshot_local_start: 0,
        snapshot_local_end: 0,
        snapshot_seq,
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

fun settlement_prefix_payout(
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
        return settlement_prefix_payout(nodes, node.left, limit_tick, running)
    };

    let mut running = running;
    let left_summary = subtree_summary(nodes, node.left);
    apply_net_delta(&mut running, left_summary.start, true);
    apply_net_delta(&mut running, left_summary.end, false);
    apply_net_delta(&mut running, node.local_start, true);
    apply_net_delta(&mut running, node.local_end, false);
    settlement_prefix_payout(nodes, node.right, limit_tick, running)
}

/// Combine every boundary strictly inside `(lower, higher)`. Whole subtrees
/// contained by the window return their stored summary, keeping the read
/// logarithmic in tree height rather than scanning the payout surface.
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

/// Accumulate start and end boundary products separately during an in-order walk
/// over the view `frozen_seq` selects: 0 walks live terms; a generation walks
/// each node's shadow where that generation captured one and its live terms
/// otherwise.
///
/// EVERY boundary in the selected view is priced, including one whose start and
/// end quantities cancel. Only the arithmetic is skipped there, because such a
/// boundary contributes `price * q - price * q = 0` to the netted aggregate at
/// any price. The pricing call itself must not be skipped: it is where
/// monotonicity is observed, and a cancelling boundary is still the shared edge
/// of two live orders. An inversion sitting on it does not move this walk's
/// total, but it does move what `redeem_live` pays per order (`range_price` is
/// evaluated per order, not netted), so skipping the observation would let NAV
/// understate liability without aborting. A node whose selected terms are both
/// zero is NOT part of the view — on the live view it is a retained husk (no
/// live order touches its tick), on a frozen view it was created after the
/// snapshot — so pricing it would observe a tick outside the surface being
/// valued; the view that does own the tick observes it.
fun walk_linear_subtree(
    nodes: &Table<u64, PayoutNode>,
    root: Option<u64>,
    pricer: &Pricer,
    tick_size: u64,
    frozen_seq: u64,
    previous_price: &mut Option<u64>,
): (u64, u64) {
    if (root.is_none()) return (0, 0);
    let tick = *root.borrow();
    let node = nodes[tick];

    let (left_start, left_end) = walk_linear_subtree(
        nodes,
        node.left,
        pricer,
        tick_size,
        frozen_seq,
        previous_price,
    );

    let (local_start, local_end) = if (frozen_seq != 0 && node.snapshot_seq == frozen_seq) {
        (node.snapshot_local_start, node.snapshot_local_end)
    } else {
        (node.local_start, node.local_end)
    };

    let mut start_total = 0;
    let mut end_total = 0;
    if (local_start != 0 || local_end != 0) {
        let price = pricer.up_price(range_codec::strike_from_tick(tick, tick_size));
        // UP price is non-increasing in strike and the in-order walk visits
        // ascending ticks, so a rising price is a non-monotone surface: the netted
        // aggregate below would understate the per-order liability the protocol
        // actually honors.
        if (previous_price.is_some()) {
            assert!(price <= *previous_price.borrow(), ENonMonotonePrice);
        };
        *previous_price = option::some(price);

        if (local_start != local_end) {
            start_total = math::mul_down(price, local_start);
            end_total = math::mul_down(price, local_end);
        };
    };

    let (right_start, right_end) = walk_linear_subtree(
        nodes,
        node.right,
        pricer,
        tick_size,
        frozen_seq,
        previous_price,
    );
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

fun boundary_summary(start: u64, end: u64): PayoutSummary {
    PayoutSummary {
        start,
        end,
        max_payout_prefix_gain: positive_net_delta(start, end, 0),
    }
}

fun zero_summary(): PayoutSummary {
    PayoutSummary {
        start: 0,
        end: 0,
        max_payout_prefix_gain: 0,
    }
}

fun combine_summaries(left: PayoutSummary, right: PayoutSummary): PayoutSummary {
    let right_gain_after_left = positive_net_delta(
        left.start,
        left.end,
        right.max_payout_prefix_gain,
    );

    PayoutSummary {
        start: left.start + right.start,
        end: left.end + right.end,
        max_payout_prefix_gain: left.max_payout_prefix_gain.max(right_gain_after_left),
    }
}

fun positive_net_delta(start: u64, end: u64, gain: u64): u64 {
    (start + gain).saturating_sub(end)
}

fun is_empty_node(node: PayoutNode): bool {
    node.local_start == 0 && node.local_end == 0
}

/// Copy live terms into the shadow before the first mutation under the active
/// generation. A node already stamped with it — captured earlier, or created
/// under it (whose zero shadows mean "not in the snapshot" and must survive
/// every later mutation) — is left alone.
fun capture_snapshot_if_stale(node: &mut PayoutNode, snapshot_seq: u64) {
    if (snapshot_seq == 0 || node.snapshot_seq == snapshot_seq) return;
    node.snapshot_local_start = node.local_start;
    node.snapshot_local_end = node.local_end;
    node.snapshot_seq = snapshot_seq;
}

/// Whether the active generation still needs this node: it captured a nonzero
/// shadow that `walk_linear_frozen` has yet to read. A stale generation's shadow
/// retains nothing — its flush was superseded and its walk can no longer run.
fun retains_snapshot(node: &PayoutNode, snapshot_seq: u64): bool {
    snapshot_seq != 0
        && node.snapshot_seq == snapshot_seq
        && (node.snapshot_local_start != 0 || node.snapshot_local_end != 0)
}

/// Collect every live-zero tick in order. Only snapshot retention creates such
/// nodes — an emptied node with no shadow to keep is removed at the mutation.
fun collect_husks(nodes: &Table<u64, PayoutNode>, root: Option<u64>, husks: &mut vector<u64>) {
    if (root.is_none()) return;
    let node = nodes[*root.borrow()];
    collect_husks(nodes, node.left, husks);
    if (is_empty_node(node)) husks.push_back(*root.borrow());
    collect_husks(nodes, node.right, husks);
}

/// Remove the node at `tick` — present by construction (a husk `collect_husks`
/// found) — rejoining and rebalancing the path exactly as an emptying mutation
/// would have.
fun detach_tick(nodes: &mut Table<u64, PayoutNode>, root: Option<u64>, tick: u64): Option<u64> {
    let root_tick = *root.borrow();
    let mut node = nodes[root_tick];
    if (tick == root_tick) {
        let _removed = nodes.remove(root_tick);
        return join_subtrees(nodes, node.left, node.right)
    };
    if (tick < root_tick) {
        node.left = detach_tick(nodes, node.left, tick);
    } else {
        node.right = detach_tick(nodes, node.right, tick);
    };
    option::some(rebalance(nodes, root_tick, node))
}

fun apply_net_delta(value: &mut u64, delta: u64, add: bool) {
    if (add) {
        *value = *value + delta;
    } else {
        assert!(*value >= delta, EInsufficientPayoutQuantity);
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
/// Read the stored node count, so snapshot tests can pin husk retention and
/// release against exact counts.
public(package) fun node_count_for_testing(tree: &StrikePayoutTree): u64 {
    tree.node_count
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
    assert!(node.summary.start == summary.start);
    assert!(node.summary.end == summary.end);
    assert!(node.summary.max_payout_prefix_gain == summary.max_payout_prefix_gain);

    (1 + taller, summary, left_count + right_count + 1)
}
