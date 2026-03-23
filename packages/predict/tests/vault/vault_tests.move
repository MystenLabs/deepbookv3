// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::vault_tests;

use deepbook_predict::{oracle::{Self, new_price_data, new_svi_params}, vault};
use std::unit_test::{assert_eq, destroy};
use sui::{balance, clock, sui::SUI};

const FLOAT: u64 = 1_000_000_000;

/// Helper: create a settled oracle at the given settlement price.
/// Uses dummy SVI params (irrelevant once settled).
fun create_settled_oracle(settlement_price: u64, ctx: &mut TxContext): oracle::OracleSVI {
    let svi = new_svi_params(0, 0, 0, false, 0, false, FLOAT / 4);
    let prices = new_price_data(100 * FLOAT, 100 * FLOAT);
    let mut oracle = oracle::create_test_oracle(
        b"BTC".to_string(),
        svi,
        prices,
        0,
        100_000,
        0,
        ctx,
    );
    oracle::settle_test_oracle(&mut oracle, settlement_price);
    oracle
}

// ============================================================
// 1. Construction
// ============================================================

#[test]
fun new_vault_has_zero_balance() {
    let ctx = &mut tx_context::dummy();
    let v = vault::new<SUI>(ctx);

    assert_eq!(vault::balance(&v), 0);

    destroy(v);
}

#[test]
fun new_vault_has_zero_total_mtm() {
    let ctx = &mut tx_context::dummy();
    let v = vault::new<SUI>(ctx);

    assert_eq!(vault::total_mtm(&v), 0);

    destroy(v);
}

#[test]
fun new_vault_has_zero_total_max_payout() {
    let ctx = &mut tx_context::dummy();
    let v = vault::new<SUI>(ctx);

    assert_eq!(vault::total_max_payout(&v), 0);

    destroy(v);
}

#[test]
fun new_vault_has_zero_vault_value() {
    let ctx = &mut tx_context::dummy();
    let v = vault::new<SUI>(ctx);

    assert_eq!(vault::vault_value(&v), 0);

    destroy(v);
}

// ============================================================
// 2. accept_payment / dispense_payout
// ============================================================

#[test]
fun accept_payment_increases_balance() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);

    let payment = balance::create_for_testing<SUI>(1_000_000);
    vault::accept_payment(&mut v, payment);
    assert_eq!(vault::balance(&v), 1_000_000);

    let payment2 = balance::create_for_testing<SUI>(500_000);
    vault::accept_payment(&mut v, payment2);
    assert_eq!(vault::balance(&v), 1_500_000);

    destroy(v);
}

#[test]
fun dispense_payout_decreases_balance() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);

    let payment = balance::create_for_testing<SUI>(1_000_000);
    vault::accept_payment(&mut v, payment);

    let payout = vault::dispense_payout(&mut v, 400_000);
    assert_eq!(vault::balance(&v), 600_000);
    assert_eq!(payout.value(), 400_000);

    destroy(payout);
    destroy(v);
}

#[test]
fun dispense_payout_exact_balance() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);

    let payment = balance::create_for_testing<SUI>(1_000_000);
    vault::accept_payment(&mut v, payment);

    let payout = vault::dispense_payout(&mut v, 1_000_000);
    assert_eq!(vault::balance(&v), 0);
    assert_eq!(payout.value(), 1_000_000);

    destroy(payout);
    destroy(v);
}

#[test, expected_failure(abort_code = vault::EInsufficientBalance)]
fun dispense_payout_exceeds_balance_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);

    let payment = balance::create_for_testing<SUI>(1_000_000);
    vault::accept_payment(&mut v, payment);

    let _payout = vault::dispense_payout(&mut v, 1_000_001);

    abort
}

#[test, expected_failure(abort_code = vault::EInsufficientBalance)]
fun dispense_payout_from_empty_vault_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);

    let _payout = vault::dispense_payout(&mut v, 1);

    abort
}

// ============================================================
// 3. insert_position - max_payout tracking
// ============================================================

#[test]
fun insert_single_up_position_max_payout() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    // Single UP position with quantity 10 * FLOAT.
    // max_payout for a single UP = quantity = 10 * FLOAT
    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock, ctx);

    assert_eq!(vault::total_max_payout(&v), 10 * FLOAT);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
fun insert_single_dn_position_max_payout() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    // Single DN position with quantity 8 * FLOAT.
    // max_payout for a single DN = quantity = 8 * FLOAT
    vault::insert_position(&mut v, &oracle, false, 50 * FLOAT, 8 * FLOAT, &clock, ctx);

    assert_eq!(vault::total_max_payout(&v), 8 * FLOAT);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
fun insert_same_strike_both_directions_max_payout() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    // At same strike: max_payout = max(total_up, total_dn)
    // Insert UP=10, DN=6 at same strike
    // max_payout = max(10, 6) = 10
    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock, ctx);
    vault::insert_position(&mut v, &oracle, false, 50 * FLOAT, 6 * FLOAT, &clock, ctx);

    assert_eq!(vault::total_max_payout(&v), 10 * FLOAT);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
fun insert_same_strike_dn_exceeds_up_max_payout() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    // UP=5, DN=12 at same strike
    // max_payout = max(5, 12) = 12
    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 5 * FLOAT, &clock, ctx);
    vault::insert_position(&mut v, &oracle, false, 50 * FLOAT, 12 * FLOAT, &clock, ctx);

    assert_eq!(vault::total_max_payout(&v), 12 * FLOAT);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
fun insert_different_strikes_max_payout() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    // Two UP positions at different strikes, each 5 * FLOAT.
    // Treap max_payout formula (from recompute_agg):
    //   max_payout = max(left_max_payout + node.q_dn + right_agg_q_dn,
    //                    left_agg_q_up + node.q_up + right_max_payout)
    //
    // For two UP-only nodes at strikes A < B:
    //   At worst case (settlement > both strikes), all UP wins.
    //   Total UP = 5 + 5 = 10, Total DN = 0.
    //   max_payout = max(0 + 0 + 0, 5 + 5 + 0) = 10 (or equivalent permutation)
    vault::insert_position(&mut v, &oracle, true, 30 * FLOAT, 5 * FLOAT, &clock, ctx);
    vault::insert_position(&mut v, &oracle, true, 70 * FLOAT, 5 * FLOAT, &clock, ctx);

    assert_eq!(vault::total_max_payout(&v), 10 * FLOAT);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
fun insert_different_strikes_mixed_directions_max_payout() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    // Strike 30: UP=8, Strike 70: DN=6
    // The max_payout considers worst case across all settlement prices:
    // - If settlement < 30: UP at 30 loses (0), DN at 70 wins (6). Payout = 6.
    // - If 30 < settlement < 70: UP at 30 wins (8), DN at 70 wins (6). Payout = 14.
    //   Wait -- DN at 70 wins when settlement <= 70, which it is. UP at 30 wins when settlement > 30. Both win.
    //   Actually for treap max_payout:
    //   For nodes at strikes 30(UP=8) and 70(DN=6), the treap computes
    //   max_payout = max(left_max_payout + node.q_dn + right_agg_q_dn,
    //                    left_agg_q_up + node.q_up + right_max_payout)
    //   The formula tracks worst-case payout to the vault.
    //   With 30 as left child, 70 as right child (or vice versa depending on priority):
    //
    //   If 30 is root, 70 is right child:
    //     node(30): q_up=8, q_dn=0
    //     right(70): q_up=0, q_dn=6, max_payout=6, agg_q_dn=6
    //     max_payout = max(0 + 0 + 6, 0 + 8 + 6) = max(6, 14) = 14
    //
    //   If 70 is root, 30 is left child:
    //     left(30): q_up=8, q_dn=0, max_payout=8, agg_q_up=8
    //     node(70): q_up=0, q_dn=6
    //     max_payout = max(8 + 6 + 0, 8 + 0 + 0) = max(14, 8) = 14
    //
    //   Either way: max_payout = 14
    vault::insert_position(&mut v, &oracle, true, 30 * FLOAT, 8 * FLOAT, &clock, ctx);
    vault::insert_position(&mut v, &oracle, false, 70 * FLOAT, 6 * FLOAT, &clock, ctx);

    assert_eq!(vault::total_max_payout(&v), 14 * FLOAT);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

// ============================================================
// 4. remove_position
// ============================================================

#[test]
fun remove_position_decreases_max_payout() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock, ctx);
    assert_eq!(vault::total_max_payout(&v), 10 * FLOAT);

    vault::remove_position(&mut v, &oracle, true, 50 * FLOAT, 4 * FLOAT, &clock);
    // Remaining UP=6 at strike 50, max_payout = 6
    assert_eq!(vault::total_max_payout(&v), 6 * FLOAT);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
fun remove_all_positions_returns_max_payout_to_zero() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock, ctx);
    vault::remove_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock);

    assert_eq!(vault::total_max_payout(&v), 0);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test, expected_failure(abort_code = vault::EOracleExposureNotFound)]
fun remove_from_nonexistent_oracle_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    // No positions inserted for this oracle — should abort
    vault::remove_position(&mut v, &oracle, true, 50 * FLOAT, 5 * FLOAT, &clock);

    abort
}

// ============================================================
// 5. assert_total_exposure
// ============================================================

#[test]
fun assert_total_exposure_passes_when_within_limit() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    // Fund vault with 100 * FLOAT
    let payment = balance::create_for_testing<SUI>(100 * FLOAT);
    vault::accept_payment(&mut v, payment);

    // Insert UP at strike 50 with qty=10. Settlement at 200 means UP wins.
    // MTM after settle = 10 * FLOAT (UP wins, price = 1e9, mtm = qty * 1.0 = qty)
    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock, ctx);

    // total_mtm = 10 * FLOAT, balance = 100 * FLOAT
    // Check: 10 * FLOAT <= mul(100 * FLOAT, 800_000_000) = 80 * FLOAT. Passes.
    vault::assert_total_exposure(&v, 800_000_000);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test, expected_failure(abort_code = vault::EExceedsMaxTotalExposure)]
fun assert_total_exposure_fails_when_exceeds_limit() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    // Fund vault with 10 * FLOAT
    let payment = balance::create_for_testing<SUI>(10 * FLOAT);
    vault::accept_payment(&mut v, payment);

    // Insert UP at strike 50, qty=10. Settlement at 200 > 50, so UP wins.
    // MTM = 10 * FLOAT
    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock, ctx);

    // total_mtm = 10*FLOAT, balance = 10*FLOAT
    // Check: 10*FLOAT <= mul(10*FLOAT, 500_000_000) = 5*FLOAT. Fails.
    vault::assert_total_exposure(&v, 500_000_000);

    abort
}

#[test]
fun assert_total_exposure_passes_at_exact_boundary() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    // Fund vault with 10 * FLOAT
    let payment = balance::create_for_testing<SUI>(10 * FLOAT);
    vault::accept_payment(&mut v, payment);

    // Insert UP at strike 50, qty=10. MTM = 10 * FLOAT
    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock, ctx);

    // total_mtm = 10*FLOAT, balance = 10*FLOAT
    // mul(10*FLOAT, 1*FLOAT) = 10*FLOAT. 10*FLOAT <= 10*FLOAT. Passes (equal).
    vault::assert_total_exposure(&v, FLOAT);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

// ============================================================
// 6. vault_value with MTM
// ============================================================

#[test]
fun vault_value_equals_balance_minus_mtm() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    // Fund vault
    let payment = balance::create_for_testing<SUI>(100 * FLOAT);
    vault::accept_payment(&mut v, payment);

    // Insert UP at strike 50, qty=10. Settlement 200 > 50 => UP wins, MTM = 10*FLOAT
    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock, ctx);

    // vault_value = balance - total_mtm = 100*FLOAT - 10*FLOAT = 90*FLOAT
    assert_eq!(vault::vault_value(&v), 90 * FLOAT);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
fun vault_value_zero_mtm() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let oracle = create_settled_oracle(10 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    // Fund vault
    let payment = balance::create_for_testing<SUI>(100 * FLOAT);
    vault::accept_payment(&mut v, payment);

    // Insert UP at strike 50, qty=10. Settlement 10 < 50 => UP loses, MTM = 0
    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock, ctx);

    assert_eq!(vault::total_mtm(&v), 0);
    assert_eq!(vault::vault_value(&v), 100 * FLOAT);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test, expected_failure(abort_code = vault::EMtmExceedsBalance)]
fun vault_value_aborts_when_mtm_exceeds_balance() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    // Fund vault with only 5 * FLOAT
    let payment = balance::create_for_testing<SUI>(5 * FLOAT);
    vault::accept_payment(&mut v, payment);

    // Insert UP at strike 50, qty=10. Settlement 200 > 50 => UP wins, MTM = 10*FLOAT
    // MTM (10*FLOAT) > balance (5*FLOAT)
    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock, ctx);

    let _val = vault::vault_value(&v);

    abort
}

// ============================================================
// 7. MTM refresh via settled oracles
// ============================================================

#[test]
fun mtm_up_wins_settled_above_strike() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    // Settlement at 200, strike at 50. Since 200 > 50, UP wins.
    // Settled curve: [(199, up=1e9, dn=0), (200, up=0, dn=1e9)]
    // Position at strike 50 < 199, so UP price = 1e9 (clamped to first point)
    // MTM = mul(qty, 1e9) = qty * 1e9 / 1e9 = qty = 10*FLOAT
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock, ctx);

    assert_eq!(vault::total_mtm(&v), 10 * FLOAT);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
fun mtm_up_loses_settled_below_strike() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    // Settlement at 30, strike at 50. Since 30 < 50, UP loses.
    // Settled curve: [(29, up=1e9, dn=0), (30, up=0, dn=1e9)]
    // Position at strike 50 > 30 (clamped to last point), UP price = 0
    // MTM = mul(qty, 0) = 0
    let oracle = create_settled_oracle(30 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock, ctx);

    assert_eq!(vault::total_mtm(&v), 0);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
fun mtm_dn_wins_settled_below_strike() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    // Settlement at 30, strike at 50. Since 30 <= 50, DN wins.
    // Settled curve: [(29, up=1e9, dn=0), (30, up=0, dn=1e9)]
    // Position at strike 50 > 30, DN price = 1e9 (clamped to last point)
    // MTM = mul(qty, 1e9) = qty = 8*FLOAT
    let oracle = create_settled_oracle(30 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    vault::insert_position(&mut v, &oracle, false, 50 * FLOAT, 8 * FLOAT, &clock, ctx);

    assert_eq!(vault::total_mtm(&v), 8 * FLOAT);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
fun mtm_dn_loses_settled_above_strike() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    // Settlement at 200, strike at 50. Since 200 > 50, DN loses.
    // Settled curve: [(199, up=1e9, dn=0), (200, up=0, dn=1e9)]
    // Position at strike 50 < 199, DN price = 0 (clamped to first point)
    // MTM = mul(qty, 0) = 0
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    vault::insert_position(&mut v, &oracle, false, 50 * FLOAT, 8 * FLOAT, &clock, ctx);

    assert_eq!(vault::total_mtm(&v), 0);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
fun mtm_multiple_positions_both_win() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    // Settlement at 200. Both positions at strikes below 200 with UP direction.
    // Both UP win. MTM = 5*FLOAT + 7*FLOAT = 12*FLOAT
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 5 * FLOAT, &clock, ctx);
    vault::insert_position(&mut v, &oracle, true, 80 * FLOAT, 7 * FLOAT, &clock, ctx);

    assert_eq!(vault::total_mtm(&v), 12 * FLOAT);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
fun mtm_mixed_directions_settled() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    // Settlement at 60*FLOAT.
    // Settled curve: [(60*FLOAT - 1, up=1e9, dn=0), (60*FLOAT, up=0, dn=1e9)]
    //
    // Position 1: UP at strike 50*FLOAT.
    //   50*FLOAT < 60*FLOAT - 1 = 59_999_999_999. UP clamped to first point = 1e9. MTM = 10*FLOAT
    //
    // Position 2: DN at strike 70*FLOAT.
    //   70*FLOAT > 60*FLOAT. DN clamped to last point = 1e9. MTM = 6*FLOAT
    //
    // Total MTM = 10*FLOAT + 6*FLOAT = 16*FLOAT
    let oracle = create_settled_oracle(60 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock, ctx);
    vault::insert_position(&mut v, &oracle, false, 70 * FLOAT, 6 * FLOAT, &clock, ctx);

    assert_eq!(vault::total_mtm(&v), 16 * FLOAT);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
fun mtm_decreases_after_remove() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    // Settlement at 200, strike 50 UP. UP wins.
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock, ctx);
    assert_eq!(vault::total_mtm(&v), 10 * FLOAT);

    // Remove 4 * FLOAT. Remaining = 6 * FLOAT, still UP winning.
    // MTM = 6 * FLOAT
    vault::remove_position(&mut v, &oracle, true, 50 * FLOAT, 4 * FLOAT, &clock);
    assert_eq!(vault::total_mtm(&v), 6 * FLOAT);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
fun mtm_returns_to_zero_after_full_remove() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock, ctx);
    assert_eq!(vault::total_mtm(&v), 10 * FLOAT);

    vault::remove_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock);
    assert_eq!(vault::total_mtm(&v), 0);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
fun mtm_with_two_oracles() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let clock = clock::create_for_testing(ctx);

    // Oracle 1: settled at 200, strike 50 UP wins. MTM = 5*FLOAT
    let oracle1 = create_settled_oracle(200 * FLOAT, ctx);
    vault::insert_position(&mut v, &oracle1, true, 50 * FLOAT, 5 * FLOAT, &clock, ctx);

    // Oracle 2: settled at 10, strike 50 DN wins. MTM = 3*FLOAT
    let oracle2 = create_settled_oracle(10 * FLOAT, ctx);
    vault::insert_position(&mut v, &oracle2, false, 50 * FLOAT, 3 * FLOAT, &clock, ctx);

    // Total MTM = 5 + 3 = 8*FLOAT
    assert_eq!(vault::total_mtm(&v), 8 * FLOAT);

    destroy(v);
    destroy(oracle1);
    destroy(oracle2);
    destroy(clock);
}

#[test]
fun insert_and_remove_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let clock = clock::create_for_testing(ctx);

    // Fund vault
    let payment = balance::create_for_testing<SUI>(100 * FLOAT);
    vault::accept_payment(&mut v, payment);

    // Oracle settled at 200, all UP positions win
    let oracle = create_settled_oracle(200 * FLOAT, ctx);

    // Insert 3 UP positions at different strikes, all below settlement
    vault::insert_position(&mut v, &oracle, true, 30 * FLOAT, 5 * FLOAT, &clock, ctx);
    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock, ctx);
    vault::insert_position(&mut v, &oracle, true, 70 * FLOAT, 8 * FLOAT, &clock, ctx);

    // All UP win: MTM = 5 + 10 + 8 = 23*FLOAT
    assert_eq!(vault::total_mtm(&v), 23 * FLOAT);
    // max_payout = total UP = 23*FLOAT
    assert_eq!(vault::total_max_payout(&v), 23 * FLOAT);
    // vault_value = 100 - 23 = 77*FLOAT
    assert_eq!(vault::vault_value(&v), 77 * FLOAT);

    // Remove the middle position
    vault::remove_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock);

    // MTM = 5 + 8 = 13*FLOAT
    assert_eq!(vault::total_mtm(&v), 13 * FLOAT);
    assert_eq!(vault::total_max_payout(&v), 13 * FLOAT);
    assert_eq!(vault::vault_value(&v), 87 * FLOAT);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

// ============================================================
// Edge cases
// ============================================================

#[test]
fun mtm_at_settlement_boundary() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let clock = clock::create_for_testing(ctx);

    // Settlement exactly at strike price.
    // Settled curve: [(strike - 1, up=1e9, dn=0), (strike, up=0, dn=1e9)]
    // Position at same strike as settlement: UP price at strike = 0 (last curve point)
    // So UP loses, DN wins at the boundary (at-the-money settles as DN win).
    let settlement = 50 * FLOAT;
    let oracle = create_settled_oracle(settlement, ctx);

    vault::insert_position(&mut v, &oracle, true, settlement, 10 * FLOAT, &clock, ctx);
    // UP at strike == settlement: clamped to last point (settlement), UP price = 0
    assert_eq!(vault::total_mtm(&v), 0);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
fun mtm_dn_wins_at_settlement_boundary() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let clock = clock::create_for_testing(ctx);

    let settlement = 50 * FLOAT;
    let oracle = create_settled_oracle(settlement, ctx);

    // DN at strike == settlement: clamped to last point, DN price = 1e9
    vault::insert_position(&mut v, &oracle, false, settlement, 10 * FLOAT, &clock, ctx);
    assert_eq!(vault::total_mtm(&v), 10 * FLOAT);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
fun multiple_oracles_independent_max_payout() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let clock = clock::create_for_testing(ctx);

    let oracle1 = create_settled_oracle(200 * FLOAT, ctx);
    let oracle2 = create_settled_oracle(10 * FLOAT, ctx);

    // Oracle1: UP at 50, qty=5. max_payout=5
    vault::insert_position(&mut v, &oracle1, true, 50 * FLOAT, 5 * FLOAT, &clock, ctx);
    // Oracle2: DN at 50, qty=3. max_payout=3
    vault::insert_position(&mut v, &oracle2, false, 50 * FLOAT, 3 * FLOAT, &clock, ctx);

    // total_max_payout = sum of per-oracle max_payouts = 5 + 3 = 8
    assert_eq!(vault::total_max_payout(&v), 8 * FLOAT);

    destroy(v);
    destroy(oracle1);
    destroy(oracle2);
    destroy(clock);
}

#[test]
fun assert_total_exposure_with_empty_vault() {
    let ctx = &mut tx_context::dummy();
    let v = vault::new<SUI>(ctx);

    // total_mtm = 0, balance = 0. mul(0, anything) = 0. 0 <= 0. Passes.
    vault::assert_total_exposure(&v, 800_000_000);

    destroy(v);
}

// ============================================================
// Cross-oracle independence
// ============================================================

#[test]
fun remove_from_one_oracle_does_not_affect_other() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let clock = clock::create_for_testing(ctx);

    let oracle1 = create_settled_oracle(200 * FLOAT, ctx);
    let oracle2 = create_settled_oracle(10 * FLOAT, ctx);

    // Oracle1: UP at 50, qty=5. UP wins → MTM=5, max_payout=5
    vault::insert_position(&mut v, &oracle1, true, 50 * FLOAT, 5 * FLOAT, &clock, ctx);
    // Oracle2: DN at 50, qty=3. DN wins → MTM=3, max_payout=3
    vault::insert_position(&mut v, &oracle2, false, 50 * FLOAT, 3 * FLOAT, &clock, ctx);

    assert_eq!(vault::total_mtm(&v), 8 * FLOAT);
    assert_eq!(vault::total_max_payout(&v), 8 * FLOAT);

    // Remove all from oracle1
    vault::remove_position(&mut v, &oracle1, true, 50 * FLOAT, 5 * FLOAT, &clock);

    // Oracle2 unaffected
    assert_eq!(vault::total_mtm(&v), 3 * FLOAT);
    assert_eq!(vault::total_max_payout(&v), 3 * FLOAT);

    destroy(v);
    destroy(oracle1);
    destroy(oracle2);
    destroy(clock);
}

#[test]
fun insert_and_remove_across_oracles_independently() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let clock = clock::create_for_testing(ctx);

    let oracle1 = create_settled_oracle(200 * FLOAT, ctx);
    let oracle2 = create_settled_oracle(10 * FLOAT, ctx);

    // Oracle1: UP at 50, qty=10. UP wins.
    vault::insert_position(&mut v, &oracle1, true, 50 * FLOAT, 10 * FLOAT, &clock, ctx);
    assert_eq!(vault::total_mtm(&v), 10 * FLOAT);

    // Oracle2: DN at 80, qty=7. DN wins (10 < 80).
    vault::insert_position(&mut v, &oracle2, false, 80 * FLOAT, 7 * FLOAT, &clock, ctx);
    assert_eq!(vault::total_mtm(&v), 17 * FLOAT);

    // Remove partial from oracle2
    vault::remove_position(&mut v, &oracle2, false, 80 * FLOAT, 3 * FLOAT, &clock);
    assert_eq!(vault::total_mtm(&v), 14 * FLOAT); // 10 + 4

    // Remove all from oracle1
    vault::remove_position(&mut v, &oracle1, true, 50 * FLOAT, 10 * FLOAT, &clock);
    assert_eq!(vault::total_mtm(&v), 4 * FLOAT); // only oracle2 remains

    // Remove rest from oracle2
    vault::remove_position(&mut v, &oracle2, false, 80 * FLOAT, 4 * FLOAT, &clock);
    assert_eq!(vault::total_mtm(&v), 0);
    assert_eq!(vault::total_max_payout(&v), 0);

    destroy(v);
    destroy(oracle1);
    destroy(oracle2);
    destroy(clock);
}

// ============================================================
// Dispense after positions
// ============================================================

#[test]
fun dispense_payout_reduces_balance_below_max_payout() {
    // The vault itself doesn't enforce balance >= max_payout.
    // That's predict.move's job. Verify raw vault allows it.
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    let payment = balance::create_for_testing<SUI>(100 * FLOAT);
    vault::accept_payment(&mut v, payment);

    // UP wins, max_payout = 50*FLOAT
    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 50 * FLOAT, &clock, ctx);
    assert_eq!(vault::total_max_payout(&v), 50 * FLOAT);

    // Dispense 60*FLOAT — puts balance (40) below max_payout (50)
    // Vault allows this; predict.move would block it
    let payout = vault::dispense_payout(&mut v, 60 * FLOAT);
    assert_eq!(vault::balance(&v), 40 * FLOAT);
    assert_eq!(payout.value(), 60 * FLOAT);

    destroy(payout);
    destroy(v);
    destroy(oracle);
    destroy(clock);
}

// ============================================================
// Re-insert after full removal
// ============================================================

#[test]
fun reinsert_after_full_removal() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    // Insert and fully remove
    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock, ctx);
    assert_eq!(vault::total_mtm(&v), 10 * FLOAT);
    vault::remove_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock);
    assert_eq!(vault::total_mtm(&v), 0);
    assert_eq!(vault::total_max_payout(&v), 0);

    // Re-insert at same strike — treap should re-create the node
    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 7 * FLOAT, &clock, ctx);
    assert_eq!(vault::total_mtm(&v), 7 * FLOAT);
    assert_eq!(vault::total_max_payout(&v), 7 * FLOAT);

    // Re-insert at different strike
    vault::insert_position(&mut v, &oracle, true, 80 * FLOAT, 3 * FLOAT, &clock, ctx);
    assert_eq!(vault::total_mtm(&v), 10 * FLOAT);
    assert_eq!(vault::total_max_payout(&v), 10 * FLOAT);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
fun reinsert_different_direction_after_full_removal() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let oracle = create_settled_oracle(200 * FLOAT, ctx);
    let clock = clock::create_for_testing(ctx);

    // Insert UP, fully remove
    vault::insert_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock, ctx);
    vault::remove_position(&mut v, &oracle, true, 50 * FLOAT, 10 * FLOAT, &clock);

    // Re-insert as DN at same strike. Settlement 200 > 50, so DN loses. MTM=0.
    vault::insert_position(&mut v, &oracle, false, 50 * FLOAT, 5 * FLOAT, &clock, ctx);
    assert_eq!(vault::total_mtm(&v), 0);
    assert_eq!(vault::total_max_payout(&v), 5 * FLOAT);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}
