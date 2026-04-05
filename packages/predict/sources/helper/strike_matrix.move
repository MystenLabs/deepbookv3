module deepbook_predict::strike_matrix;

use deepbook::{constants::max_u64, math};
use deepbook_predict::oracle::CurvePoint;
use sui::table::{Self, Table};

const PAGE_SLOTS: u64 = 512;
const ENonMonotoneCurve: u64 = 0;

public struct StrikeMatrix has store {
    pages: Table<u64, vector<Node>>,
    tick_size: u64,
    min_strike: u64,
    minted_min_strike: u64,
    minted_max_strike: u64,
    total_q_up: u64,
    total_q_dn: u64,
    mtm: u64,
}

public struct Node has copy, drop, store {
    agg_q_up: u64,
    agg_qk_up: u64,
    agg_q_dn: u64,
    agg_qk_dn: u64,
}

// === Public-Package API ===

/// Allocates the full page table for the oracle's strike grid and zeros all cached state.
public(package) fun new(
    ctx: &mut TxContext,
    tick_size: u64,
    min_strike: u64,
    max_strike: u64,
): StrikeMatrix {
    let mut pages = table::new(ctx);
    let last_tick_index = (max_strike - min_strike) / tick_size;
    let last_page_key = last_tick_index / PAGE_SLOTS;
    let mut page_key = 0;
    while (page_key <= last_page_key) {
        pages.add(page_key, empty_page());
        page_key = page_key + 1;
    };

    StrikeMatrix {
        pages,
        tick_size,
        min_strike,
        minted_min_strike: max_u64(),
        minted_max_strike: 0,
        total_q_up: 0,
        total_q_dn: 0,
        mtm: 0,
    }
}

/// Adds one position by updating the owning page's directional aggregates.
/// UP positions propagate to the right; DN positions propagate to the left.
public(package) fun insert(self: &mut StrikeMatrix, strike: u64, qty: u64, is_up: bool) {
    let qk = math::mul(qty, strike);
    self.minted_min_strike = self.minted_min_strike.min(strike);
    self.minted_max_strike = self.minted_max_strike.max(strike);
    if (is_up) {
        self.total_q_up = self.total_q_up + qty;
    } else {
        self.total_q_dn = self.total_q_dn + qty;
    };

    let (page_key, slot) = self.strike_to_coords(strike);
    self.apply_position_delta(page_key, slot, qty, qk, is_up, true);
}

/// Removes one position by reversing the directional aggregate updates from `insert`.
public(package) fun remove(self: &mut StrikeMatrix, strike: u64, qty: u64, is_up: bool) {
    let qk = math::mul(qty, strike);
    if (is_up) {
        self.total_q_up = self.total_q_up - qty;
    } else {
        self.total_q_dn = self.total_q_dn - qty;
    };
    let (page_key, slot) = self.strike_to_coords(strike);
    self.apply_position_delta(page_key, slot, qty, qk, is_up, false);
}

/// Marks the live book against a sampled oracle curve by valuing quantities between
/// adjacent curve points at their strike-weighted average price.
public(package) fun evaluate(self: &StrikeMatrix, curve: &vector<CurvePoint>): u64 {
    let len = curve.length();
    if (len == 0) return 0;
    let mut value = self.evaluate_curve_endpoints(curve);
    let (mut page_lo, mut slot_lo) = self.strike_to_coords(curve[0].strike());

    let mut ci = 1;
    while (ci < len) {
        let ci_strike = curve[ci].strike();
        let ci_strike_prev = curve[ci-1].strike();
        let ci_up_price = curve[ci].up_price();
        let ci_dn_price = curve[ci].dn_price();
        let ci_up_price_prev = curve[ci-1].up_price();
        let ci_dn_price_prev = curve[ci-1].dn_price();
        let (page_hi, slot_hi) = self.strike_to_coords(ci_strike);
        let (q_up_delta, qk_up_delta) = self.segment_qty_qk(
            page_lo,
            slot_lo,
            page_hi,
            slot_hi,
            true,
        );
        let (q_dn_delta, qk_dn_delta) = self.segment_qty_qk(
            page_lo,
            slot_lo,
            page_hi,
            slot_hi,
            false,
        );

        value =
            value + self.segment_value(
            q_up_delta,
            qk_up_delta,
            ci_strike_prev,
            ci_strike,
            ci_up_price_prev,
            ci_up_price,
            true,
        );
        value =
            value + self.segment_value(
            q_dn_delta,
            qk_dn_delta,
            ci_strike_prev,
            ci_strike,
            ci_dn_price_prev,
            ci_dn_price,
            false,
        );

        page_lo = page_hi;
        slot_lo = slot_hi;
        ci = ci + 1;
    };

    value
}

/// Computes final settled payout by summing winning UP strikes below settlement and
/// winning DN strikes at or above settlement.
public(package) fun evaluate_settled(self: &StrikeMatrix, settlement: u64): u64 {
    if (self.minted_max_strike < self.minted_min_strike) return 0;

    let (min_page, min_slot) = self.strike_to_coords(self.minted_min_strike);
    let (max_page, max_slot) = self.strike_to_coords(self.minted_max_strike);
    let mut value = 0u64;
    let mut page_key = min_page;
    while (true) {
        let page = &self.pages[page_key];
        let start_slot = if (page_key == min_page) { min_slot } else { 0 };
        let end_slot = if (page_key == max_page) {
            max_slot
        } else {
            PAGE_SLOTS - 1
        };
        let mut slot = start_slot;
        while (true) {
            let strike = self.strike_from_coords(page_key, slot);
            if (strike < settlement) {
                value = value + self.node_q(page, slot, true);
            } else {
                value = value + self.node_q(page, slot, false);
            };

            if (slot == end_slot) break;
            slot = slot + 1;
        };

        if (page_key == max_page) break;
        page_key = page_key + 1;
    };

    value
}

/// Returns the cached mark-to-market value last written by vault risk refresh.
public(package) fun mtm(self: &StrikeMatrix): u64 {
    self.mtm
}

/// Stores the latest mark-to-market value for this oracle's book.
public(package) fun set_mtm(self: &mut StrikeMatrix, value: u64) {
    self.mtm = value;
}

/// Conservative upper bound on worst-case settlement payout.
/// This intentionally overestimates mutually exclusive books until exact
/// max-payout tracking is reinstated.
public(package) fun max_payout(self: &StrikeMatrix): u64 {
    self.total_q_up + self.total_q_dn
}

/// Reports whether any live UP or DN quantity remains in the matrix.
public(package) fun has_live_positions(self: &StrikeMatrix): bool {
    self.total_q_up > 0 || self.total_q_dn > 0
}

/// Returns the historical min/max strikes touched by the book.
public(package) fun minted_strike_range(self: &StrikeMatrix): (u64, u64) {
    (self.minted_min_strike, self.minted_max_strike)
}

// === Private Helpers ===

/// Prices the exact first UP point and exact last DN point that are excluded from the
/// segment interpolation loop.
fun evaluate_curve_endpoints(self: &StrikeMatrix, curve: &vector<CurvePoint>): u64 {
    let len = curve.length();
    let (page_lo, slot_lo) = self.strike_to_coords(curve[0].strike());
    let (page_hi, slot_hi) = self.strike_to_coords(curve[len-1].strike());
    let page = &self.pages[page_lo];
    let mut value = math::mul(self.node_q(page, slot_lo, true), curve[0].up_price());
    let page = &self.pages[page_hi];
    value = value + math::mul(self.node_q(page, slot_hi, false), curve[len-1].dn_price());
    value
}

/// Returns the interior inventory for one curve segment.
/// UP uses `(left, right]`; DN uses `[left, right)`.
fun segment_qty_qk(
    self: &StrikeMatrix,
    page_lo: u64,
    slot_lo: u64,
    page_hi: u64,
    slot_hi: u64,
    is_up: bool,
): (u64, u64) {
    let same_coord = page_lo == page_hi && slot_lo == slot_hi;
    if (same_coord) return (0, 0);

    let (range_start_page, range_start_slot, range_end_page, range_end_slot) = if (is_up) {
        let (next_page, next_slot) = next_coord(page_lo, slot_lo);
        (next_page, next_slot, page_hi, slot_hi)
    } else {
        let (prev_page, prev_slot) = prev_coord(page_hi, slot_hi);
        (page_lo, slot_lo, prev_page, prev_slot)
    };

    if (!coords_leq(range_start_page, range_start_slot, range_end_page, range_end_slot)) {
        return (0, 0)
    };

    self.range_qty_qk(
        range_start_page,
        range_start_slot,
        range_end_page,
        range_end_slot,
        is_up,
    )
}

/// Applies one position delta to the page-local aggregates. UP walks rightward on the
/// normal axis; DN walks leftward because its winner-oriented prefix axis is mirrored.
fun apply_position_delta(
    self: &mut StrikeMatrix,
    page_key: u64,
    slot: u64,
    qty: u64,
    qk: u64,
    is_up: bool,
    add: bool,
) {
    let page = &mut self.pages[page_key];
    let mut i = slot;
    while (true) {
        let n = &mut page[i];
        if (is_up) {
            if (add) {
                n.agg_q_up = n.agg_q_up + qty;
                n.agg_qk_up = n.agg_qk_up + qk;
            } else {
                n.agg_q_up = n.agg_q_up - qty;
                n.agg_qk_up = n.agg_qk_up - qk;
            };
            i = i + 1;
            if (i == PAGE_SLOTS) break;
        } else {
            if (add) {
                n.agg_q_dn = n.agg_q_dn + qty;
                n.agg_qk_dn = n.agg_qk_dn + qk;
            } else {
                n.agg_q_dn = n.agg_q_dn - qty;
                n.agg_qk_dn = n.agg_qk_dn - qk;
            };
            if (i == 0) break;
            i = i - 1;
        };
    };
}

/// Maps an aligned strike into its page key and slot within that page.
fun strike_to_coords(self: &StrikeMatrix, strike: u64): (u64, u64) {
    let tick_index = (strike - self.min_strike) / self.tick_size;
    let page_key = tick_index / PAGE_SLOTS;
    let slot = tick_index % PAGE_SLOTS;
    (page_key, slot)
}

/// Converts a page key and slot back into the aligned strike value.
fun strike_from_coords(self: &StrikeMatrix, page_key: u64, slot: u64): u64 {
    self.min_strike + (page_key * PAGE_SLOTS + slot) * self.tick_size
}

/// Returns the next slot on the normal strike axis, rolling into the next page when needed.
fun next_coord(page_key: u64, slot: u64): (u64, u64) {
    if (slot + 1 == PAGE_SLOTS) {
        (page_key + 1, 0)
    } else {
        (page_key, slot + 1)
    }
}

/// Returns the previous slot on the normal strike axis, rolling into the prior page when needed.
fun prev_coord(page_key: u64, slot: u64): (u64, u64) {
    if (slot == 0) {
        (page_key - 1, PAGE_SLOTS - 1)
    } else {
        (page_key, slot - 1)
    }
}

/// Compares two matrix coordinates on the normal strike axis.
fun coords_leq(page_lo: u64, slot_lo: u64, page_hi: u64, slot_hi: u64): bool {
    page_lo < page_hi || (page_lo == page_hi && slot_lo <= slot_hi)
}

/// Maps a normal slot into the winner-oriented prefix axis: normal for UP, mirrored for DN.
fun axis_slot(slot: u64, is_up: bool): u64 {
    if (is_up) slot else PAGE_SLOTS - 1 - slot
}

/// Maps a winner-oriented prefix slot back into the page's normal slot coordinates.
fun slot_from_axis(axis_slot: u64, is_up: bool): u64 {
    if (is_up) axis_slot else PAGE_SLOTS - 1 - axis_slot
}

/// Reads the prefix quantity at one winner-oriented axis slot.
fun prefix_q(page: &vector<Node>, axis_slot: u64, is_up: bool): u64 {
    let slot = slot_from_axis(axis_slot, is_up);
    if (is_up) page[slot].agg_q_up else page[slot].agg_q_dn
}

/// Reads the prefix strike-weighted quantity at one winner-oriented axis slot.
fun prefix_qk(page: &vector<Node>, axis_slot: u64, is_up: bool): u64 {
    let slot = slot_from_axis(axis_slot, is_up);
    if (is_up) page[slot].agg_qk_up else page[slot].agg_qk_dn
}

/// Returns the inclusive prefix delta between two winner-oriented axis slots.
fun prefix_delta(page: &vector<Node>, axis_lo: u64, axis_hi: u64, is_up: bool): (u64, u64) {
    let mut qty = prefix_q(page, axis_hi, is_up);
    let mut qk = prefix_qk(page, axis_hi, is_up);
    if (axis_lo > 0) {
        qty = qty - prefix_q(page, axis_lo - 1, is_up);
        qk = qk - prefix_qk(page, axis_lo - 1, is_up);
    };
    (qty, qk)
}

/// Sums an inclusive slot range within one page using the same prefix-difference logic
/// for both UP and DN. DN works on a mirrored winner-oriented axis.
fun page_range_qty_qk(
    self: &StrikeMatrix,
    page: &vector<Node>,
    start_slot: u64,
    end_slot: u64,
    is_up: bool,
): (u64, u64) {
    let start_axis = axis_slot(start_slot, is_up);
    let end_axis = axis_slot(end_slot, is_up);
    let axis_lo = start_axis.min(end_axis);
    let axis_hi = start_axis.max(end_axis);
    prefix_delta(page, axis_lo, axis_hi, is_up)
}

/// Sums an inclusive strike range that may span multiple pages.
fun range_qty_qk(
    self: &StrikeMatrix,
    start_page: u64,
    start_slot: u64,
    end_page: u64,
    end_slot: u64,
    is_up: bool,
): (u64, u64) {
    let mut qty = 0;
    let mut qk = 0;
    let mut page_key = start_page;
    while (true) {
        let page = &self.pages[page_key];
        let page_start = if (page_key == start_page) { start_slot } else { 0 };
        let page_end = if (page_key == end_page) {
            end_slot
        } else {
            PAGE_SLOTS - 1
        };
        let (page_qty, page_qk) = self.page_range_qty_qk(page, page_start, page_end, is_up);
        qty = qty + page_qty;
        qk = qk + page_qk;

        if (page_key == end_page) break;
        page_key = page_key + 1;
    };

    (qty, qk)
}

/// Recovers the exact quantity at one slot from the winner-oriented prefix aggregates.
fun node_q(self: &StrikeMatrix, page: &vector<Node>, slot: u64, is_up: bool): u64 {
    let axis_slot = axis_slot(slot, is_up);
    let (qty, _) = prefix_delta(page, axis_slot, axis_slot, is_up);
    qty
}

/// Values one segment's quantity at the price implied by its strike-weighted average.
fun segment_value(
    _self: &StrikeMatrix,
    qty: u64,
    qk: u64,
    start_strike: u64,
    end_strike: u64,
    start_price: u64,
    end_price: u64,
    price_descends: bool,
): u64 {
    if (qty == 0) return 0;

    let k_avg = math::div(qk, qty);
    let ratio = math::div((k_avg - start_strike), (end_strike - start_strike));
    let avg_price = if (price_descends) {
        assert!(start_price >= end_price, ENonMonotoneCurve);
        start_price - math::mul(start_price - end_price, ratio)
    } else {
        assert!(end_price >= start_price, ENonMonotoneCurve);
        start_price + math::mul(end_price - start_price, ratio)
    };

    math::mul(qty, avg_price)
}

/// Builds one zeroed page with `PAGE_SLOTS` empty nodes.
fun empty_page(): vector<Node> {
    let empty = Node {
        agg_q_up: 0,
        agg_qk_up: 0,
        agg_q_dn: 0,
        agg_qk_dn: 0,
    };
    vector::tabulate!(PAGE_SLOTS, |_| empty)
}
