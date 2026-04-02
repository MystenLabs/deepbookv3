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
    mtm: u64,
}

public struct Node has copy, drop, store {
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
        mtm: 0,
    }
}

public(package) fun insert(self: &mut StrikeMatrix, strike: u64, qty: u64, is_up: bool) {
    let qk = math::mul(qty, strike);
    self.minted_min_strike = self.minted_min_strike.min(strike);
    self.minted_max_strike = self.minted_max_strike.max(strike);

    let (page_key, slot) = self.strike_to_coords(strike);

    if (!self.pages.contains(page_key)) {
        self.pages.add(page_key, empty_page());
    };

    let page = &mut self.pages[page_key];

    let mut i = slot;
    while (i < PAGE_SLOTS) {
        let n = &mut page[i];
        if (is_up) {
            n.agg_q_up = n.agg_q_up + qty;
            n.agg_qk_up = n.agg_qk_up + qk;
        } else {
            n.agg_q_dn = n.agg_q_dn + qty;
            n.agg_qk_dn = n.agg_qk_dn + qk;
        };
        i = i + 1;
    };
}

public(package) fun remove(self: &mut StrikeMatrix, strike: u64, qty: u64, is_up: bool) {
    let qk = math::mul(qty, strike);
    let (page_key, slot) = self.strike_to_coords(strike);
    let page = &mut self.pages[page_key];

    let mut i = slot;
    while (i < PAGE_SLOTS) {
        let n = &mut page[i];
        if (is_up) {
            n.agg_q_up = n.agg_q_up - qty;
            n.agg_qk_up = n.agg_qk_up - qk;
        } else {
            n.agg_q_dn = n.agg_q_dn - qty;
            n.agg_qk_dn = n.agg_qk_dn - qk;
        };
        i = i + 1;
    };
}

public(package) fun evaluate(self: &StrikeMatrix, curve: &vector<CurvePoint>): u64 {
    let len = curve.length();
    if (len == 0) return 0;

    let (mut cur_page, start_slot) = self.strike_to_coords(curve[0].strike());
    let start_page = &self.pages[cur_page];
    let start_node = &start_page[start_slot];
    let mut value =
        math::mul(start_node.agg_q_up, curve[0].up_price())
        + math::mul(start_node.agg_q_dn, curve[0].dn_price());
    let mut chk_up = start_node.agg_q_up;
    let mut chk_qk_up = start_node.agg_qk_up;
    let mut chk_dn = start_node.agg_q_dn;
    let mut chk_qk_dn = start_node.agg_qk_dn;

    let mut ci = 1;
    while (ci < len) {
        let (target_page, target_slot) = self.strike_to_coords(curve[ci].strike());
        let mut delta_q_up = 0u64;
        let mut delta_qk_up = 0u64;
        let mut delta_q_dn = 0u64;
        let mut delta_qk_dn = 0u64;

        while (true) {
            let end_slot = if (cur_page == target_page) {
                target_slot
            } else {
                PAGE_SLOTS - 1
            };

            if (self.pages.contains(cur_page)) {
                let page = &self.pages[cur_page];
                let node = &page[end_slot];
                delta_q_up = delta_q_up + (node.agg_q_up - chk_up);
                delta_qk_up = delta_qk_up + (node.agg_qk_up - chk_qk_up);
                delta_q_dn = delta_q_dn + (node.agg_q_dn - chk_dn);
                delta_qk_dn = delta_qk_dn + (node.agg_qk_dn - chk_qk_dn);
                chk_up = node.agg_q_up;
                chk_qk_up = node.agg_qk_up;
                chk_dn = node.agg_q_dn;
                chk_qk_dn = node.agg_qk_dn;
            };

            if (cur_page == target_page) break;

            cur_page = cur_page + 1;
            chk_up = 0;
            chk_qk_up = 0;
            chk_dn = 0;
            chk_qk_dn = 0;
        };

        let lo = &curve[ci - 1];
        let hi = &curve[ci];
        let k_lo = lo.strike();
        let k_hi = hi.strike();
        let range = k_hi - k_lo;

        if (delta_q_up > 0) {
            let k_avg_up = math::div(delta_qk_up, delta_q_up);
            let p_lo = lo.up_price();
            let p_hi = hi.up_price();
            let price_up = if (range == 0) {
                p_lo
            } else {
                let ratio = math::div(k_avg_up - k_lo, range);
                if (p_hi >= p_lo) {
                    p_lo + math::mul(p_hi - p_lo, ratio)
                } else {
                    p_lo - math::mul(p_lo - p_hi, ratio)
                }
            };
            value = value + math::mul(delta_q_up, price_up);
        };

        if (delta_q_dn > 0) {
            let k_avg_dn = math::div(delta_qk_dn, delta_q_dn);
            let p_lo = lo.dn_price();
            let p_hi = hi.dn_price();
            let price_dn = if (range == 0) {
                p_lo
            } else {
                let ratio = math::div(k_avg_dn - k_lo, range);
                if (p_hi >= p_lo) {
                    p_lo + math::mul(p_hi - p_lo, ratio)
                } else {
                    p_lo - math::mul(p_lo - p_hi, ratio)
                }
            };
            value = value + math::mul(delta_q_dn, price_dn);
        };

        ci = ci + 1;
    };

    value
}

public(package) fun evaluate_settled(self: &StrikeMatrix, settlement: u64): u64 {
    if (!self.has_minted_strikes()) return 0;

    let (mut total_page, start_slot) = self.strike_to_coords(self.minted_min_strike);
    let start_page = &self.pages[total_page];
    let start_node = &start_page[start_slot];
    let mut total_up = start_node.agg_q_up;
    let mut total_dn = start_node.agg_q_dn;
    let mut chk_up = start_node.agg_q_up;
    let mut chk_dn = start_node.agg_q_dn;
    let (max_page, max_slot) = self.strike_to_coords(self.minted_max_strike);

    while (true) {
        let end_slot = if (total_page == max_page) {
            max_slot
        } else {
            PAGE_SLOTS - 1
        };

        if (self.pages.contains(total_page)) {
            let page = &self.pages[total_page];
            let node = &page[end_slot];
            total_up = total_up + (node.agg_q_up - chk_up);
            total_dn = total_dn + (node.agg_q_dn - chk_dn);
            chk_up = node.agg_q_up;
            chk_dn = node.agg_q_dn;
        };

        if (total_page == max_page) break;

        total_page = total_page + 1;
        chk_up = 0;
        chk_dn = 0;
    };

    if (settlement <= self.minted_min_strike) return total_dn;
    if (settlement > self.minted_max_strike) return total_up;

    let (mut below_page, _) = self.strike_to_coords(self.minted_min_strike);
    let mut up_below = start_node.agg_q_up;
    let mut dn_below = start_node.agg_q_dn;
    let mut chk_up = start_node.agg_q_up;
    let mut chk_dn = start_node.agg_q_dn;
    let (cutoff_page, cutoff_slot) = self.strike_to_coords(settlement - 1);

    while (true) {
        let end_slot = if (below_page == cutoff_page) {
            cutoff_slot
        } else {
            PAGE_SLOTS - 1
        };

        if (self.pages.contains(below_page)) {
            let page = &self.pages[below_page];
            let node = &page[end_slot];
            up_below = up_below + (node.agg_q_up - chk_up);
            dn_below = dn_below + (node.agg_q_dn - chk_dn);
            chk_up = node.agg_q_up;
            chk_dn = node.agg_q_dn;
        };

        if (below_page == cutoff_page) break;

        below_page = below_page + 1;
        chk_up = 0;
        chk_dn = 0;
    };

    up_below + (total_dn - dn_below)
}

public(package) fun mtm(self: &StrikeMatrix): u64 {
    self.mtm
}

public(package) fun set_mtm(self: &mut StrikeMatrix, value: u64) {
    self.mtm = value;
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
        agg_q_up: 0,
        agg_qk_up: 0,
        agg_q_dn: 0,
        agg_qk_dn: 0,
    };
    vector::tabulate!(PAGE_SLOTS, |_| empty)
}
