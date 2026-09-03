// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for `predict_account` — Predict's per-account app-data slot on an
/// `account::Account`: position bookkeeping keyed by expiry market and order id.
///
/// USDC/PLP custody itself lives in the `account` package (covered by its own
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
const OPENED_AT_MS: u64 = 1_700_000_000_000;
const REPLACEMENT_OPENED_AT_MS: u64 = 1_700_000_500_000;

// === Positions ===

#[test]
fun has_position_false_for_unknown() {
    let (scenario, wrapper) = new_account();
    let account = wrapper.load_account();
    assert!(!predict_account::has_position(account, eid(EXPIRY_A), ORDER_A));
    finish(scenario, wrapper);
}

#[test]
fun add_then_remove_position_round_trips_root_id() {
    let (mut scenario, mut wrapper) = new_account();
    let account = wrapper.load_account_mut(auth(&mut scenario));
    // At mint the root equals the order's own id.
    predict_account::add_position(
        account,
        eid(EXPIRY_A),
        ORDER_A,
        ORDER_A,
        OPENED_AT_MS,
        scenario.ctx(),
    );
    assert!(predict_account::has_position(account, eid(EXPIRY_A), ORDER_A));
    assert_eq!(
        predict_account::position_opened_at_ms(account, eid(EXPIRY_A), ORDER_A),
        OPENED_AT_MS,
    );

    // A partial-close replacement carries the parent root (and its own open time) forward.
    predict_account::add_position(
        account,
        eid(EXPIRY_A),
        ORDER_B,
        ROOT_PARENT,
        REPLACEMENT_OPENED_AT_MS,
        scenario.ctx(),
    );
    assert_eq!(
        predict_account::position_opened_at_ms(account, eid(EXPIRY_A), ORDER_B),
        REPLACEMENT_OPENED_AT_MS,
    );

    let root = predict_account::remove_position(account, eid(EXPIRY_A), ORDER_B, scenario.ctx());
    assert_eq!(root, ROOT_PARENT);
    assert!(!predict_account::has_position(account, eid(EXPIRY_A), ORDER_B));
    finish(scenario, wrapper);
}

#[test]
fun positions_are_scoped_per_expiry() {
    let (mut scenario, mut wrapper) = new_account();
    let account = wrapper.load_account_mut(auth(&mut scenario));
    predict_account::add_position(
        account,
        eid(EXPIRY_A),
        ORDER_A,
        ORDER_A,
        OPENED_AT_MS,
        scenario.ctx(),
    );
    predict_account::add_position(
        account,
        eid(EXPIRY_B),
        ORDER_A,
        ORDER_A,
        OPENED_AT_MS,
        scenario.ctx(),
    );

    // The same order id in two markets is two distinct positions.
    assert!(predict_account::has_position(account, eid(EXPIRY_A), ORDER_A));
    assert!(predict_account::has_position(account, eid(EXPIRY_B), ORDER_A));
    assert!(!predict_account::has_position(account, eid(EXPIRY_A), ORDER_B));
    finish(scenario, wrapper);
}

#[test, expected_failure(abort_code = predict_account::EPositionAlreadyExists)]
fun add_duplicate_position_aborts() {
    let (mut scenario, mut wrapper) = new_account();
    let account = wrapper.load_account_mut(auth(&mut scenario));
    predict_account::add_position(
        account,
        eid(EXPIRY_A),
        ORDER_A,
        ORDER_A,
        OPENED_AT_MS,
        scenario.ctx(),
    );
    predict_account::add_position(
        account,
        eid(EXPIRY_A),
        ORDER_A,
        ROOT_A,
        OPENED_AT_MS,
        scenario.ctx(),
    );
    abort 999
}

#[test, expected_failure(abort_code = predict_account::EPositionNotFound)]
fun remove_unknown_position_aborts() {
    let (mut scenario, mut wrapper) = new_account();
    let account = wrapper.load_account_mut(auth(&mut scenario));
    predict_account::remove_position(account, eid(EXPIRY_A), ORDER_A, scenario.ctx());
    abort 999
}

#[test, expected_failure(abort_code = predict_account::EPositionNotFound)]
fun opened_at_ms_unknown_position_aborts() {
    let (mut scenario, mut wrapper) = new_account();
    let account = wrapper.load_account_mut(auth(&mut scenario));
    // Attach the slot with one position so the getter reaches the missing-row guard
    // rather than the empty-app-data path.
    predict_account::add_position(
        account,
        eid(EXPIRY_A),
        ORDER_A,
        ORDER_A,
        OPENED_AT_MS,
        scenario.ctx(),
    );
    predict_account::position_opened_at_ms(account, eid(EXPIRY_A), ORDER_B);
    abort 999
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
