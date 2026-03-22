// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Treap-based aggregate tree for O(log N) position tracking.
///
/// Each unique strike gets its own node. Nodes are ordered by strike (BST)
/// and by random priority (max-heap), giving expected O(log N) depth
/// regardless of insertion order.
///
/// Every node caches subtree aggregates: total quantity and quantity-weighted
/// strike sum for both UP and DOWN directions. These enable Barnes-Hut style
/// evaluation — descend only where a pricing curve has curvature, use
/// aggregates everywhere else.
///
/// Insert uses delta updates on the common (no-rotation) path for zero
/// extra Table reads. Rotations and removes use recompute_agg which
/// reads children to rebuild aggregates from scratch.
module deepbook_predict::treap;

use deepbook::math;
use deepbook_predict::oracle::CurvePoint;
use sui::{bcs, hash::blake2b256, table::{Self, Table}};

// === Errors ===

const ENodeNotFound: u64 = 0;
const EInsufficientQuantity: u64 = 1;

// === Structs ===

/// Treap root container.
public struct Treap has store {
    root: Option<u64>,
    nodes: Table<u64, Node>,
    size: u64,
    /// Cached mark-to-market liability for this oracle's positions
    mtm: u64,
}

/// A single treap node, keyed by strike.
public struct Node has copy, drop, store {
    // Treap structure
    priority: u64,
    left: Option<u64>,
    right: Option<u64>,
    // Position data at this exact strike
    q_up: u64,
    q_dn: u64,
    // Subtree aggregates for Barnes-Hut evaluation
    // agg_qk stores Σ(q_i * strike_i / FLOAT_SCALING) to fit in u64
    agg_q_up: u64,
    agg_qk_up: u64,
    agg_q_dn: u64,
    agg_qk_dn: u64,
    // Subtree strike range for curve intersection checks
    sub_min: u64,
    sub_max: u64,
    // Worst-case payout for this subtree at any settlement price
    max_payout: u64,
}

// === Public-Package API ===

/// Create an empty treap.
public(package) fun new(ctx: &mut TxContext): Treap {
    Treap {
        root: option::none(),
        nodes: table::new(ctx),
        size: 0,
        mtm: 0,
    }
}

/// Get cached mark-to-market liability.
public(package) fun mtm(self: &Treap): u64 {
    self.mtm
}

/// Set cached mark-to-market liability.
public(package) fun set_mtm(self: &mut Treap, value: u64) {
    self.mtm = value;
}

/// Insert a position into the treap.
public(package) fun insert(self: &mut Treap, strike: u64, qty: u64, is_up: bool) {
    let is_new = !self.nodes.contains(strike);
    let new_root = insert_at(&mut self.nodes, self.root, strike, qty, is_up);
    self.root = option::some(new_root);
    if (is_new) self.size = self.size + 1;
}

/// Remove quantity from a position. Removes the node entirely if both
/// q_up and q_dn reach zero.
public(package) fun remove(self: &mut Treap, strike: u64, qty: u64, is_up: bool) {
    let had_node = self.nodes.contains(strike);
    let new_root = remove_at(&mut self.nodes, self.root, strike, qty, is_up);
    self.root = new_root;
    if (had_node && !self.nodes.contains(strike)) self.size = self.size - 1;
}

/// Evaluate total portfolio value against a piecewise-linear pricing curve.
/// Co-iterates the in-order tree traversal with a forward cursor through the
/// sorted curve. Descends only where the curve has interior sample points;
/// uses aggregates elsewhere. O(V + C) where V = visited nodes, C = curve length.
public(package) fun evaluate(self: &Treap, curve: &vector<CurvePoint>): u64 {
    if (self.root.is_none() || curve.is_empty()) return 0;
    let (value, _) = eval_inorder(&self.nodes, *self.root.borrow(), curve, 0);
    value
}

/// Number of unique strikes in the treap.
public(package) fun size(self: &Treap): u64 {
    self.size
}

/// Returns (min_strike, max_strike) across all positions, or (0, 0) if empty.
public(package) fun strike_range(self: &Treap): (u64, u64) {
    if (self.root.is_none()) return (0, 0);
    let root = self.nodes[*self.root.borrow()];
    (root.sub_min, root.sub_max)
}

/// Worst-case payout across all settlement prices.
public(package) fun max_payout(self: &Treap): u64 {
    if (self.root.is_none()) return 0;
    self.nodes[*self.root.borrow()].max_payout
}

/// Whether the treap has no positions.
public(package) fun is_empty(self: &Treap): bool {
    self.root.is_none()
}

// === Private: Insert ===

/// Recursive insert. Returns new subtree root strike.
fun insert_at(
    nodes: &mut Table<u64, Node>,
    root: Option<u64>,
    strike: u64,
    qty: u64,
    is_up: bool,
): u64 {
    if (root.is_none()) {
        nodes.add(strike, new_leaf(strike, qty, is_up));
        return strike
    };

    let root_strike = *root.borrow();

    if (strike == root_strike) {
        let n = &mut nodes[root_strike];
        if (is_up) { n.q_up = n.q_up + qty } else { n.q_dn = n.q_dn + qty };
        recompute_agg(nodes, root_strike);
        return root_strike
    };

    let node = nodes[root_strike];

    if (strike < root_strike) {
        let new_child = insert_at(nodes, node.left, strike, qty, is_up);
        if (nodes[new_child].priority > node.priority) {
            return rotate_right(nodes, root_strike, new_child)
        };
        nodes[root_strike].left = option::some(new_child);
    } else {
        let new_child = insert_at(nodes, node.right, strike, qty, is_up);
        if (nodes[new_child].priority > node.priority) {
            return rotate_left(nodes, root_strike, new_child)
        };
        nodes[root_strike].right = option::some(new_child);
    };

    recompute_agg(nodes, root_strike);
    root_strike
}

// === Private: Remove ===

/// Recursive remove. Returns new subtree root, or none if empty.
fun remove_at(
    nodes: &mut Table<u64, Node>,
    root: Option<u64>,
    strike: u64,
    qty: u64,
    is_up: bool,
): Option<u64> {
    assert!(root.is_some(), ENodeNotFound);
    let root_strike = *root.borrow();
    let node = nodes[root_strike];

    if (strike == root_strike) {
        if (is_up) { assert!(node.q_up >= qty, EInsufficientQuantity) } else {
            assert!(node.q_dn >= qty, EInsufficientQuantity)
        };

        let new_q_up = if (is_up) { node.q_up - qty } else { node.q_up };
        let new_q_dn = if (!is_up) { node.q_dn - qty } else { node.q_dn };
        if (new_q_up == 0 && new_q_dn == 0) return remove_node(nodes, root_strike);

        let n = &mut nodes[root_strike];
        if (is_up) { n.q_up = n.q_up - qty } else { n.q_dn = n.q_dn - qty };
        recompute_agg(nodes, root_strike);
        return option::some(root_strike)
    };

    if (strike < root_strike) {
        let new_left = remove_at(nodes, node.left, strike, qty, is_up);
        nodes[root_strike].left = new_left;
    } else {
        let new_right = remove_at(nodes, node.right, strike, qty, is_up);
        nodes[root_strike].right = new_right;
    };

    recompute_agg(nodes, root_strike);
    option::some(root_strike)
}

/// Remove a node with no position quantity by rotating it down until it's a leaf.
fun remove_node(nodes: &mut Table<u64, Node>, strike: u64): Option<u64> {
    let node = nodes[strike];
    let has_left = node.left.is_some();
    let has_right = node.right.is_some();

    if (!has_left && !has_right) {
        nodes.remove(strike);
        return option::none()
    };

    // Promote the higher-priority child
    let promote_left = if (has_left && has_right) {
        nodes[*node.left.borrow()].priority > nodes[*node.right.borrow()].priority
    } else {
        has_left
    };

    if (promote_left) {
        let left_strike = *node.left.borrow();
        let left_node = nodes[left_strike];
        // Right rotation: push strike down
        nodes[strike].left = left_node.right;
        let new_right = remove_node(nodes, strike);
        nodes[left_strike].right = new_right;
        recompute_agg(nodes, left_strike);
        option::some(left_strike)
    } else {
        let right_strike = *node.right.borrow();
        let right_node = nodes[right_strike];
        // Left rotation: push strike down
        nodes[strike].right = right_node.left;
        let new_left = remove_node(nodes, strike);
        nodes[right_strike].left = new_left;
        recompute_agg(nodes, right_strike);
        option::some(right_strike)
    }
}

// === Private: Rotations ===

///       root              left
///      /    \            /    \
///    left    C   →      A    root
///   /    \                  /    \
///  A      B                B      C
fun rotate_right(nodes: &mut Table<u64, Node>, root_strike: u64, left_strike: u64): u64 {
    let left_node = nodes[left_strike];
    // root.left = B, left.right = root
    nodes[root_strike].left = left_node.right;
    recompute_agg(nodes, root_strike);
    nodes[left_strike].right = option::some(root_strike);
    recompute_agg(nodes, left_strike);
    left_strike
}

///     root              right
///    /    \            /     \
///   A    right   →   root     C
///       /    \      /    \
///      B      C    A      B
fun rotate_left(nodes: &mut Table<u64, Node>, root_strike: u64, right_strike: u64): u64 {
    let right_node = nodes[right_strike];
    // root.right = B, right.left = root
    nodes[root_strike].right = right_node.left;
    recompute_agg(nodes, root_strike);
    nodes[right_strike].left = option::some(root_strike);
    recompute_agg(nodes, right_strike);
    right_strike
}

// === Private: Aggregates ===

/// Recompute a node's aggregate fields from its children.
fun recompute_agg(nodes: &mut Table<u64, Node>, strike: u64) {
    let node = nodes[strike];
    let n = &mut nodes[strike];
    n.agg_q_up = node.q_up;
    n.agg_qk_up = math::mul(node.q_up, strike);
    n.agg_q_dn = node.q_dn;
    n.agg_qk_dn = math::mul(node.q_dn, strike);
    n.sub_min = strike;
    n.sub_max = strike;

    let mut left_agg_q_up = 0;
    let mut left_max_payout = 0;
    let mut right_agg_q_dn = 0;
    let mut right_max_payout = 0;

    if (node.left.is_some()) {
        let left = nodes[*node.left.borrow()];
        left_agg_q_up = left.agg_q_up;
        left_max_payout = left.max_payout;
        add_aggs(&mut nodes[strike], &left);
    };
    if (node.right.is_some()) {
        let right = nodes[*node.right.borrow()];
        right_agg_q_dn = right.agg_q_dn;
        right_max_payout = right.max_payout;
        add_aggs(&mut nodes[strike], &right);
    };

    nodes[strike].max_payout = (left_max_payout + node.q_dn + right_agg_q_dn)
        .max(left_agg_q_up + node.q_up + right_max_payout);
}

/// Add b's aggregate values to a.
fun add_aggs(a: &mut Node, b: &Node) {
    a.agg_q_up = a.agg_q_up + b.agg_q_up;
    a.agg_qk_up = a.agg_qk_up + b.agg_qk_up;
    a.agg_q_dn = a.agg_q_dn + b.agg_q_dn;
    a.agg_qk_dn = a.agg_qk_dn + b.agg_qk_dn;
    a.sub_min = a.sub_min.min(b.sub_min);
    a.sub_max = a.sub_max.max(b.sub_max);
}

// === Private: Evaluation ===

/// In-order co-iteration of the treap with a forward cursor through the
/// sorted curve. Returns (subtree value, updated cursor).
/// Cursor invariant: index of the first curve point with strike > last processed strike.
fun eval_inorder(
    nodes: &Table<u64, Node>,
    strike: u64,
    curve: &vector<CurvePoint>,
    mut cursor: u64,
): (u64, u64) {
    let node = nodes[strike];
    let len = curve.length();

    if (node.agg_q_up == 0 && node.agg_q_dn == 0) return (0, cursor);

    // Advance cursor to first curve point strictly after sub_min
    while (cursor < len && curve[cursor].strike() <= node.sub_min) {
        cursor = cursor + 1;
    };

    // No curve points strictly inside (sub_min, sub_max) → aggregate
    let has_interior =
        node.sub_min < node.sub_max
        && cursor < len
        && curve[cursor].strike() < node.sub_max;

    if (!has_interior) {
        let mut value = 0u64;
        if (node.agg_q_up > 0) {
            let k_avg = math::div(node.agg_qk_up, node.agg_q_up);
            value = value + math::mul(node.agg_q_up, interp_at(curve, cursor, k_avg, true));
        };
        if (node.agg_q_dn > 0) {
            let k_avg = math::div(node.agg_qk_dn, node.agg_q_dn);
            value = value + math::mul(node.agg_q_dn, interp_at(curve, cursor, k_avg, false));
        };
        // Advance cursor past this subtree
        while (cursor < len && curve[cursor].strike() <= node.sub_max) {
            cursor = cursor + 1;
        };
        return (value, cursor)
    };

    // Curve has structure here — descend
    let mut value = 0u64;

    if (node.left.is_some()) {
        let (v, c) = eval_inorder(nodes, *node.left.borrow(), curve, cursor);
        value = value + v;
        cursor = c;
    };

    // Advance cursor for this node's strike
    while (cursor < len && curve[cursor].strike() <= strike) {
        cursor = cursor + 1;
    };

    if (node.q_up > 0) {
        value = value + math::mul(node.q_up, interp_at(curve, cursor, strike, true));
    };
    if (node.q_dn > 0) {
        value = value + math::mul(node.q_dn, interp_at(curve, cursor, strike, false));
    };

    if (node.right.is_some()) {
        let (v, c) = eval_inorder(nodes, *node.right.borrow(), curve, cursor);
        value = value + v;
        cursor = c;
    };

    (value, cursor)
}

/// O(1) interpolation using cursor position.
/// Cursor = index of first curve point with strike > the query strike.
fun interp_at(curve: &vector<CurvePoint>, cursor: u64, strike: u64, is_up: bool): u64 {
    let len = curve.length();

    // Clamp to edges
    if (cursor == 0) {
        return if (is_up) { curve[0].up_price() } else { curve[0].dn_price() }
    };
    if (cursor >= len) {
        return if (is_up) { curve[len - 1].up_price() } else { curve[len - 1].dn_price() }
    };

    let k_lo = curve[cursor - 1].strike();
    let k_hi = curve[cursor].strike();
    let p_lo = if (is_up) { curve[cursor - 1].up_price() } else { curve[cursor - 1].dn_price() };
    let p_hi = if (is_up) { curve[cursor].up_price() } else { curve[cursor].dn_price() };

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

// === Private: Helpers ===

/// Derive treap priority from strike via hash.
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

fun new_leaf(strike: u64, qty: u64, is_up: bool): Node {
    let (q_up, q_dn) = if (is_up) { (qty, 0u64) } else { (0u64, qty) };

    Node {
        priority: strike_priority(strike),
        left: option::none(),
        right: option::none(),
        q_up,
        q_dn,
        agg_q_up: q_up,
        agg_qk_up: math::mul(q_up, strike),
        agg_q_dn: q_dn,
        agg_qk_dn: math::mul(q_dn, strike),
        sub_min: strike,
        sub_max: strike,
        max_payout: q_up.max(q_dn),
    }
}
