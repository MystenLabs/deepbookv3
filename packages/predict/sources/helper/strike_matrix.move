module deepbook_predict::strike_matrix;

use deepbook::{constants::max_u64, math};
use deepbook_predict::oracle::CurvePoint;
use sui::table::{Self, Table};

const PAGE_SLOTS: u64 = 256;

public struct StrikeMatrix has store {
    pages: Table<u64, vector<Node>>,
    tick_size: u64,
    min_strike: u64,
    max_strike: u64,
    minted_min_strike: u64,
    minted_max_strike: u64,
    total_q_up: u64,
    total_q_dn: u64,
    mtm: u64,
}

public struct Node has copy, drop, store {
    q_up: u64,
    q_dn: u64,
    qk_up: u64,
    qk_dn: u64,
    agg_q_up: u64,
    agg_qk_up: u64,
    agg_q_dn: u64,
    agg_qk_dn: u64,
}

// === Public-Package API ===

public(package) fun new(
    ctx: &mut TxContext,
    tick_size: u64,
    min_strike: u64,
    max_strike: u64,
): StrikeMatrix {
    StrikeMatrix {
        pages: table::new(ctx),
        tick_size,
        min_strike,
        max_strike,
        minted_min_strike: max_u64(),
        minted_max_strike: 0,
        total_q_up: 0,
        total_q_dn: 0,
        mtm: 0,
    }
}

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

    if (!self.pages.contains(page_key)) {
        self.pages.add(page_key, empty_page());
    };

    let page = &mut self.pages[page_key];
    page[slot].qk_up = page[slot].qk_up + if (is_up) { qk } else { 0 };
    page[slot].q_up = page[slot].q_up + if (is_up) { qty } else { 0 };
    page[slot].qk_dn = page[slot].qk_dn + if (is_up) { 0 } else { qk };
    page[slot].q_dn = page[slot].q_dn + if (is_up) { 0 } else { qty };

    let mut i = slot;
    while (true) {
        let n = &mut page[i];
        if (is_up) {
            n.agg_q_up = n.agg_q_up + qty;
            n.agg_qk_up = n.agg_qk_up + qk;
            i = i + 1;
            if (i == PAGE_SLOTS) break;
        } else {
            n.agg_q_dn = n.agg_q_dn + qty;
            n.agg_qk_dn = n.agg_qk_dn + qk;
            if (i == 0) break;
            i = i - 1;
        };
    };
}

public(package) fun remove(self: &mut StrikeMatrix, strike: u64, qty: u64, is_up: bool) {
    let qk = math::mul(qty, strike);
    if (is_up) {
        self.total_q_up = self.total_q_up - qty;
    } else {
        self.total_q_dn = self.total_q_dn - qty;
    };
    let (page_key, slot) = self.strike_to_coords(strike);
    let page = &mut self.pages[page_key];
    page[slot].qk_up = page[slot].qk_up - if (is_up) { qk } else { 0 };
    page[slot].q_up = page[slot].q_up - if (is_up) { qty } else { 0 };
    page[slot].qk_dn = page[slot].qk_dn - if (is_up) { 0 } else { qk };
    page[slot].q_dn = page[slot].q_dn - if (is_up) { 0 } else { qty };

    let mut i = slot;
    while (true) {
        let n = &mut page[i];
        if (is_up) {
            n.agg_q_up = n.agg_q_up - qty;
            n.agg_qk_up = n.agg_qk_up - qk;
            i = i + 1;
            if (i == PAGE_SLOTS) break;
        } else {
            n.agg_q_dn = n.agg_q_dn - qty;
            n.agg_qk_dn = n.agg_qk_dn - qk;
            if (i == 0) break;
            i = i - 1;
        };
    };
}

public(package) fun evaluate(self: &StrikeMatrix, curve: &vector<CurvePoint>): u64 {
    let len = curve.length();
    if (len == 0) return 0;
    let mut value = 0;
    let (mut page_lo, mut slot_lo) = self.strike_to_coords(curve[0].strike());
    let (mut page_hi, mut slot_hi) = self.strike_to_coords(curve[len-1].strike());
    if (self.pages.contains(page_lo)) {
        value = value + math::mul(self.pages[page_lo][slot_lo].q_up, curve[0].up_price());
    };
    if (self.pages.contains(page_hi)) {
        value = value + math::mul(self.pages[page_hi][slot_hi].q_dn, curve[len-1].dn_price());
    };

    let mut ci = 1;
    while (ci < len) {
        (page_hi, slot_hi) = self.strike_to_coords(curve[ci].strike());
        let mut q_up_delta = 0;
        let mut qk_up_delta = 0;
        let mut q_up_chk = 0;
        let mut qk_up_chk = 0;
        let mut q_dn_delta = 0;
        let mut qk_dn_delta = 0;
        while (page_lo < page_hi) {
            if (self.pages.contains(page_lo)) {
                let page = &self.pages[page_lo];
                let start_node = &page[slot_lo];
                let end_node = &page[PAGE_SLOTS - 1];

                q_up_delta = q_up_delta + end_node.agg_q_up - start_node.agg_q_up + q_up_chk;
                qk_up_delta = qk_up_delta + end_node.agg_qk_up - start_node.agg_qk_up + qk_up_chk;

                q_dn_delta = q_dn_delta + start_node.agg_q_dn - end_node.agg_q_dn + end_node.q_dn;
                qk_dn_delta =
                    qk_dn_delta + start_node.agg_qk_dn - end_node.agg_qk_dn + end_node.qk_dn;
            };

            page_lo = page_lo + 1;
            slot_lo = 0;
            if (self.pages.contains(page_lo)) {
                q_up_chk = self.pages[page_lo][slot_lo].q_up;
                qk_up_chk = self.pages[page_lo][slot_lo].qk_up;
            };
        };

        if (self.pages.contains(page_hi)) {
            let page = &self.pages[page_hi];
            let start_node = &page[slot_lo];
            let end_node = &page[slot_hi];

            q_up_delta = q_up_delta + end_node.agg_q_up - start_node.agg_q_up + q_up_chk;
            qk_up_delta = qk_up_delta + end_node.agg_qk_up - start_node.agg_qk_up + qk_up_chk;
            q_dn_delta = q_dn_delta + start_node.agg_q_dn - end_node.agg_q_dn;
            qk_dn_delta = qk_dn_delta + start_node.agg_qk_dn - end_node.agg_qk_dn;
        };

        if (q_up_delta > 0) {
            let k_avg = math::div(qk_up_delta, q_up_delta);
            let ratio = math::div(
                (k_avg - curve[ci-1].strike()),
                (curve[ci].strike() - curve[ci-1].strike()),
            );
            // UP price goes down as strikes increase
            let p_avg =
                curve[ci-1].up_price() - math::mul(curve[ci-1].up_price() - curve[ci].up_price(), ratio);
            value = value + math::mul(q_up_delta, p_avg)
        };

        if (q_dn_delta > 0) {
            let k_dn_avg = math::div(qk_dn_delta, q_dn_delta);
            let ratio_dn = math::div(
                (k_dn_avg - curve[ci-1].strike()),
                (curve[ci].strike() - curve[ci-1].strike()),
            );
            let p_dn_avg =
                curve[ci-1].dn_price() + math::mul(curve[ci].dn_price() - curve[ci-1].dn_price(), ratio_dn);
            value = value + math::mul(q_dn_delta, p_dn_avg);
        };

        page_lo = page_hi;
        slot_lo = slot_hi;
        ci = ci + 1;
    };

    value
}

public(package) fun evaluate_settled(self: &StrikeMatrix, settlement: u64): u64 {
    if (!self.has_minted_strikes()) return 0;

    let (min_page, min_slot) = self.strike_to_coords(self.minted_min_strike);
    let (max_page, max_slot) = self.strike_to_coords(self.minted_max_strike);

    if (settlement <= self.minted_min_strike) {
        let mut dn_above = 0u64;
        let mut page_key = min_page;
        while (true) {
            if (self.pages.contains(page_key)) {
                let page = &self.pages[page_key];
                let start_slot = if (page_key == min_page) { min_slot } else { 0 };
                dn_above = dn_above + page[start_slot].agg_q_dn;
            };

            if (page_key == max_page) break;
            page_key = page_key + 1;
        };
        return dn_above;
    };

    if (settlement > self.minted_max_strike) {
        let mut up_below = 0u64;
        let mut page_key = min_page;
        while (true) {
            if (self.pages.contains(page_key)) {
                let page = &self.pages[page_key];
                let start_slot = if (page_key == min_page) { min_slot } else { 0 };
                let end_slot = if (page_key == max_page) {
                    max_slot
                } else {
                    PAGE_SLOTS - 1
                };
                let end_node = &page[end_slot];
                up_below =
                    up_below + if (start_slot == 0) {
                    end_node.agg_q_up
                } else {
                    end_node.agg_q_up - page[start_slot].agg_q_up + page[start_slot].q_up
                };
            };

            if (page_key == max_page) break;
            page_key = page_key + 1;
        };
        return up_below;
    };

    let mut up_below = 0u64;
    let (cutoff_page, cutoff_slot) = self.strike_to_coords(settlement - 1);
    let mut page_key = min_page;
    while (true) {
        if (self.pages.contains(page_key)) {
            let page = &self.pages[page_key];
            let start_slot = if (page_key == min_page) { min_slot } else { 0 };
            let end_slot = if (page_key == cutoff_page) {
                cutoff_slot
            } else {
                PAGE_SLOTS - 1
            };
            let end_node = &page[end_slot];
            up_below =
                up_below + if (start_slot == 0) {
                end_node.agg_q_up
            } else {
                end_node.agg_q_up - page[start_slot].agg_q_up + page[start_slot].q_up
            };
        };

        if (page_key == cutoff_page) break;
        page_key = page_key + 1;
    };

    let mut dn_above = 0u64;
    let floor_strike =
        self.min_strike + ((settlement - self.min_strike) / self.tick_size) * self.tick_size;
    let first_winning_strike = if (floor_strike == settlement) {
        settlement
    } else {
        floor_strike + self.tick_size
    };
    let (dn_start_page, dn_start_slot) = self.strike_to_coords(first_winning_strike);
    page_key = dn_start_page;
    while (true) {
        if (self.pages.contains(page_key)) {
            let page = &self.pages[page_key];
            let start_slot = if (page_key == dn_start_page) {
                dn_start_slot
            } else {
                0
            };
            dn_above = dn_above + page[start_slot].agg_q_dn;
        };

        if (page_key == max_page) break;
        page_key = page_key + 1;
    };

    up_below + dn_above
}

public(package) fun mtm(self: &StrikeMatrix): u64 {
    self.mtm
}

public(package) fun set_mtm(self: &mut StrikeMatrix, value: u64) {
    self.mtm = value;
}

public(package) fun max_payout(self: &StrikeMatrix): u64 {
    self.total_q_up + self.total_q_dn
}

public(package) fun has_minted_strikes(self: &StrikeMatrix): bool {
    self.minted_max_strike >= self.minted_min_strike
}

public(package) fun minted_strike_range(self: &StrikeMatrix): (u64, u64) {
    (self.minted_min_strike, self.minted_max_strike)
}

// === Private Helpers ===

fun strike_to_coords(self: &StrikeMatrix, strike: u64): (u64, u64) {
    let tick_index = (strike - self.min_strike) / self.tick_size;
    let page_key = tick_index / PAGE_SLOTS;
    let slot = tick_index % PAGE_SLOTS;
    (page_key, slot)
}

fun empty_page(): vector<Node> {
    let empty = Node {
        q_up: 0,
        q_dn: 0,
        qk_up: 0,
        qk_dn: 0,
        agg_q_up: 0,
        agg_qk_up: 0,
        agg_q_dn: 0,
        agg_qk_dn: 0,
    };
    vector::tabulate!(PAGE_SLOTS, |_| empty)
}
