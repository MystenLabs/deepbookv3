// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for `liquidation_book::scan_compact` — the flush valuation's
/// fused kill-and-correct scan — driven by a real live `Pricer` memo over a
/// standalone book, mirroring `liquidation_book_tests`' direct-construction
/// style (the book is a pure data structure; only leveraged orders are indexed).
///
/// The default degenerate test SVI prices the exact-ATM digital at 0.5 exactly
/// (pinned by the flow fixtures' cash constants), so every order here uses the
/// ATM up range `(strike_tick, +inf]` at an exact gross of `quantity / 2`, and
/// the knock-out boundary is pinned to the unit: hand-derived `(floor, ltv)`
/// pairs put one order's gross exactly AT `div(floor, ltv)` (killed — the test
/// is `<=`) and another's exactly ONE unit above (survives). Floors are the
/// free variable because packed floors have unit granularity while lot-aligned
/// quantities move gross in 5_000-unit steps.
#[test_only]
module deepbook_predict::liquidation_scan_tests;

use deepbook_predict::{
    constants,
    liquidation_book,
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    order::{Self, Order},
    pricing::{Self, PriceMemo},
    strike_payout_tree,
    test_constants
};
use std::unit_test::{assert_eq, destroy};

/// 40_000 lots; every scan order's gross at the exact-ATM price is
/// `mul(5e8, 4e8) = 200_000_000` exactly.
const SCAN_QUANTITY: u64 = 400_000_000;
/// Admissible LTV (envelope `[0.5e9, 0.95e9]`) chosen so both knock-out
/// boundary sides are exactly representable in integer floors (see below).
const BOUNDARY_LTV: u64 = 600_000_003;
/// `div(120_000_001, 0.600000003) = floor(120_000_001e9 / 600_000_003)
/// = 200_000_000` exactly: gross == threshold, so the `<=` test kills it.
const KILLED_AT_BOUNDARY_FLOOR: u64 = 120_000_001;
/// `div(120_000_000, 0.600000003) = 199_999_999` exactly: gross is one unit
/// above the threshold, so the order survives.
const ONE_UNIT_ABOVE_FLOOR: u64 = 120_000_000;
/// Default LTV (0.85): `div(170_000_000, 0.85) = 200_000_000` exactly — the
/// compaction test's kill floor sits at the boundary too.
const DEFAULT_LTV: u64 = 850_000_000;
const COMPACT_KILL_FLOOR: u64 = 170_000_000;
/// `div(100_000_000, 0.85) = 117_647_058 < 200_000_000`: clear survivor.
const COMPACT_SURVIVE_FLOOR: u64 = 100_000_000;
/// Spans one page split (`PAGE_CAPACITY = 64`), half killed, half surviving.
const COMPACT_ORDERS_PER_SIDE: u64 = 35;
/// Clear survivors for the correction-equivalence test:
/// thresholds 58_823_529 / 70_588_235 / 82_352_941, all far below gross.
const SURVIVOR_FLOOR_A: u64 = 50_000_000;
const SURVIVOR_FLOOR_B: u64 = 60_000_000;
const SURVIVOR_FLOOR_C: u64 = 70_000_000;
const EXACT_ATM_PRICE: u64 = 500_000_000;

#[test]
fun kills_at_exact_threshold_and_spares_one_unit_above() {
    let (fixture, oracle, memo) = atm_memo();
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);

    let killed_order = atm_order(KILLED_AT_BOUNDARY_FLOOR, 0);
    let survivor_order = atm_order(ONE_UNIT_ABOVE_FLOOR, 1);
    book.insert_order(&killed_order);
    book.insert_order(&survivor_order);

    let (correction, killed) = book.scan_compact(&memo, BOUNDARY_LTV);

    assert_eq!(killed.length(), 1);
    assert_eq!(killed[0].id(), killed_order.id());
    // Survivor correction is its static floor exactly (the min-cap cannot bind
    // above the knock-out threshold).
    assert_eq!(correction, ONE_UNIT_ABOVE_FLOOR);
    assert!(!book.contains_active_order(&killed_order));
    assert!(book.contains_active_order(&survivor_order));

    destroy(book);
    cleanup(fixture, oracle);
}

#[test]
fun zero_liquidatable_scan_matches_correction_value_and_leaves_book_intact() {
    let (fixture, oracle, memo) = atm_memo();
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);

    let a = atm_order(SURVIVOR_FLOOR_A, 0);
    let b = atm_order(SURVIVOR_FLOOR_B, 1);
    let c = atm_order(SURVIVOR_FLOOR_C, 2);
    book.insert_order(&a);
    book.insert_order(&b);
    book.insert_order(&c);

    let (correction, killed) = book.scan_compact(&memo, DEFAULT_LTV);

    assert!(killed.is_empty());
    // Hand sum of the three floors...
    assert_eq!(correction, SURVIVOR_FLOOR_A + SURVIVOR_FLOOR_B + SURVIVOR_FLOOR_C);
    // ...and bit-identical to the read-only correction walk `current_nav` uses,
    // pinning the survivor min-cap equivalence the flush's bit-identity relies on.
    assert_eq!(correction, book.correction_value(&memo));
    assert!(book.contains_active_order(&a));
    assert!(book.contains_active_order(&b));
    assert!(book.contains_active_order(&c));

    destroy(book);
    cleanup(fixture, oracle);
}

#[test]
fun compaction_across_pages_preserves_survivor_bookkeeping() {
    let (fixture, oracle, memo) = atm_memo();
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);

    // Equal quantities sort larger floors first (inverse-encoded), so the kill
    // set fills the front pages and emptied-page removal is exercised.
    let mut killed_orders = vector<Order>[];
    let mut survivors = vector<Order>[];
    COMPACT_ORDERS_PER_SIDE.do!(|i| {
        let kill = atm_order(COMPACT_KILL_FLOOR, i);
        let live = atm_order(COMPACT_SURVIVE_FLOOR, COMPACT_ORDERS_PER_SIDE + i);
        book.insert_order(&kill);
        book.insert_order(&live);
        killed_orders.push_back(kill);
        survivors.push_back(live);
    });

    let (correction, killed) = book.scan_compact(&memo, DEFAULT_LTV);

    assert_eq!(killed.length(), COMPACT_ORDERS_PER_SIDE);
    assert_eq!(correction, COMPACT_ORDERS_PER_SIDE * COMPACT_SURVIVE_FLOOR);
    killed_orders.do_ref!(|o| assert!(!book.contains_active_order(o)));
    survivors.do_ref!(|o| assert!(book.contains_active_order(o)));

    // The compacted geometry (page vectors, max-order-id index, count) must
    // still support the full mutation surface: any corruption aborts these
    // removals with EActiveOrderNotFound.
    let refill = atm_order(COMPACT_SURVIVE_FLOOR, 2 * COMPACT_ORDERS_PER_SIDE);
    book.insert_order(&refill);
    book.remove_order(&refill);
    survivors.do_ref!(|o| book.remove_order(o));
    survivors.do_ref!(|o| assert!(!book.contains_active_order(o)));

    destroy(book);
    cleanup(fixture, oracle);
}

#[test]
fun empty_book_scan_is_a_noop() {
    let ctx = &mut tx_context::dummy();
    let mut book = liquidation_book::new(ctx);
    let memo = pricing::new_price_memo();

    let (correction, killed) = book.scan_compact(&memo, DEFAULT_LTV);

    assert_eq!(correction, 0);
    assert!(killed.is_empty());

    destroy(book);
}

// === Helpers ===

/// ATM up order `(strike_tick, +inf]` with an explicit floor and sequence;
/// nonzero floors make every order leveraged (1x orders are never indexed).
fun atm_order(floor_shares: u64, sequence: u64): Order {
    order::new_from_ticks(
        test_constants::default_strike_tick(),
        constants::pos_inf_tick!(),
        floor_shares,
        SCAN_QUANTITY,
        sequence,
    )
}

/// Live default (degenerate-SVI) oracle plus a memo filled by the production
/// linear walk over the single ATM boundary, with the exact-ATM price asserted
/// so a fixture drift fails loudly here instead of skewing the boundary pins.
fun atm_memo(): (OracleFixture, OracleBundle, PriceMemo) {
    let mut fixture = oracle_fixture::setup_oracle_default();
    let mut oracle = fixture.take_oracle_bundle();
    fixture.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let pricer = fixture.load_pricer_bundle(&oracle);

    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());
    tree.insert_range(
        test_constants::default_strike_tick(),
        constants::pos_inf_tick!(),
        SCAN_QUANTITY,
        0,
    );
    let mut memo = pricing::new_price_memo();
    tree.walk_linear(&pricer, &mut memo, test_constants::default_tick_size());
    assert_eq!(
        memo.cached_range_price(
            test_constants::default_strike_tick(),
            constants::pos_inf_tick!(),
        ),
        EXACT_ATM_PRICE,
    );
    destroy(tree);
    (fixture, oracle, memo)
}

fun cleanup(fixture: OracleFixture, oracle: OracleBundle) {
    oracle_fixture::return_oracle_bundle(oracle);
    fixture.finish();
}
