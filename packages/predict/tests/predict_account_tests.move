// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for `predict_account` — Predict's per-account app-data slot on an
/// `account::Account`: position bookkeeping, per-expiry trading-fee accounting, and
/// the lazy DEEP stake roll.
///
/// DUSDC/PLP/DEEP custody itself lives in the `account` package (covered by its own
/// tests and by the Predict flow suite), so these tests drive only the app-data
/// accounting primitives, which take an already-loaded `&mut Account`. The account is
/// created through the real `account_registry` derivation and held owner-side
/// (unshared) so the `&mut Account` can be threaded across operations without the
/// shared-object take/return dance.
#[test_only]
module deepbook_predict::predict_account_tests;

use account::{account::{Self, AccountWrapper}, account_registry::{Self, AccountRegistry}};
use deepbook_predict::predict_account;
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::{Self as test, Scenario, return_shared};

const ALICE: address = @0xA;
const EXPIRY_A: address = @0xCAFE;
const EXPIRY_B: address = @0xBABE;
const ORDER_A: u256 = 42;
const ORDER_B: u256 = 99;
const ROOT_A: u256 = 42;
const ROOT_PARENT: u256 = 7;
const STAKE_1: u64 = 1_000;
const STAKE_2: u64 = 2_500;

// === Positions ===

#[test]
fun has_position_false_for_unknown() {
    let (scenario, wrapper) = new_account();
    let account = wrapper.load_account();
    assert!(!predict_account::has_position(account, eid(EXPIRY_A), ORDER_A));
    assert_eq!(predict_account::expiry_position_count(account, eid(EXPIRY_A)), 0);
    finish(scenario, wrapper);
}

#[test]
fun add_then_remove_position_round_trips_root_id() {
    let (mut scenario, mut wrapper) = new_account();
    let account = wrapper.load_account_mut(auth(&mut scenario));
    // At mint the root equals the order's own id.
    predict_account::add_position(account, eid(EXPIRY_A), ORDER_A, ORDER_A, scenario.ctx());
    assert!(predict_account::has_position(account, eid(EXPIRY_A), ORDER_A));
    assert_eq!(predict_account::expiry_position_count(account, eid(EXPIRY_A)), 1);

    // A partial-close replacement carries the parent root forward.
    predict_account::add_position(account, eid(EXPIRY_A), ORDER_B, ROOT_PARENT, scenario.ctx());
    assert_eq!(predict_account::expiry_position_count(account, eid(EXPIRY_A)), 2);

    let root = predict_account::remove_position(account, eid(EXPIRY_A), ORDER_B, scenario.ctx());
    assert_eq!(root, ROOT_PARENT);
    assert!(!predict_account::has_position(account, eid(EXPIRY_A), ORDER_B));
    assert_eq!(predict_account::expiry_position_count(account, eid(EXPIRY_A)), 1);
    finish(scenario, wrapper);
}

#[test]
fun positions_are_scoped_per_expiry() {
    let (mut scenario, mut wrapper) = new_account();
    let account = wrapper.load_account_mut(auth(&mut scenario));
    predict_account::add_position(account, eid(EXPIRY_A), ORDER_A, ORDER_A, scenario.ctx());
    predict_account::add_position(account, eid(EXPIRY_B), ORDER_A, ORDER_A, scenario.ctx());

    // The same order id in two markets is two distinct positions.
    assert!(predict_account::has_position(account, eid(EXPIRY_A), ORDER_A));
    assert!(predict_account::has_position(account, eid(EXPIRY_B), ORDER_A));
    assert_eq!(predict_account::expiry_position_count(account, eid(EXPIRY_A)), 1);
    assert_eq!(predict_account::expiry_position_count(account, eid(EXPIRY_B)), 1);
    assert!(!predict_account::has_position(account, eid(EXPIRY_A), ORDER_B));
    finish(scenario, wrapper);
}

#[test, expected_failure(abort_code = predict_account::EPositionAlreadyExists)]
fun add_duplicate_position_aborts() {
    let (mut scenario, mut wrapper) = new_account();
    let account = wrapper.load_account_mut(auth(&mut scenario));
    predict_account::add_position(account, eid(EXPIRY_A), ORDER_A, ORDER_A, scenario.ctx());
    predict_account::add_position(account, eid(EXPIRY_A), ORDER_A, ROOT_A, scenario.ctx());
    abort 999
}

#[test, expected_failure(abort_code = predict_account::EPositionNotFound)]
fun remove_unknown_position_aborts() {
    let (mut scenario, mut wrapper) = new_account();
    let account = wrapper.load_account_mut(auth(&mut scenario));
    predict_account::remove_position(account, eid(EXPIRY_A), ORDER_A, scenario.ctx());
    abort 999
}

// === Trading fees ===

#[test]
fun record_trading_fee_accumulates_per_expiry() {
    let (mut scenario, mut wrapper) = new_account();
    let account = wrapper.load_account_mut(auth(&mut scenario));
    predict_account::record_trading_fee_paid(account, eid(EXPIRY_A), 100, scenario.ctx());
    predict_account::record_trading_fee_paid(account, eid(EXPIRY_A), 250, scenario.ctx());
    predict_account::record_trading_fee_paid(account, eid(EXPIRY_B), 70, scenario.ctx());
    assert_eq!(predict_account::trading_fees_paid(account, eid(EXPIRY_A)), 350);
    assert_eq!(predict_account::trading_fees_paid(account, eid(EXPIRY_B)), 70);
    finish(scenario, wrapper);
}

#[test]
fun record_trading_fee_zero_is_no_op() {
    let (mut scenario, mut wrapper) = new_account();
    let account = wrapper.load_account_mut(auth(&mut scenario));
    predict_account::record_trading_fee_paid(account, eid(EXPIRY_A), 0, scenario.ctx());
    // Zero never creates the summary row, so the unknown-expiry zero path is exercised.
    assert_eq!(predict_account::trading_fees_paid(account, eid(EXPIRY_A)), 0);
    finish(scenario, wrapper);
}

#[test]
fun trading_fees_unknown_expiry_is_zero() {
    let (scenario, wrapper) = new_account();
    assert_eq!(predict_account::trading_fees_paid(wrapper.load_account(), eid(EXPIRY_A)), 0);
    finish(scenario, wrapper);
}

// === DEEP stake roll ===

#[test]
fun add_inactive_stake_goes_to_inactive() {
    let (mut scenario, mut wrapper) = new_account();
    let account = wrapper.load_account_mut(auth(&mut scenario));
    predict_account::add_inactive_stake(account, STAKE_1, scenario.ctx());
    assert_eq!(predict_account::inactive_stake(account), STAKE_1);
    assert_eq!(predict_account::active_stake(account), 0);
    finish(scenario, wrapper);
}

#[test]
fun active_stake_mut_is_noop_within_epoch() {
    let (mut scenario, mut wrapper) = new_account();
    let account = wrapper.load_account_mut(auth(&mut scenario));
    predict_account::add_inactive_stake(account, STAKE_1, scenario.ctx());
    // Same epoch as the slot's creation: no roll.
    assert_eq!(predict_account::active_stake_mut(account, scenario.ctx()), 0);
    assert_eq!(predict_account::inactive_stake(account), STAKE_1);
    assert_eq!(predict_account::active_stake(account), 0);
    finish(scenario, wrapper);
}

#[test]
fun active_stake_mut_activates_inactive_next_epoch() {
    let (mut scenario, mut wrapper) = new_account();
    {
        let account = wrapper.load_account_mut(auth(&mut scenario));
        predict_account::add_inactive_stake(account, STAKE_1, scenario.ctx());
    };
    scenario.next_epoch(ALICE);
    let account = wrapper.load_account_mut(auth(&mut scenario));
    assert_eq!(predict_account::active_stake_mut(account, scenario.ctx()), STAKE_1);
    assert_eq!(predict_account::active_stake(account), STAKE_1);
    assert_eq!(predict_account::inactive_stake(account), 0);

    // Staking again after activation lands in inactive until the next epoch.
    predict_account::add_inactive_stake(account, STAKE_2, scenario.ctx());
    assert_eq!(predict_account::active_stake(account), STAKE_1);
    assert_eq!(predict_account::inactive_stake(account), STAKE_2);
    finish(scenario, wrapper);
}

#[test]
fun remove_all_stake_sums_active_plus_inactive_and_zeroes() {
    let (mut scenario, mut wrapper) = new_account();
    {
        let account = wrapper.load_account_mut(auth(&mut scenario));
        predict_account::add_inactive_stake(account, STAKE_1, scenario.ctx());
    };
    scenario.next_epoch(ALICE);
    let account = wrapper.load_account_mut(auth(&mut scenario));
    predict_account::active_stake_mut(account, scenario.ctx()); // STAKE_1 now active
    predict_account::add_inactive_stake(account, STAKE_2, scenario.ctx()); // plus inactive

    assert_eq!(predict_account::remove_all_stake(account, scenario.ctx()), STAKE_1 + STAKE_2);
    assert_eq!(predict_account::active_stake(account), 0);
    assert_eq!(predict_account::inactive_stake(account), 0);
    finish(scenario, wrapper);
}

// === Helpers ===

/// Create an owner-held (unshared) account through the real registry derivation.
fun new_account(): (Scenario, AccountWrapper) {
    let mut scenario = test::begin(ALICE);
    account_registry::init_for_testing(scenario.ctx());
    scenario.next_tx(ALICE);
    let mut registry = scenario.take_shared<AccountRegistry>();
    let wrapper = registry.new(scenario.ctx());
    return_shared(registry);
    scenario.next_tx(ALICE);
    (scenario, wrapper)
}

/// Fresh owner auth from the ALICE sender for a `load_account_mut`.
fun auth(scenario: &mut Scenario): account::Auth {
    account::generate_auth(scenario.ctx())
}

fun eid(addr: address): ID {
    addr.to_id()
}

fun finish(scenario: Scenario, wrapper: AccountWrapper) {
    destroy(wrapper);
    scenario.end();
}
