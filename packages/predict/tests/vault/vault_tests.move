// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::vault_tests;

use deepbook_predict::{constants, generated_oracle as go, oracle, oracle_helper, vault};
use std::unit_test::{assert_eq, destroy};
use sui::{balance, clock, sui::SUI};

const QTY: u64 = 10_000_000; // 10 units at 1e6 quote precision.
const MAX_EXPOSURE_PCT_80: u64 = 800_000_000; // 80%
const MAX_EXPOSURE_PCT_50: u64 = 500_000_000; // 50%
const ORACLE_SCENARIO_S0: u64 = 7;
const ORACLE_SCENARIO_S4: u64 = 11;
const ORACLE_SCENARIO_S5: u64 = 12;

fun create_test_vault(
    settlement_price: u64,
    ctx: &mut TxContext,
): (vault::Vault<SUI>, oracle::OracleSVI, clock::Clock) {
    let v = vault::new<SUI>(ctx);
    let oracle = oracle_helper::create_settled_oracle(settlement_price, ctx);
    let clock = clock::create_for_testing(ctx);
    (v, oracle, clock)
}

/// Scale an externally generated binary price into MTM for the fixed test quantity.
/// This does not reimplement vault risk logic; it only converts generated oracle prices
/// into quote units so tests can compare vault output to independent fixture data.
fun expected_mtm(sp: &go::StrikePoint, is_up: bool): u64 {
    let price = if (is_up) sp.expected_up() else sp.expected_dn();
    (((QTY as u128) * (price as u128) / (constants::float_scaling!() as u128)) as u64)
}

fun create_generated_oracle(
    idx: u64,
    ctx: &mut TxContext,
): (go::OracleScenario, oracle::OracleSVI, clock::Clock) {
    let scenario = go::scenarios()[idx];
    let (oracle, clock) = oracle_helper::create_from_scenario(&scenario, ctx);
    (scenario, oracle, clock)
}

fun create_live_oracle_s0(
    ctx: &mut TxContext,
): (go::OracleScenario, oracle::OracleSVI, clock::Clock) {
    create_generated_oracle(ORACLE_SCENARIO_S0, ctx)
}

fun create_live_oracle_s4(
    ctx: &mut TxContext,
): (go::OracleScenario, oracle::OracleSVI, clock::Clock) {
    create_generated_oracle(ORACLE_SCENARIO_S4, ctx)
}

fun create_live_oracle_s5(
    ctx: &mut TxContext,
): (go::OracleScenario, oracle::OracleSVI, clock::Clock) {
    create_generated_oracle(ORACLE_SCENARIO_S5, ctx)
}

#[test]
/// A new vault should start with zero balance, zero MTM, and zero payout liability.
fun new_vault_initializes_to_zero() {
    let ctx = &mut tx_context::dummy();
    let v = vault::new<SUI>(ctx);

    assert_eq!(vault::balance(&v), 0);
    assert_eq!(vault::total_mtm(&v), 0);
    assert_eq!(vault::total_max_payout(&v), 0);
    assert_eq!(vault::vault_value(&v), 0);

    destroy(v);
}

#[test]
/// Accepting payment should increase vault balance by the deposited amount.
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
/// Dispensing payout should split vault balance and reduce stored balance accordingly.
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

#[test, expected_failure(abort_code = vault::EInsufficientBalance)]
/// Dispensing more than the current balance should abort.
fun dispense_payout_exceeds_balance_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);

    let payment = balance::create_for_testing<SUI>(1_000_000);
    vault::accept_payment(&mut v, payment);

    let _payout = vault::dispense_payout(&mut v, 1_000_001);

    abort
}

#[test]
/// A single winning position should set max payout equal to its contract quantity.
fun insert_single_position_max_payout() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(200 * constants::float_scaling!(), ctx);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        10 * constants::float_scaling!(),
        &clock,
        ctx,
    );
    assert_eq!(vault::total_max_payout(&v), 10 * constants::float_scaling!());

    vault::insert_position(
        &mut v,
        &oracle,
        false,
        50 * constants::float_scaling!(),
        8 * constants::float_scaling!(),
        &clock,
        ctx,
    );
    assert_eq!(vault::total_max_payout(&v), 10 * constants::float_scaling!());

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Opposite-direction exposure at the same strike should use the larger directional payout.
fun insert_same_strike_dn_exceeds_up_max_payout() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(200 * constants::float_scaling!(), ctx);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        5 * constants::float_scaling!(),
        &clock,
        ctx,
    );
    vault::insert_position(
        &mut v,
        &oracle,
        false,
        50 * constants::float_scaling!(),
        12 * constants::float_scaling!(),
        &clock,
        ctx,
    );

    assert_eq!(vault::total_max_payout(&v), 12 * constants::float_scaling!());

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Winning exposure across two UP strikes should add linearly in the settled step curve.
fun insert_different_strikes_max_payout() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(200 * constants::float_scaling!(), ctx);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        30 * constants::float_scaling!(),
        5 * constants::float_scaling!(),
        &clock,
        ctx,
    );
    vault::insert_position(
        &mut v,
        &oracle,
        true,
        70 * constants::float_scaling!(),
        5 * constants::float_scaling!(),
        &clock,
        ctx,
    );

    assert_eq!(vault::total_max_payout(&v), 10 * constants::float_scaling!());

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Mixed-direction winning exposure across different strikes should add into total payout.
fun insert_different_strikes_mixed_directions_max_payout() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(200 * constants::float_scaling!(), ctx);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        30 * constants::float_scaling!(),
        8 * constants::float_scaling!(),
        &clock,
        ctx,
    );
    vault::insert_position(
        &mut v,
        &oracle,
        false,
        70 * constants::float_scaling!(),
        6 * constants::float_scaling!(),
        &clock,
        ctx,
    );

    assert_eq!(vault::total_max_payout(&v), 14 * constants::float_scaling!());

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Removing part of a settled winning position should reduce both MTM and max payout.
fun remove_position_decreases_max_payout_and_mtm() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(200 * constants::float_scaling!(), ctx);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        10 * constants::float_scaling!(),
        &clock,
        ctx,
    );
    assert_eq!(vault::total_max_payout(&v), 10 * constants::float_scaling!());
    assert_eq!(vault::total_mtm(&v), 10 * constants::float_scaling!());

    vault::remove_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        4 * constants::float_scaling!(),
        &clock,
    );
    assert_eq!(vault::total_max_payout(&v), 6 * constants::float_scaling!());
    assert_eq!(vault::total_mtm(&v), 6 * constants::float_scaling!());

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Removing the full position should clear cached payout liability for that oracle.
fun remove_all_positions_returns_max_payout_to_zero() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(200 * constants::float_scaling!(), ctx);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        10 * constants::float_scaling!(),
        &clock,
        ctx,
    );
    vault::remove_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        10 * constants::float_scaling!(),
        &clock,
    );

    assert_eq!(vault::total_max_payout(&v), 0);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test, expected_failure(abort_code = vault::EOracleExposureNotFound)]
/// Removing exposure for an oracle with no tracked treap should abort.
fun remove_from_nonexistent_oracle_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(200 * constants::float_scaling!(), ctx);

    vault::remove_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        5 * constants::float_scaling!(),
        &clock,
    );

    abort
}

#[test]
/// Total exposure check should pass when MTM stays below the configured percentage of balance.
fun assert_total_exposure_passes_when_within_limit() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(200 * constants::float_scaling!(), ctx);

    let payment = balance::create_for_testing<SUI>(100 * constants::float_scaling!());
    vault::accept_payment(&mut v, payment);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        10 * constants::float_scaling!(),
        &clock,
        ctx,
    );

    vault::assert_total_exposure(&v, MAX_EXPOSURE_PCT_80);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test, expected_failure(abort_code = vault::EExceedsMaxTotalExposure)]
/// Total exposure check should fail when MTM exceeds the configured budget.
fun assert_total_exposure_fails_when_exceeds_limit() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(200 * constants::float_scaling!(), ctx);

    let payment = balance::create_for_testing<SUI>(10 * constants::float_scaling!());
    vault::accept_payment(&mut v, payment);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        10 * constants::float_scaling!(),
        &clock,
        ctx,
    );

    vault::assert_total_exposure(&v, MAX_EXPOSURE_PCT_50);

    abort
}

#[test]
/// Total exposure should pass exactly on the 100% utilization boundary.
fun assert_total_exposure_passes_at_exact_boundary() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(200 * constants::float_scaling!(), ctx);

    let payment = balance::create_for_testing<SUI>(10 * constants::float_scaling!());
    vault::accept_payment(&mut v, payment);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        10 * constants::float_scaling!(),
        &clock,
        ctx,
    );

    vault::assert_total_exposure(&v, constants::float_scaling!());

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Vault value is free balance after subtracting cached MTM liability.
fun vault_value_equals_balance_minus_mtm() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(200 * constants::float_scaling!(), ctx);

    let payment = balance::create_for_testing<SUI>(100 * constants::float_scaling!());
    vault::accept_payment(&mut v, payment);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        10 * constants::float_scaling!(),
        &clock,
        ctx,
    );

    assert_eq!(vault::vault_value(&v), 90 * constants::float_scaling!());

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Vault value should be exactly zero when balance matches cached MTM liability.
fun vault_value_zero_at_exact_mtm_boundary() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(200 * constants::float_scaling!(), ctx);

    let payment = balance::create_for_testing<SUI>(10 * constants::float_scaling!());
    vault::accept_payment(&mut v, payment);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        10 * constants::float_scaling!(),
        &clock,
        ctx,
    );

    assert_eq!(vault::vault_value(&v), 0);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Losing settled exposure contributes zero MTM, so vault value equals raw balance.
fun vault_value_zero_mtm() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(10 * constants::float_scaling!(), ctx);

    let payment = balance::create_for_testing<SUI>(100 * constants::float_scaling!());
    vault::accept_payment(&mut v, payment);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        10 * constants::float_scaling!(),
        &clock,
        ctx,
    );

    assert_eq!(vault::total_mtm(&v), 0);
    assert_eq!(vault::vault_value(&v), 100 * constants::float_scaling!());

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test, expected_failure(abort_code = vault::EMtmExceedsBalance)]
/// Vault value should abort when cached MTM exceeds available balance.
fun vault_value_aborts_when_mtm_exceeds_balance() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(200 * constants::float_scaling!(), ctx);

    let payment = balance::create_for_testing<SUI>(5 * constants::float_scaling!());
    vault::accept_payment(&mut v, payment);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        10 * constants::float_scaling!(),
        &clock,
        ctx,
    );

    let _val = vault::vault_value(&v);

    abort
}

#[test, expected_failure(abort_code = vault::EExceedsMaxTotalExposure)]
/// Any nonzero liability should fail the exposure check when vault balance is zero.
fun assert_total_exposure_zero_balance_with_liability_fails() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(200 * constants::float_scaling!(), ctx);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        10 * constants::float_scaling!(),
        &clock,
        ctx,
    );

    vault::assert_total_exposure(&v, MAX_EXPOSURE_PCT_80);

    abort
}

#[test]
/// A settled DOWN position wins when settlement is below strike.
fun mtm_dn_wins_settled_below_strike() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(30 * constants::float_scaling!(), ctx);

    vault::insert_position(
        &mut v,
        &oracle,
        false,
        50 * constants::float_scaling!(),
        8 * constants::float_scaling!(),
        &clock,
        ctx,
    );

    assert_eq!(vault::total_mtm(&v), 8 * constants::float_scaling!());

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// A settled DOWN position loses when settlement is above strike.
fun mtm_dn_loses_settled_above_strike() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(200 * constants::float_scaling!(), ctx);

    vault::insert_position(
        &mut v,
        &oracle,
        false,
        50 * constants::float_scaling!(),
        8 * constants::float_scaling!(),
        &clock,
        ctx,
    );

    assert_eq!(vault::total_mtm(&v), 0);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Multiple settled winning positions should accumulate MTM across strikes.
fun mtm_multiple_positions_both_win() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(200 * constants::float_scaling!(), ctx);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        5 * constants::float_scaling!(),
        &clock,
        ctx,
    );
    vault::insert_position(
        &mut v,
        &oracle,
        true,
        80 * constants::float_scaling!(),
        7 * constants::float_scaling!(),
        &clock,
        ctx,
    );

    assert_eq!(vault::total_mtm(&v), 12 * constants::float_scaling!());

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Mixed settled UP and DOWN winners should both contribute to total MTM.
fun mtm_mixed_directions_settled() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(60 * constants::float_scaling!(), ctx);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        10 * constants::float_scaling!(),
        &clock,
        ctx,
    );
    vault::insert_position(
        &mut v,
        &oracle,
        false,
        70 * constants::float_scaling!(),
        6 * constants::float_scaling!(),
        &clock,
        ctx,
    );

    assert_eq!(vault::total_mtm(&v), 16 * constants::float_scaling!());

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Inserting and then partially removing settled exposure should keep cached aggregates consistent.
fun insert_and_remove_lifecycle() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let clock = clock::create_for_testing(ctx);

    let payment = balance::create_for_testing<SUI>(100 * constants::float_scaling!());
    vault::accept_payment(&mut v, payment);

    let oracle = oracle_helper::create_settled_oracle(200 * constants::float_scaling!(), ctx);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        30 * constants::float_scaling!(),
        5 * constants::float_scaling!(),
        &clock,
        ctx,
    );
    vault::insert_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        10 * constants::float_scaling!(),
        &clock,
        ctx,
    );
    vault::insert_position(
        &mut v,
        &oracle,
        true,
        70 * constants::float_scaling!(),
        8 * constants::float_scaling!(),
        &clock,
        ctx,
    );

    assert_eq!(vault::total_mtm(&v), 23 * constants::float_scaling!());
    assert_eq!(vault::total_max_payout(&v), 23 * constants::float_scaling!());
    assert_eq!(vault::vault_value(&v), 77 * constants::float_scaling!());

    vault::remove_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        10 * constants::float_scaling!(),
        &clock,
    );

    assert_eq!(vault::total_mtm(&v), 13 * constants::float_scaling!());
    assert_eq!(vault::total_max_payout(&v), 13 * constants::float_scaling!());
    assert_eq!(vault::vault_value(&v), 87 * constants::float_scaling!());

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// UP binary settles strictly above strike, so equality should produce zero UP payout.
fun mtm_at_settlement_boundary() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let clock = clock::create_for_testing(ctx);

    let settlement = 50 * constants::float_scaling!();
    let oracle = oracle_helper::create_settled_oracle(settlement, ctx);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        settlement,
        10 * constants::float_scaling!(),
        &clock,
        ctx,
    );
    assert_eq!(vault::total_mtm(&v), 0);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// DOWN binary wins at the settlement boundary because UP requires settlement > strike.
fun mtm_dn_wins_at_settlement_boundary() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let clock = clock::create_for_testing(ctx);

    let settlement = 50 * constants::float_scaling!();
    let oracle = oracle_helper::create_settled_oracle(settlement, ctx);

    vault::insert_position(
        &mut v,
        &oracle,
        false,
        settlement,
        10 * constants::float_scaling!(),
        &clock,
        ctx,
    );
    assert_eq!(vault::total_mtm(&v), 10 * constants::float_scaling!());

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Empty vault should trivially satisfy total exposure checks.
fun assert_total_exposure_with_empty_vault() {
    let ctx = &mut tx_context::dummy();
    let v = vault::new<SUI>(ctx);

    vault::assert_total_exposure(&v, MAX_EXPOSURE_PCT_80);

    destroy(v);
}

#[test]
/// Removing one oracle's positions should not disturb cached risk for another oracle.
fun remove_from_one_oracle_does_not_affect_other() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let clock = clock::create_for_testing(ctx);

    let oracle1 = oracle_helper::create_settled_oracle(200 * constants::float_scaling!(), ctx);
    let oracle2 = oracle_helper::create_settled_oracle(10 * constants::float_scaling!(), ctx);

    vault::insert_position(
        &mut v,
        &oracle1,
        true,
        50 * constants::float_scaling!(),
        5 * constants::float_scaling!(),
        &clock,
        ctx,
    );
    vault::insert_position(
        &mut v,
        &oracle2,
        false,
        50 * constants::float_scaling!(),
        3 * constants::float_scaling!(),
        &clock,
        ctx,
    );

    assert_eq!(vault::total_mtm(&v), 8 * constants::float_scaling!());
    assert_eq!(vault::total_max_payout(&v), 8 * constants::float_scaling!());

    vault::remove_position(
        &mut v,
        &oracle1,
        true,
        50 * constants::float_scaling!(),
        5 * constants::float_scaling!(),
        &clock,
    );

    assert_eq!(vault::total_mtm(&v), 3 * constants::float_scaling!());
    assert_eq!(vault::total_max_payout(&v), 3 * constants::float_scaling!());

    destroy(v);
    destroy(oracle1);
    destroy(oracle2);
    destroy(clock);
}

#[test]
/// Vault can dispense balance below max payout; the risk check is performed separately.
fun dispense_payout_reduces_balance_below_max_payout() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(200 * constants::float_scaling!(), ctx);

    let payment = balance::create_for_testing<SUI>(100 * constants::float_scaling!());
    vault::accept_payment(&mut v, payment);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        50 * constants::float_scaling!(),
        &clock,
        ctx,
    );
    assert_eq!(vault::total_max_payout(&v), 50 * constants::float_scaling!());

    let payout = vault::dispense_payout(&mut v, 60 * constants::float_scaling!());
    assert_eq!(vault::balance(&v), 40 * constants::float_scaling!());
    assert_eq!(payout.value(), 60 * constants::float_scaling!());

    destroy(payout);
    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// After fully removing an oracle's exposure, reinserting should rebuild MTM and payout cleanly.
fun reinsert_after_full_removal() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(200 * constants::float_scaling!(), ctx);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        10 * constants::float_scaling!(),
        &clock,
        ctx,
    );
    assert_eq!(vault::total_mtm(&v), 10 * constants::float_scaling!());
    vault::remove_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        10 * constants::float_scaling!(),
        &clock,
    );
    assert_eq!(vault::total_mtm(&v), 0);
    assert_eq!(vault::total_max_payout(&v), 0);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        7 * constants::float_scaling!(),
        &clock,
        ctx,
    );
    assert_eq!(vault::total_mtm(&v), 7 * constants::float_scaling!());
    assert_eq!(vault::total_max_payout(&v), 7 * constants::float_scaling!());

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        80 * constants::float_scaling!(),
        3 * constants::float_scaling!(),
        &clock,
        ctx,
    );
    assert_eq!(vault::total_mtm(&v), 10 * constants::float_scaling!());
    assert_eq!(vault::total_max_payout(&v), 10 * constants::float_scaling!());

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Rebuilding exposure in the opposite direction after full removal should use fresh risk state.
fun reinsert_different_direction_after_full_removal() {
    let ctx = &mut tx_context::dummy();
    let (mut v, oracle, clock) = create_test_vault(200 * constants::float_scaling!(), ctx);

    vault::insert_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        10 * constants::float_scaling!(),
        &clock,
        ctx,
    );
    vault::remove_position(
        &mut v,
        &oracle,
        true,
        50 * constants::float_scaling!(),
        10 * constants::float_scaling!(),
        &clock,
    );

    vault::insert_position(
        &mut v,
        &oracle,
        false,
        50 * constants::float_scaling!(),
        5 * constants::float_scaling!(),
        &clock,
        ctx,
    );
    assert_eq!(vault::total_mtm(&v), 0);
    assert_eq!(vault::total_max_payout(&v), 5 * constants::float_scaling!());

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Live snapshot S0 ATM prices should flow through the vault curve into cached MTM.
fun mtm_live_oracle_s0_atm() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let (scenario, oracle, clock) = create_live_oracle_s0(ctx);
    let s = &scenario;
    let atm = &s.strike_points()[0];

    vault::insert_position(&mut v, &oracle, true, atm.strike(), QTY, &clock, ctx);
    assert_eq!(vault::total_mtm(&v), expected_mtm(atm, true));

    vault::insert_position(&mut v, &oracle, false, atm.strike(), QTY, &clock, ctx);
    let exp_total = expected_mtm(atm, true) + expected_mtm(atm, false);
    assert_eq!(vault::total_mtm(&v), exp_total);

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Live snapshot S0 OTM UP pricing should match generated oracle fixture data.
fun mtm_live_oracle_s0_otm() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let (scenario, oracle, clock) = create_live_oracle_s0(ctx);
    let s = &scenario;
    let otm10 = &s.strike_points()[2];

    vault::insert_position(&mut v, &oracle, true, otm10.strike(), QTY, &clock, ctx);
    assert_eq!(vault::total_mtm(&v), expected_mtm(otm10, true));

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Near-expiry snapshot S4 should still evaluate to the generated live oracle price.
fun mtm_live_oracle_s4_near_expiry() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let (scenario, oracle, clock) = create_live_oracle_s4(ctx);
    let s = &scenario;
    let atm = &s.strike_points()[0];

    vault::insert_position(&mut v, &oracle, true, atm.strike(), QTY, &clock, ctx);
    assert_eq!(vault::total_mtm(&v), expected_mtm(atm, true));

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Extreme near-expiry snapshot S5 should refresh correctly across remove/reinsert cycles.
fun mtm_live_oracle_s5_extreme_near_expiry() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let (scenario, oracle, clock) = create_live_oracle_s5(ctx);
    let s = &scenario;
    let atm = &s.strike_points()[0];
    let itm10 = &s.strike_points()[4];

    vault::insert_position(&mut v, &oracle, true, atm.strike(), QTY, &clock, ctx);
    assert_eq!(vault::total_mtm(&v), expected_mtm(atm, true));

    vault::remove_position(&mut v, &oracle, true, atm.strike(), QTY, &clock);
    vault::insert_position(&mut v, &oracle, true, itm10.strike(), QTY, &clock, ctx);
    assert_eq!(vault::total_mtm(&v), expected_mtm(itm10, true));

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Live snapshot S0 OTM DOWN pricing should match generated oracle fixture data.
fun mtm_live_oracle_s0_dn_otm10() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let (scenario, oracle, clock) = create_live_oracle_s0(ctx);
    let s = &scenario;
    let otm10 = &s.strike_points()[2];

    vault::insert_position(&mut v, &oracle, false, otm10.strike(), QTY, &clock, ctx);
    assert_eq!(vault::total_mtm(&v), expected_mtm(otm10, false));

    destroy(v);
    destroy(oracle);
    destroy(clock);
}

#[test]
/// Live snapshot S5 ATM DOWN pricing should match generated oracle fixture data.
fun mtm_live_oracle_s5_dn_atm() {
    let ctx = &mut tx_context::dummy();
    let mut v = vault::new<SUI>(ctx);
    let (scenario, oracle, clock) = create_live_oracle_s5(ctx);
    let s = &scenario;
    let atm = &s.strike_points()[0];

    vault::insert_position(&mut v, &oracle, false, atm.strike(), QTY, &clock, ctx);
    assert_eq!(vault::total_mtm(&v), expected_mtm(atm, false));

    destroy(v);
    destroy(oracle);
    destroy(clock);
}
