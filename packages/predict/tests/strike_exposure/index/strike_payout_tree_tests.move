// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::strike_payout_tree_tests;

use deepbook_predict::{constants, strike_payout_tree};
use std::unit_test::{assert_eq, destroy};

// Small grid that fits inside the oracle_strike_grid_ticks!() envelope.
// 11 ticks: 100, 110, 120, ..., 200.
const MIN_STRIKE: u64 = 100;
const TICK_SIZE: u64 = 10;
const MAX_STRIKE: u64 = 200;

// === Constructor (new + grid validation) ===

#[test]
fun new_returns_empty_tree() {
    let ctx = &mut tx_context::dummy();
    let tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    // Empty tree has zero conservative backing and zero settled liability at any
    // settlement price.
    assert_eq!(tree.max_live_backing_payout(), 0);
    assert_eq!(tree.settled_payout_liability(MIN_STRIKE), 0);
    assert_eq!(tree.settled_payout_liability(MAX_STRIKE), 0);
    tree.destroy();
}

#[test, expected_failure(abort_code = strike_payout_tree::EInvalidTickSize)]
fun new_zero_tick_size_aborts() {
    let ctx = &mut tx_context::dummy();
    destroy(strike_payout_tree::new(MIN_STRIKE, 0, MAX_STRIKE, ctx));
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EInvalidStrikeRange)]
fun new_min_above_max_aborts() {
    let ctx = &mut tx_context::dummy();
    destroy(strike_payout_tree::new(MAX_STRIKE, TICK_SIZE, MIN_STRIKE, ctx));
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EUnalignedStrike)]
fun new_unaligned_min_aborts() {
    // min_strike=105 with tick=10 -> 105 % 10 != 0.
    let ctx = &mut tx_context::dummy();
    destroy(strike_payout_tree::new(105, TICK_SIZE, MAX_STRIKE, ctx));
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EUnalignedStrike)]
fun new_unaligned_max_aborts() {
    let ctx = &mut tx_context::dummy();
    destroy(strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, 205, ctx));
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::ETooManyStrikes)]
fun new_too_many_strikes_aborts() {
    // oracle_strike_grid_ticks!() + 1 strikes is the cap; +2 strikes aborts.
    let ctx = &mut tx_context::dummy();
    let too_wide_max = TICK_SIZE * (constants::oracle_strike_grid_ticks!() + 2);
    destroy(strike_payout_tree::new(0, TICK_SIZE, too_wide_max, ctx));
    abort 999
}

// === max_live_backing_payout ===

#[test]
fun insert_open_low_range_returns_backing_at_max_strike() {
    // (neg_inf, 150]: backing required for the entire low-prefix bucket. The
    // max live backing prefix is the base value (since the boundary at 150
    // closes it).
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(constants::neg_inf!(), 150, 100, 100);

    assert_eq!(tree.max_live_backing_payout(), 100);
    tree.destroy();
}

#[test]
fun insert_open_high_range_returns_max_backing() {
    // (150, pos_inf]: backing accrues at strike 150 and never closes.
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(150, constants::pos_inf!(), 100, 100);

    assert_eq!(tree.max_live_backing_payout(), 100);
    tree.destroy();
}

#[test]
fun insert_finite_range_returns_max_backing_in_range() {
    // (120, 160]: backing is required between 120 and 160 (the gain side).
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(120, 160, 50, 50);

    assert_eq!(tree.max_live_backing_payout(), 50);
    tree.destroy();
}

#[test]
fun two_disjoint_ranges_only_count_max_overlap() {
    // (110, 130] and (150, 170] never overlap, so the peak prefix gain is the
    // single-order backing, not the sum.
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(110, 130, 40, 40);
    tree.insert_range(150, 170, 30, 30);

    assert_eq!(tree.max_live_backing_payout(), 40);
    tree.destroy();
}

#[test]
fun two_overlapping_ranges_sum_backing() {
    // (110, 160] and (130, 170] overlap on (130, 160]; the peak prefix gain
    // is the sum of both backings during the overlap window.
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(110, 160, 40, 40);
    tree.insert_range(130, 170, 30, 30);

    assert_eq!(tree.max_live_backing_payout(), 70);
    tree.destroy();
}

// === insert_range early-return and abort cases ===

#[test]
fun insert_with_both_terms_zero_is_no_op() {
    // The module short-circuits on `terminal_payout == 0 && live_backing_payout == 0`.
    // Otherwise EInvalidPayoutTerms would not even be reached.
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(120, 160, 0, 0);

    assert_eq!(tree.max_live_backing_payout(), 0);
    tree.destroy();
}

#[test, expected_failure(abort_code = strike_payout_tree::EInvalidPayoutTerms)]
fun insert_terminal_greater_than_backing_aborts() {
    // Module invariant: terminal_payout <= live_backing_payout (the live
    // requirement must be at least the terminal liability).
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(120, 160, 100, 50);
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EInvalidStrikeRange)]
fun insert_lower_equal_higher_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(150, 150, 10, 10);
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EInvalidStrikeRange)]
fun insert_lower_above_higher_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(160, 140, 10, 10);
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EInvalidStrikeRange)]
fun insert_full_open_range_aborts() {
    // (neg_inf, pos_inf] is rejected to keep settlement liability finite.
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(constants::neg_inf!(), constants::pos_inf!(), 10, 10);
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EInvalidStrikeRange)]
fun insert_finite_below_grid_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(MIN_STRIKE - TICK_SIZE, 150, 10, 10);
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EInvalidStrikeRange)]
fun insert_finite_above_grid_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(150, MAX_STRIKE + TICK_SIZE, 10, 10);
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EUnalignedStrike)]
fun insert_unaligned_strike_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(115, 150, 10, 10);
    abort 999
}

// === remove_range ===

#[test]
fun insert_then_remove_restores_empty_state() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);

    tree.insert_range(120, 160, 50, 50);
    assert_eq!(tree.max_live_backing_payout(), 50);
    tree.remove_range(120, 160, 50, 50);
    assert_eq!(tree.max_live_backing_payout(), 0);

    tree.destroy();
}

#[test]
fun insert_two_then_remove_one_leaves_other() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);

    tree.insert_range(110, 160, 40, 40);
    tree.insert_range(130, 170, 30, 30);
    assert_eq!(tree.max_live_backing_payout(), 70);

    tree.remove_range(130, 170, 30, 30);
    assert_eq!(tree.max_live_backing_payout(), 40);

    tree.destroy();
}

#[test, expected_failure(abort_code = strike_payout_tree::EInsufficientPayoutTerms)]
fun remove_more_than_inserted_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(120, 160, 50, 50);
    // Bump both terms together so the EInvalidPayoutTerms shape check passes
    // and the failure surfaces in the boundary delta's available-terms check.
    tree.remove_range(120, 160, 51, 51);
    abort 999
}

#[test, expected_failure(abort_code = strike_payout_tree::EInsufficientPayoutTerms)]
fun remove_from_empty_tree_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.remove_range(120, 160, 1, 1);
    abort 999
}

// === settled_payout_liability ===

#[test]
fun settled_liability_zero_below_winning_range() {
    // (120, 160] only wins for settlement > 120.
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(120, 160, 50, 50);

    assert_eq!(tree.settled_payout_liability(120), 0);
    assert_eq!(tree.settled_payout_liability(110), 0);
    tree.destroy();
}

#[test]
fun settled_liability_owed_inside_winning_range() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(120, 160, 50, 50);

    // (120, 160] means winning for settlement in {130, 140, 150, 160}.
    assert_eq!(tree.settled_payout_liability(130), 50);
    assert_eq!(tree.settled_payout_liability(160), 50);
    tree.destroy();
}

#[test]
fun settled_liability_zero_above_winning_range() {
    // (120, 160] does not win for settlement > 160. The boundary at 160 closes
    // the range out at strike+1.
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(120, 160, 50, 50);

    assert_eq!(tree.settled_payout_liability(170), 0);
    assert_eq!(tree.settled_payout_liability(MAX_STRIKE), 0);
    tree.destroy();
}

#[test]
fun settled_liability_neg_inf_range_owed_until_close() {
    // (neg_inf, 150] wins for all settlement <= 150.
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(constants::neg_inf!(), 150, 100, 100);

    assert_eq!(tree.settled_payout_liability(MIN_STRIKE), 100);
    assert_eq!(tree.settled_payout_liability(150), 100);
    assert_eq!(tree.settled_payout_liability(160), 0);
    tree.destroy();
}

#[test]
fun settled_liability_pos_inf_range_owed_from_lower() {
    // (150, pos_inf] wins for all settlement > 150.
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(150, constants::pos_inf!(), 100, 100);

    assert_eq!(tree.settled_payout_liability(150), 0);
    assert_eq!(tree.settled_payout_liability(160), 100);
    assert_eq!(tree.settled_payout_liability(MAX_STRIKE), 100);
    tree.destroy();
}

#[test]
fun settled_liability_sums_multiple_winners() {
    // Settlement 150 wins for both (120, 160] (terminal 50) and
    // (140, 170] (terminal 30). Settlement 165 wins only the second.
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(120, 160, 50, 50);
    tree.insert_range(140, 170, 30, 30);

    assert_eq!(tree.settled_payout_liability(150), 80);
    assert_eq!(tree.settled_payout_liability(165), 30);
    assert_eq!(tree.settled_payout_liability(180), 0);
    tree.destroy();
}

#[test]
fun settled_liability_uses_terminal_not_backing() {
    // Terminal payout < live backing (e.g. when an order has a floor that
    // grows between open and expiry). settled_payout_liability must report
    // the terminal value, not the (larger) live-backing value.
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.insert_range(120, 160, 30, 50);

    assert_eq!(tree.settled_payout_liability(150), 30);
    // Live backing peak still reflects 50.
    assert_eq!(tree.max_live_backing_payout(), 50);
    tree.destroy();
}

// === destroy ===

#[test]
fun destroy_after_many_inserts_succeeds() {
    let ctx = &mut tx_context::dummy();
    let mut tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    // Insert across every finite boundary in the grid to exercise the treap's
    // node-by-node destroy path.
    let mut s = MIN_STRIKE;
    while (s < MAX_STRIKE) {
        tree.insert_range(s, s + TICK_SIZE, 1, 1);
        s = s + TICK_SIZE;
    };
    tree.destroy();
}

#[test]
fun destroy_empty_tree() {
    let ctx = &mut tx_context::dummy();
    let tree = strike_payout_tree::new(MIN_STRIKE, TICK_SIZE, MAX_STRIKE, ctx);
    tree.destroy();
}
