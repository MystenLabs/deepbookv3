// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit tests for vault balance accounting, exposure tracking, and cached MTM.
#[test_only]
module deepbook_predict::vault_tests;

use deepbook_predict::{constants::float_scaling as float, oracle_config::new_curve_point, vault};
use std::unit_test::{assert_eq, destroy};
use sui::{balance, sui::SUI};

const ORACLE_1: address = @0x1;
const ORACLE_2: address = @0x2;

public struct ALTUSD has drop {}

fun oracle_id(addr: address): ID {
    object::id_from_address(addr)
}

fun init_matrix(vault: &mut vault::Vault, oracle_id: ID, ctx: &mut TxContext) {
    vault::init_oracle_matrix(
        vault,
        oracle_id,
        50 * float!(),
        150 * float!(),
        1 * float!(),
        ctx,
    );
}

#[test]
fun accept_payment_tracks_multiple_quote_assets() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new(ctx);

    vault::accept_payment(&mut vault, balance::create_for_testing<SUI>(1_000_000));
    vault::accept_payment(&mut vault, balance::create_for_testing<ALTUSD>(500_000));

    assert_eq!(vault::balance(&vault), 1_500_000);
    assert_eq!(vault::asset_balance<SUI>(&vault), 1_000_000);
    assert_eq!(vault::asset_balance<ALTUSD>(&vault), 500_000);

    destroy(vault);
}

#[test]
fun new_vault_initializes_to_zero() {
    let ctx = &mut tx_context::dummy();
    let vault = vault::new(ctx);

    assert_eq!(vault::balance(&vault), 0);
    assert_eq!(vault::total_mtm(&vault), 0);
    assert_eq!(vault::total_max_payout(&vault), 0);
    assert_eq!(vault::vault_value(&vault), 0);

    destroy(vault);
}

#[test]
fun accept_payment_increases_balance() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new(ctx);

    vault::accept_payment(&mut vault, balance::create_for_testing<SUI>(1_000_000));
    vault::accept_payment(&mut vault, balance::create_for_testing<SUI>(500_000));

    assert_eq!(vault::balance(&vault), 1_500_000);

    destroy(vault);
}

#[test]
fun dispense_payout_decreases_balance() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new(ctx);
    vault::accept_payment(&mut vault, balance::create_for_testing<SUI>(1_000_000));

    let payout = vault::dispense_payout<SUI>(&mut vault, 400_000);

    assert_eq!(vault::balance(&vault), 600_000);
    assert_eq!(payout.value(), 400_000);

    destroy(payout);
    destroy(vault);
}

#[test, expected_failure(abort_code = vault::EInsufficientBalance)]
fun dispense_payout_exceeds_balance_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new(ctx);
    vault::accept_payment(&mut vault, balance::create_for_testing<SUI>(1_000_000));

    let _payout = vault::dispense_payout<SUI>(&mut vault, 1_000_001);

    abort 999
}

#[test, expected_failure(abort_code = vault::EAssetNotInVault)]
fun dispense_zero_payout_for_missing_asset_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new(ctx);
    vault::accept_payment(&mut vault, balance::create_for_testing<SUI>(1_000_000));

    let _payout = vault::dispense_payout<ALTUSD>(&mut vault, 0);

    abort 999
}

#[test]
fun insert_position_tracks_max_payout() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new(ctx);
    let oracle_id = oracle_id(ORACLE_1);

    init_matrix(&mut vault, oracle_id, ctx);
    vault::insert_position(&mut vault, oracle_id, true, 50 * float!(), 10 * float!());
    assert_eq!(vault::total_max_payout(&vault), 10 * float!());

    vault::insert_position(&mut vault, oracle_id, false, 50 * float!(), 8 * float!());
    assert_eq!(vault::total_max_payout(&vault), 18 * float!());

    destroy(vault);
}

#[test]
fun remove_position_updates_max_payout() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new(ctx);
    let oracle_id = oracle_id(ORACLE_1);

    init_matrix(&mut vault, oracle_id, ctx);
    vault::insert_position(&mut vault, oracle_id, true, 50 * float!(), 10 * float!());
    vault::remove_position(&mut vault, oracle_id, true, 50 * float!(), 4 * float!());

    assert_eq!(vault::total_max_payout(&vault), 6 * float!());

    destroy(vault);
}

#[test, expected_failure(abort_code = vault::EOracleExposureNotFound)]
fun remove_from_missing_oracle_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new(ctx);

    vault::remove_position(&mut vault, oracle_id(ORACLE_1), true, 50 * float!(), 5 * float!());

    abort 999
}

#[test]
fun set_mtm_updates_cached_liability() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new(ctx);
    let oracle_id = oracle_id(ORACLE_1);

    init_matrix(&mut vault, oracle_id, ctx);
    vault::insert_position(&mut vault, oracle_id, true, 50 * float!(), 10 * float!());
    vault::set_mtm(&mut vault, oracle_id, 7 * float!());

    assert_eq!(vault::total_mtm(&vault), 7 * float!());
    assert_eq!(vault::total_max_payout(&vault), 10 * float!());

    destroy(vault);
}

#[test]
fun set_mtm_with_curve_evaluates_current_tree() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new(ctx);
    let oracle_id = oracle_id(ORACLE_1);

    init_matrix(&mut vault, oracle_id, ctx);
    vault::insert_position(&mut vault, oracle_id, true, 50 * float!(), 10 * float!());
    let curve = vector[
        new_curve_point(50 * float!(), float!(), 0),
        new_curve_point(60 * float!(), 0, float!()),
    ];

    vault::set_mtm_with_curve(&mut vault, oracle_id, &curve);

    assert_eq!(vault::total_mtm(&vault), 10 * float!());
    assert_eq!(vault::total_max_payout(&vault), 10 * float!());

    destroy(vault);
}

#[test]
fun multiple_oracles_aggregate_independently() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new(ctx);
    let oracle_1 = oracle_id(ORACLE_1);
    let oracle_2 = oracle_id(ORACLE_2);

    init_matrix(&mut vault, oracle_1, ctx);
    init_matrix(&mut vault, oracle_2, ctx);
    vault::insert_position(&mut vault, oracle_1, true, 50 * float!(), 5 * float!());
    vault::insert_position(&mut vault, oracle_2, false, 70 * float!(), 3 * float!());
    vault::set_mtm(&mut vault, oracle_1, 5 * float!());
    vault::set_mtm(&mut vault, oracle_2, 3 * float!());

    assert_eq!(vault::total_max_payout(&vault), 8 * float!());
    assert_eq!(vault::total_mtm(&vault), 8 * float!());

    vault::remove_position(&mut vault, oracle_1, true, 50 * float!(), 5 * float!());
    vault::set_mtm(&mut vault, oracle_1, 0);

    assert_eq!(vault::total_max_payout(&vault), 3 * float!());
    assert_eq!(vault::total_mtm(&vault), 3 * float!());

    destroy(vault);
}

#[test]
fun assert_total_exposure_passes_within_limit() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new(ctx);
    let oracle_id = oracle_id(ORACLE_1);

    vault::accept_payment(&mut vault, balance::create_for_testing<SUI>(100 * float!()));
    init_matrix(&mut vault, oracle_id, ctx);
    vault::insert_position(&mut vault, oracle_id, true, 50 * float!(), 10 * float!());
    vault::set_mtm(&mut vault, oracle_id, 10 * float!());

    vault::assert_total_exposure(&vault, 800_000_000);

    destroy(vault);
}

#[test, expected_failure(abort_code = vault::EExceedsMaxTotalExposure)]
fun assert_total_exposure_fails_when_exceeds_limit() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new(ctx);
    let oracle_id = oracle_id(ORACLE_1);

    vault::accept_payment(&mut vault, balance::create_for_testing<SUI>(10 * float!()));
    init_matrix(&mut vault, oracle_id, ctx);
    vault::insert_position(&mut vault, oracle_id, true, 50 * float!(), 10 * float!());
    vault::set_mtm(&mut vault, oracle_id, 10 * float!());

    vault::assert_total_exposure(&vault, 500_000_000);

    abort 999
}

#[test]
fun vault_value_equals_balance_minus_mtm() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new(ctx);
    let oracle_id = oracle_id(ORACLE_1);

    vault::accept_payment(&mut vault, balance::create_for_testing<SUI>(100 * float!()));
    init_matrix(&mut vault, oracle_id, ctx);
    vault::insert_position(&mut vault, oracle_id, true, 50 * float!(), 10 * float!());
    vault::set_mtm(&mut vault, oracle_id, 10 * float!());

    assert_eq!(vault::vault_value(&vault), 90 * float!());

    destroy(vault);
}

#[test, expected_failure(abort_code = vault::EMtmExceedsBalance)]
fun vault_value_aborts_when_underwater() {
    let ctx = &mut tx_context::dummy();
    let mut vault = vault::new(ctx);
    let oracle_id = oracle_id(ORACLE_1);

    vault::accept_payment(&mut vault, balance::create_for_testing<SUI>(5 * float!()));
    init_matrix(&mut vault, oracle_id, ctx);
    vault::insert_position(&mut vault, oracle_id, true, 50 * float!(), 10 * float!());
    vault::set_mtm(&mut vault, oracle_id, 10 * float!());

    let _value = vault::vault_value(&vault);

    abort 999
}
