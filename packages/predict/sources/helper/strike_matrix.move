module deepbook_predict::strike_matrix;

use deepbook::math;
use deepbook_predict::oracle::CurvePoint;
use sui::table::{Self, Table};

const PAGE_SLOTS: u64 = 256;

public struct StrikeMatrix has store {
    pages: Table<u64, vector<Node>>,
    tick_size: u64,
    min_strike: u64,
    max_strike: u64,
}

public struct Node has copy, drop, store {
    agg_q_up: u64,
    agg_q_dn: u64,
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
    }
}

public(package) fun insert(
    self: &mut StrikeMatrix,
    strike: u64,
    qty: u64,
    is_up: bool,
) {
    let (page_key, slot) = self.strike_to_coords(strike);

    if (!self.pages.contains(page_key)) {
        self.pages.add(page_key, empty_page());
    };

    let page = &mut self.pages[page_key];

    let mut i = slot;
    while (i < PAGE_SLOTS) {
        let n = &mut page[i];
        if (is_up) { n.agg_q_up = n.agg_q_up + qty }
        else { n.agg_q_dn = n.agg_q_dn + qty };
        i = i + 1;
    };
}

public(package) fun remove(
    self: &mut StrikeMatrix,
    strike: u64,
    qty: u64,
    is_up: bool,
) {
    let (page_key, slot) = self.strike_to_coords(strike);
    let page = &mut self.pages[page_key];

    let mut i = slot;
    while (i < PAGE_SLOTS) {
        let n = &mut page[i];
        if (is_up) { n.agg_q_up = n.agg_q_up - qty }
        else { n.agg_q_dn = n.agg_q_dn - qty };
        i = i + 1;
    };
}

public(package) fun strike_range(self: &StrikeMatrix): (u64, u64) {
    (self.min_strike, self.max_strike)
}

public(package) fun evaluate(self: &StrikeMatrix, curve: &vector<CurvePoint>): u64 {
    let len = curve.length();
    if (len == 0) return 0;

    let mut value = 0u64;
    let (mut cur_page, _) = self.strike_to_coords(curve[0].strike());
    let mut chk_up = 0u64;
    let mut chk_dn = 0u64;

    let mut ci = 1;
    while (ci < len) {
        let (target_page, target_slot) = self.strike_to_coords(curve[ci].strike());
        let price_up = curve[ci].up_price();
        let price_dn = curve[ci].dn_price();

        // Sweep from current position to target position page by page
        while (cur_page < target_page) {
            if (self.pages.contains(cur_page)) {
                let page = &self.pages[cur_page];
                let last = &page[PAGE_SLOTS - 1];
                let delta_up = last.agg_q_up - chk_up;
                let delta_dn = last.agg_q_dn - chk_dn;
                value = value
                    + math::mul(delta_up, price_up)
                    + math::mul(delta_dn, price_dn);
            };
            cur_page = cur_page + 1;
            chk_up = 0;
            chk_dn = 0;
        };

        // Same page as target — read at target slot
        if (self.pages.contains(cur_page)) {
            let page = &self.pages[cur_page];
            let node = &page[target_slot];
            let delta_up = node.agg_q_up - chk_up;
            let delta_dn = node.agg_q_dn - chk_dn;
            value = value
                + math::mul(delta_up, price_up)
                + math::mul(delta_dn, price_dn);
            chk_up = node.agg_q_up;
            chk_dn = node.agg_q_dn;
        };

        ci = ci + 1;
    };

    value
}

// === Private Helpers ===

fun strike_to_coords(self: &StrikeMatrix, strike: u64): (u64, u64) {
    let tick_index = (strike - self.min_strike) / self.tick_size;
    let page_key = tick_index / PAGE_SLOTS;
    let slot = tick_index % PAGE_SLOTS;
    (page_key, slot)
}

fun empty_page(): vector<Node> {
    let empty = Node { agg_q_up: 0, agg_q_dn: 0 };
    vector::tabulate!(PAGE_SLOTS, |_| empty)
}
