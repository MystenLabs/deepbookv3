// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Strike-matrix aggregate store for dense, fixed-grid oracle books.
///
/// The matrix eagerly allocates one page per strike-grid segment and stores
/// winner-oriented prefix aggregates for UP and DN positions. Live valuation
/// walks a sampled oracle curve and values the inventory between curve points
/// at the price implied by the segment's strike-weighted average.
module deepbook_predict::strike_matrix;

use deepbook::{constants::max_u64, math};
use deepbook_predict::oracle_config::CurvePoint;
use sui::table::{Self, Table};

const PAGE_SLOTS: u64 = 512;
const ENonMonotoneCurve: u64 = 0;
const EInvalidCurveRange: u64 = 1;

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
    assert!(
        curve[0].strike() <= self.minted_min_strike
        && curve[len - 1].strike() >= self.minted_max_strike,
        EInvalidCurveRange,
    );
    let mut value = 0;
    let (mut page_lo, mut slot_lo) = self.strike_to_coords(curve[0].strike());
    let (mut page_hi, mut slot_hi) = self.strike_to_coords(curve[len - 1].strike());

    let page = &self.pages[page_lo];
    value = value + math::mul(node_q_up(page, slot_lo), curve[0].up_price());
    let page = &self.pages[page_hi];
    value = value + math::mul(node_q_dn(page, slot_hi), curve[len - 1].dn_price());

    let mut ci = 1;
    while (ci < len) {
        let ci_strike = curve[ci].strike();
        let ci_strike_prev = curve[ci - 1].strike();
        let ci_up_price = curve[ci].up_price();
        let ci_dn_price = curve[ci].dn_price();
        let ci_up_price_prev = curve[ci - 1].up_price();
        let ci_dn_price_prev = curve[ci - 1].dn_price();
        (page_hi, slot_hi) = self.strike_to_coords(ci_strike);
        let (q_up_delta, qk_up_delta, q_dn_delta, qk_dn_delta) = self.accumulate_segment_qty_qk(
            page_lo,
            slot_lo,
            page_hi,
            slot_hi,
        );

        if (q_up_delta > 0) {
            assert!(ci_up_price_prev >= ci_up_price, ENonMonotoneCurve);
            let p_avg = interpolate_price_at_avg_strike(
                q_up_delta,
                qk_up_delta,
                ci_strike_prev,
                ci_strike,
                ci_up_price_prev,
                ci_up_price,
            );
            value = value + math::mul(q_up_delta, p_avg);
        };

        if (q_dn_delta > 0) {
            assert!(ci_dn_price >= ci_dn_price_prev, ENonMonotoneCurve);
            let p_dn_avg = interpolate_price_at_avg_strike(
                q_dn_delta,
                qk_dn_delta,
                ci_strike_prev,
                ci_strike,
                ci_dn_price_prev,
                ci_dn_price,
            );
            value = value + math::mul(q_dn_delta, p_dn_avg);
        };

        page_lo = page_hi;
        slot_lo = slot_hi;
        ci = ci + 1;
    };

    value
}

/// Accumulates exact UP/DN quantity and quantity-strike totals for one segment.
/// The boundary ownership remains the same as `evaluate()`: UP uses `(left, right]`
/// and DN uses `[left, right)`.
fun accumulate_segment_qty_qk(
    self: &StrikeMatrix,
    start_page: u64,
    start_slot: u64,
    end_page: u64,
    end_slot: u64,
): (u64, u64, u64, u64) {
    let mut page_lo = start_page;
    let mut slot_lo = start_slot;
    let mut q_up_delta = 0;
    let mut qk_up_delta = 0;
    let mut q_up_chk = 0;
    let mut qk_up_chk = 0;
    let mut q_dn_delta = 0;
    let mut qk_dn_delta = 0;
    while (page_lo < end_page) {
        let page = &self.pages[page_lo];
        let start_node = &page[slot_lo];
        let end_node = &page[PAGE_SLOTS - 1];

        q_up_delta = q_up_delta + end_node.agg_q_up - start_node.agg_q_up + q_up_chk;
        qk_up_delta = qk_up_delta + end_node.agg_qk_up - start_node.agg_qk_up + qk_up_chk;

        let end_q_dn = node_q_dn(page, PAGE_SLOTS - 1);
        q_dn_delta = q_dn_delta + start_node.agg_q_dn - end_node.agg_q_dn + end_q_dn;
        qk_dn_delta =
            qk_dn_delta + start_node.agg_qk_dn - end_node.agg_qk_dn +
            math::mul(end_q_dn, self.strike_from_coords(page_lo, PAGE_SLOTS - 1));

        page_lo = page_lo + 1;
        slot_lo = 0;
        let next_page = &self.pages[page_lo];
        q_up_chk = node_q_up(next_page, slot_lo);
        qk_up_chk = math::mul(q_up_chk, self.strike_from_coords(page_lo, slot_lo));
    };

    let page = &self.pages[end_page];
    let start_node = &page[slot_lo];
    let end_node = &page[end_slot];

    q_up_delta = q_up_delta + end_node.agg_q_up - start_node.agg_q_up + q_up_chk;
    qk_up_delta = qk_up_delta + end_node.agg_qk_up - start_node.agg_qk_up + qk_up_chk;
    q_dn_delta = q_dn_delta + start_node.agg_q_dn - end_node.agg_q_dn;
    qk_dn_delta = qk_dn_delta + start_node.agg_qk_dn - end_node.agg_qk_dn;

    (q_up_delta, qk_up_delta, q_dn_delta, qk_dn_delta)
}

/// Evaluates one linear price segment at the strike-weighted average position.
fun interpolate_price_at_avg_strike(
    qty: u64,
    qty_strike: u64,
    strike_lo: u64,
    strike_hi: u64,
    price_lo: u64,
    price_hi: u64,
): u64 {
    let strike_avg = math::div(qty_strike, qty);
    let ratio = math::div((strike_avg - strike_lo), (strike_hi - strike_lo));
    if (price_hi >= price_lo) {
        price_lo + math::mul(price_hi - price_lo, ratio)
    } else {
        price_lo - math::mul(price_lo - price_hi, ratio)
    }
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
                value = value + node_q_up(page, slot);
            } else {
                value = value + node_q_dn(page, slot);
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

/// Recovers the exact UP quantity at one slot from the page's prefix-style UP aggregates.
fun node_q_up(page: &vector<Node>, slot: u64): u64 {
    if (slot == 0) {
        page[slot].agg_q_up
    } else {
        page[slot].agg_q_up - page[slot - 1].agg_q_up
    }
}

/// Recovers the exact DN quantity at one slot from the page's suffix-style DN aggregates.
fun node_q_dn(page: &vector<Node>, slot: u64): u64 {
    if (slot == PAGE_SLOTS - 1) {
        page[slot].agg_q_dn
    } else {
        page[slot].agg_q_dn - page[slot + 1].agg_q_dn
    }
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
