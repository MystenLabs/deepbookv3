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
use deepbook_predict::i64;
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
    net_qty: i64::I64,
    mtm: u64,
}

public struct Node has copy, drop, store {
    agg_net_up: i64::I64,
    agg_net_qk_up: i64::I64,
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
        net_qty: i64::zero(),
        mtm: 0,
    }
}

public(package) fun increase_up(self: &mut StrikeMatrix, strike: u64, qty: u64) {
    self.minted_min_strike = self.minted_min_strike.min(strike);
    self.minted_max_strike = self.minted_max_strike.max(strike);
    self.net_qty = i64::add_u64(&self.net_qty, qty);

    let qk = math::mul(qty, strike);
    let (page_key, mut slot) = self.strike_to_coords(strike);
    let page = &mut self.pages[page_key];
    while (slot < PAGE_SLOTS) {
        let node = &mut page[slot];
        node.agg_net_up = i64::add_u64(&node.agg_net_up, qty);
        node.agg_net_qk_up = i64::add_u64(&node.agg_net_qk_up, qk);
        slot = slot + 1;
    };
}

public(package) fun decrease_up(self: &mut StrikeMatrix, strike: u64, qty: u64) {
    self.net_qty = i64::sub_u64(&self.net_qty, qty);

    let qk = math::mul(qty, strike);
    let (page_key, mut slot) = self.strike_to_coords(strike);
    let page = &mut self.pages[page_key];
    while (slot < PAGE_SLOTS) {
        let node = &mut page[slot];
        node.agg_net_up = i64::sub_u64(&node.agg_net_up, qty);
        node.agg_net_qk_up = i64::sub_u64(&node.agg_net_qk_up, qk);
        slot = slot + 1;
    };
}

public(package) fun evaluate2(self: &StrikeMatrix, curve: &vector<CurvePoint>): i64::I64 {
    let len = curve.length();
    if (len == 0) return i64::zero();
    assert!(
        curve[0].strike() <= self.minted_min_strike
        && curve[len - 1].strike() >= self.minted_max_strike,
        EInvalidCurveRange,
    );
    let (page_lo, slot_lo) = self.strike_to_coords(curve[0].strike());
    let mut value = i64::mul_scaled(&self.pages[page_lo][slot_lo].agg_net_up, &i64::from_u64(curve[0].price()));

    let mut ci = 1;
    while (ci < len) {
        assert!(curve[ci].strike() > curve[ci - 1].strike(), ENonMonotoneCurve);
        let (mut page_lo, slot_lo) = self.strike_to_coords(curve[ci - 1].strike());
        let (page_hi, slot_hi) = self.strike_to_coords(curve[ci].strike());
        let mut agg_q = i64::neg(&self.pages[page_lo][slot_lo].agg_net_up);
        let mut agg_qk = i64::neg(&self.pages[page_lo][slot_lo].agg_net_qk_up);
        while (page_lo < page_hi) {
            agg_q = i64::add(&agg_q, &self.pages[page_lo][PAGE_SLOTS - 1].agg_net_up);
            agg_qk = i64::add(&agg_qk, &self.pages[page_lo][PAGE_SLOTS - 1].agg_net_qk_up);
            page_lo = page_lo + 1;
        };

        agg_q = i64::add(&agg_q, &self.pages[page_hi][slot_hi].agg_net_up);
        agg_qk = i64::add(&agg_qk, &self.pages[page_hi][slot_hi].agg_net_qk_up);

        let k0 = i64::from_u64(curve[ci - 1].strike());
        let p0 = i64::from_u64(curve[ci - 1].price());
        let p1 = i64::from_u64(curve[ci].price());

        let dp = i64::sub(&p1, &p0);
        let dk = i64::from_u64(curve[ci].strike() - curve[ci - 1].strike());
        let slope = i64::div_scaled(&dp, &dk);

        let base = i64::mul_scaled(&agg_q, &p0);
        let offset = i64::sub(&agg_qk, &i64::mul_scaled(&k0, &agg_q));
        let extra = i64::mul_scaled(&slope, &offset);

        value = i64::add(&value, &base);
        value = i64::add(&value, &extra);

        ci = ci + 1;
    };

    value
}

/// Computes final settled payout by summing winning UP strikes below settlement and
/// winning DN strikes at or above settlement.
public(package) fun evaluate_settled(self: &StrikeMatrix, settlement: u64): i64::I64 {
    if (self.minted_max_strike < self.minted_min_strike) return i64::zero();

    let (min_page, min_slot) = self.strike_to_coords(self.minted_min_strike);
    let (max_page, max_slot) = self.strike_to_coords(self.minted_max_strike);

    let mut value = i64::zero();
    let mut page_key = min_page;
    while (true) {
        let page = &self.pages[page_key];
        let start_slot = if (page_key == min_page) { min_slot } else { 0 };
        let end_slot = if (page_key == max_page) { max_slot } else { PAGE_SLOTS - 1 };

        let mut slot = start_slot;
        while (true) {
            let q = if (slot == 0) {
                page[slot].agg_net_up
            } else {
                i64::sub(&page[slot].agg_net_up, &page[slot - 1].agg_net_up)
            };
            let strike = self.strike_from_coords(page_key, slot);

            if (strike < settlement) {
                if (!i64::is_negative(&q)) {
                    value = i64::add(&value, &q);
                };
            } else {
                if (i64::is_negative(&q)) {
                    value = i64::add(&value, &i64::neg(&q));
                };
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

/// Returns the historical min/max strikes touched by the book.
public(package) fun minted_strike_range(self: &StrikeMatrix): (u64, u64) {
    (self.minted_min_strike, self.minted_max_strike)
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

/// Builds one zeroed page with `PAGE_SLOTS` empty nodes.
fun empty_page(): vector<Node> {
    let empty = Node {
        agg_net_up: i64::zero(),
        agg_net_qk_up: i64::zero(),
    };
    vector::tabulate!(PAGE_SLOTS, |_| empty)
}
