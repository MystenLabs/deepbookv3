// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Sparse strike exposure index for payout-liability accounting.
///
/// The index keys finite interval boundaries by absolute tick, matching the tick
/// pair packed into the durable order ID. Raw strikes are recovered only at the
/// pricing/settlement boundary, where callers pass the owning market's `tick_size`
/// (`raw_strike = tick * tick_size`); the index stores no grid geometry.
///
/// Records live in a tick-sorted vector on the market object. A full read, a
/// range peak, and a settlement prefix therefore load no dynamic-field children.
/// That removes the C-1 object-cache wall from `walk_linear`: the previous AVL
/// table stored one child per distinct strike, and a pool flush aborted once the
/// cached-child count reached 1,000.
///
/// Each order's quantity is also its settled payout: a winning order pays its
/// full quantity. Live cash backing is the max-point payout plus a buffer over
/// the disjoint-book gap; the index's max-point term is the floor anchor of that
/// enforced reserve. The per-boundary underflow in `apply_net_delta` is the
/// authority for a caller/index desync.
module deepbook_predict::strike_payout_tree;

use deepbook_predict::{constants, pricing::Pricer, range_codec};
use fixed_math::math;

const EInsufficientPayoutQuantity: u64 = 0;
const EMaxPayoutTreeNodes: u64 = 1;
const ENonMonotonePrice: u64 = 2;

/// Sparse payout-liability index keyed by finite strike tick.
public struct StrikePayoutTree has store {
    /// Finite boundaries in strictly ascending tick order. Empty records are
    /// removed, so every slot is a live edge.
    records: vector<PayoutRecord>,
    /// Occupied finite boundaries. Kept beside the vector so tests can seed the
    /// admission cap without inserting a thousand records.
    node_count: u64,
    /// Aggregate order quantity over the open-lower prefix, which is also its
    /// aggregate settled payout.
    base: u64,
}

/// One finite boundary's start and end quantities.
public struct PayoutRecord has copy, drop, store {
    tick: u64,
    local_start: u64,
    local_end: u64,
}

/// Return `(max_payout, total_payout)` for pre-settlement reserve math.
public(package) fun payout_reserve_terms(tree: &StrikePayoutTree): (u64, u64) {
    let mut running = tree.base;
    let mut max_payout = tree.base;
    let mut total_payout = tree.base;
    let mut index = 0;
    while (index < tree.records.length()) {
        let record = &tree.records[index];
        apply_net_delta(&mut running, record.local_start, true);
        apply_net_delta(&mut running, record.local_end, false);
        if (running > max_payout) max_payout = running;
        total_payout = total_payout + record.local_start;
        index = index + 1;
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
    // sentinel and lives in `base`, not in the record list.
    let prefix_at_lower = tree.settlement_prefix_payout(lower_tick + 1);
    // The window is a subsequence and can open on an end edge of a range that
    // started at or before `lower`. Track start and end totals separately and
    // saturate, matching the old subtree-summary algebra.
    let mut start_total = 0;
    let mut end_total = 0;
    let mut max_gain = 0;
    let mut index = 0;
    while (index < tree.records.length()) {
        let record = &tree.records[index];
        if (record.tick >= higher_tick) break;
        if (record.tick > lower_tick) {
            start_total = start_total + record.local_start;
            end_total = end_total + record.local_end;
            let gain = start_total.saturating_sub(end_total);
            if (gain > max_gain) max_gain = gain;
        };
        index = index + 1;
    };
    prefix_at_lower + max_gain
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
    tree.settlement_prefix_payout(range_codec::prefix_limit_tick(settlement, tick_size))
}

/// Value the quantity-weighted linear liability by pricing each distinct boundary
/// once.
///
/// The start and end sides accumulate as two non-negative totals: a record's net
/// `local_start - local_end` quantity is signed, so a single running `u64` would
/// underflow mid-walk. They combine once at the top:
/// `base + start_total - end_total`. `tree.base` is the `P(-inf) = 1`
/// anchor for `(-inf, h]` ranges (its quantity enters at face value); `+inf` ends
/// are never stored (`P = 0`).
public(package) fun walk_linear(tree: &StrikePayoutTree, pricer: &Pricer, tick_size: u64): u64 {
    let mut previous_price = option::none();
    let mut start_total = 0;
    let mut end_total = 0;
    let mut index = 0;
    while (index < tree.records.length()) {
        let record = &tree.records[index];
        let price = pricer.up_price(range_codec::strike_from_tick(record.tick, tick_size));
        // UP price is non-increasing in strike and the walk visits ascending
        // ticks, so a rising price is a non-monotone surface: the netted aggregate
        // below would understate the per-order liability the protocol actually honors.
        if (previous_price.is_some()) {
            assert!(price <= *previous_price.borrow(), ENonMonotonePrice);
        };
        previous_price = option::some(price);

        // EVERY record is priced, including one whose local start and end
        // quantities cancel. Only the arithmetic is skipped there, because such a
        // boundary contributes `price * q - price * q = 0` to the netted aggregate
        // at any price. The pricing call itself is where monotonicity is observed,
        // and a cancelling boundary is still the shared edge of two live orders.
        if (record.local_start != record.local_end) {
            start_total = start_total + math::mul_down(price, record.local_start);
            end_total = end_total + math::mul_down(price, record.local_end);
        };
        index = index + 1;
    };
    // Boundary products are rounded per record and the signed aggregate is floored
    // once. This can differ from pricing and flooring each order independently.
    (tree.base + start_total).saturating_sub(end_total)
}

/// Create an empty sparse payout index.
public(package) fun new(_ctx: &mut TxContext): StrikePayoutTree {
    StrikePayoutTree {
        records: vector[],
        node_count: 0,
        base: 0,
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
    if (lower_tick != 0 && !tree.contains_tick(lower_tick)) {
        new_nodes = new_nodes + 1;
    };
    if (
        higher_tick != constants::pos_inf_tick!()
            && higher_tick != lower_tick
            && !tree.contains_tick(higher_tick)
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

fun apply_range(
    tree: &mut StrikePayoutTree,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    add: bool,
) {
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
    let (found, index) = tree.find_record(tick);
    if (found) {
        let record = &mut tree.records[index];
        if (is_start) {
            apply_net_delta(&mut record.local_start, quantity, add);
        } else {
            apply_net_delta(&mut record.local_end, quantity, add);
        };
        if (record.local_start == 0 && record.local_end == 0) {
            tree.records.remove(index);
            tree.node_count = tree.node_count - 1;
        };
        return
    };

    assert!(add, EInsufficientPayoutQuantity);
    let (local_start, local_end) = if (is_start) {
        (quantity, 0)
    } else {
        (0, quantity)
    };
    tree.records.insert(PayoutRecord { tick, local_start, local_end }, index);
    tree.node_count = tree.node_count + 1;
}

/// A boundary is active in the prefix iff `tick < limit_tick`
/// (`tick * tick_size < settlement`).
fun settlement_prefix_payout(tree: &StrikePayoutTree, limit_tick: u64): u64 {
    let mut running = tree.base;
    let mut index = 0;
    while (index < tree.records.length()) {
        let record = &tree.records[index];
        if (record.tick >= limit_tick) break;
        apply_net_delta(&mut running, record.local_start, true);
        apply_net_delta(&mut running, record.local_end, false);
        index = index + 1;
    };
    running
}

fun contains_tick(tree: &StrikePayoutTree, tick: u64): bool {
    let (found, _) = tree.find_record(tick);
    found
}

/// Binary search. Returns `(true, index)` when `tick` is present, otherwise
/// `(false, insertion_index)` so a new record stays sorted.
fun find_record(tree: &StrikePayoutTree, tick: u64): (bool, u64) {
    let mut lo = 0;
    let mut hi = tree.records.length();
    while (lo < hi) {
        let mid = lo + (hi - lo) / 2;
        let mid_tick = tree.records[mid].tick;
        if (mid_tick == tick) return (true, mid);
        if (mid_tick < tick) {
            lo = mid + 1;
        } else {
            hi = mid;
        };
    };
    (false, lo)
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
/// Assert the list invariant: strictly ascending ticks, no empty records, and
/// `node_count` equal to the live record count. Returns that count.
public(package) fun assert_tree_invariant_for_testing(tree: &StrikePayoutTree): u64 {
    let mut previous_tick = option::none();
    let mut index = 0;
    while (index < tree.records.length()) {
        let record = &tree.records[index];
        assert!(record.local_start > 0 || record.local_end > 0);
        if (previous_tick.is_some()) {
            assert!(record.tick > *previous_tick.borrow());
        };
        previous_tick = option::some(record.tick);
        index = index + 1;
    };
    assert!(tree.node_count == tree.records.length());
    tree.records.length()
}
