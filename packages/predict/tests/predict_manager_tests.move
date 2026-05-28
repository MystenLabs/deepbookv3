// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::predict_manager_tests;

use deepbook_predict::{
    builder_code,
    predict_manager::{Self, PredictManager},
    registry,
    test_constants
};
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::{coin, test_scenario::{Self as test, return_shared}};

const DEPOSIT_AMOUNT: u64 = 1_000_000;
const WITHDRAW_AMOUNT: u64 = 400_000;
const FAKE_EXPIRY_ID: address = @0xCAFE;
const FAKE_EXPIRY_ID_2: address = @0xBABE;
const ORDER_ID_A: u256 = 42;
const ORDER_ID_B: u256 = 43;
const BUILDER_INDEX: u64 = 7;
const FEE_AMOUNT: u64 = 5_000;
const CASH_PAID: u64 = 100_000;
const CASH_RECEIVED: u64 = 60_000;

// === Helpers ===

fun setup(): (test::Scenario, ID) {
    let mut scenario = test::begin(test_constants::alice());
    let registry_id = registry::init_for_testing(scenario.ctx());
    (scenario, registry_id)
}

fun create_alice_manager(scenario: &mut test::Scenario, registry_id: ID): PredictManager {
    scenario.next_tx(test_constants::alice());
    let mut reg = scenario.take_shared_by_id<registry::Registry>(registry_id);
    let manager = registry::create_manager(&mut reg, scenario.ctx());
    return_shared(reg);
    manager
}

// === id / owner / balance ===

#[test]
fun fresh_manager_has_alice_owner_and_zero_balance() {
    let (mut scenario, registry_id) = setup();
    let manager = create_alice_manager(&mut scenario, registry_id);

    assert_eq!(manager.owner(), test_constants::alice());
    assert_eq!(manager.balance(), 0);

    destroy(manager);
    scenario.end();
}

#[test]
fun id_is_stable_across_reads() {
    let (mut scenario, registry_id) = setup();
    let manager = create_alice_manager(&mut scenario, registry_id);

    assert_eq!(manager.id(), manager.id());

    destroy(manager);
    scenario.end();
}

// === deposit / withdraw ===

#[test]
fun deposit_increases_balance() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);

    let coin = coin::mint_for_testing<DUSDC>(DEPOSIT_AMOUNT, scenario.ctx());
    manager.deposit(coin, scenario.ctx());
    assert_eq!(manager.balance(), DEPOSIT_AMOUNT);

    destroy(manager);
    scenario.end();
}

#[test]
fun withdraw_decreases_balance_and_returns_coin() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);

    let coin = coin::mint_for_testing<DUSDC>(DEPOSIT_AMOUNT, scenario.ctx());
    manager.deposit(coin, scenario.ctx());

    let withdrawn = manager.withdraw(WITHDRAW_AMOUNT, scenario.ctx());
    assert_eq!(withdrawn.value(), WITHDRAW_AMOUNT);
    assert_eq!(manager.balance(), DEPOSIT_AMOUNT - WITHDRAW_AMOUNT);

    destroy(manager);
    destroy(withdrawn);
    scenario.end();
}

#[test]
fun deposit_permissionless_works_without_owner_sender() {
    // deposit_permissionless uses the manager's stored DepositCap so anyone
    // can credit the manager (used for protocol-driven payouts).
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);

    scenario.next_tx(test_constants::bob());
    let coin = coin::mint_for_testing<DUSDC>(DEPOSIT_AMOUNT, scenario.ctx());
    manager.deposit_permissionless(coin, scenario.ctx());
    assert_eq!(manager.balance(), DEPOSIT_AMOUNT);

    destroy(manager);
    scenario.end();
}

// === share ===

#[test]
fun share_makes_manager_take_shared() {
    let (mut scenario, registry_id) = setup();
    let manager = create_alice_manager(&mut scenario, registry_id);
    let manager_id = manager.id();
    manager.share();

    scenario.next_tx(test_constants::alice());
    let taken = scenario.take_shared_by_id<PredictManager>(manager_id);
    assert_eq!(taken.id(), manager_id);
    return_shared(taken);

    scenario.end();
}

// === builder_code_id setter / unsetter ===

#[test]
fun builder_code_id_starts_none_then_set_and_unset() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);

    assert!(manager.builder_code_id().is_none());

    // Alice creates a builder code for herself.
    let code = builder_code::new_for_testing(
        test_constants::alice(),
        BUILDER_INDEX,
        scenario.ctx(),
    );
    manager.set_builder_code(&code, scenario.ctx());

    let stored = manager.builder_code_id();
    assert!(stored.is_some());
    assert_eq!(*stored.borrow(), code.id());

    manager.unset_builder_code(scenario.ctx());
    assert!(manager.builder_code_id().is_none());

    destroy(manager);
    builder_code::destroy_for_testing(code);
    scenario.end();
}

#[test, expected_failure(abort_code = predict_manager::ENotOwner)]
fun set_builder_code_by_non_owner_aborts() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);
    let code = builder_code::new_for_testing(
        test_constants::alice(),
        BUILDER_INDEX,
        scenario.ctx(),
    );

    scenario.next_tx(test_constants::bob());
    manager.set_builder_code(&code, scenario.ctx());
    abort 999
}

#[test, expected_failure(abort_code = predict_manager::ENotOwner)]
fun unset_builder_code_by_non_owner_aborts() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);

    scenario.next_tx(test_constants::bob());
    manager.unset_builder_code(scenario.ctx());
    abort 999
}

// === Position bookkeeping ===

#[test]
fun has_position_returns_false_for_unknown_position() {
    let (mut scenario, registry_id) = setup();
    let manager = create_alice_manager(&mut scenario, registry_id);

    assert!(!manager.has_position(FAKE_EXPIRY_ID.to_id(), ORDER_ID_A));

    destroy(manager);
    scenario.end();
}

#[test]
fun add_position_then_remove_round_trip() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);
    let expiry = FAKE_EXPIRY_ID.to_id();

    manager.add_position(expiry, ORDER_ID_A);
    assert!(manager.has_position(expiry, ORDER_ID_A));
    assert_eq!(manager.expiry_position_count(expiry), 1);

    manager.add_position(expiry, ORDER_ID_B);
    assert_eq!(manager.expiry_position_count(expiry), 2);

    manager.remove_position(expiry, ORDER_ID_A);
    assert!(!manager.has_position(expiry, ORDER_ID_A));
    assert_eq!(manager.expiry_position_count(expiry), 1);
    // The other position is unchanged.
    assert!(manager.has_position(expiry, ORDER_ID_B));

    manager.remove_position(expiry, ORDER_ID_B);

    destroy(manager);
    scenario.end();
}

#[test]
fun positions_are_scoped_per_expiry() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);
    let expiry_a = FAKE_EXPIRY_ID.to_id();
    let expiry_b = FAKE_EXPIRY_ID_2.to_id();

    // Same order_id under two different expiries is two distinct positions.
    manager.add_position(expiry_a, ORDER_ID_A);
    manager.add_position(expiry_b, ORDER_ID_A);

    assert!(manager.has_position(expiry_a, ORDER_ID_A));
    assert!(manager.has_position(expiry_b, ORDER_ID_A));
    assert_eq!(manager.expiry_position_count(expiry_a), 1);
    assert_eq!(manager.expiry_position_count(expiry_b), 1);

    destroy(manager);
    scenario.end();
}

#[test, expected_failure(abort_code = predict_manager::EPositionAlreadyExists)]
fun add_position_duplicate_aborts() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);

    manager.add_position(FAKE_EXPIRY_ID.to_id(), ORDER_ID_A);
    manager.add_position(FAKE_EXPIRY_ID.to_id(), ORDER_ID_A);
    abort 999
}

#[test, expected_failure(abort_code = predict_manager::EInsufficientPosition)]
fun remove_position_that_does_not_exist_aborts() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);

    manager.remove_position(FAKE_EXPIRY_ID.to_id(), ORDER_ID_A);
    abort 999
}

#[test]
fun expiry_position_count_unknown_expiry_returns_zero() {
    let (mut scenario, registry_id) = setup();
    let manager = create_alice_manager(&mut scenario, registry_id);

    assert_eq!(manager.expiry_position_count(FAKE_EXPIRY_ID.to_id()), 0);

    destroy(manager);
    scenario.end();
}

// === Cash flow recording ===

#[test]
fun record_helpers_accumulate_per_expiry() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);
    let expiry = FAKE_EXPIRY_ID.to_id();

    manager.record_trading_fee_paid(expiry, FEE_AMOUNT);
    manager.record_trading_fee_paid(expiry, FEE_AMOUNT);
    manager.record_cash_paid_to_expiry(expiry, CASH_PAID);
    manager.record_cash_received_from_expiry(expiry, CASH_RECEIVED);

    assert_eq!(manager.trading_fees_paid(expiry), 2 * FEE_AMOUNT);
    assert_eq!(manager.cash_paid_to_expiry(expiry), CASH_PAID);
    assert_eq!(manager.cash_received_from_expiry(expiry), CASH_RECEIVED);

    destroy(manager);
    scenario.end();
}

#[test]
fun record_helpers_zero_amount_is_no_op() {
    // The record_* helpers short-circuit on amount == 0 and do not even
    // ensure the expiry summary exists. The getters then return 0 from
    // the unknown-expiry fallback.
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);
    let expiry = FAKE_EXPIRY_ID.to_id();

    manager.record_trading_fee_paid(expiry, 0);
    manager.record_cash_paid_to_expiry(expiry, 0);
    manager.record_cash_received_from_expiry(expiry, 0);

    assert_eq!(manager.trading_fees_paid(expiry), 0);
    assert_eq!(manager.cash_paid_to_expiry(expiry), 0);
    assert_eq!(manager.cash_received_from_expiry(expiry), 0);

    destroy(manager);
    scenario.end();
}

#[test]
fun getters_return_zero_for_unknown_expiry() {
    let (mut scenario, registry_id) = setup();
    let manager = create_alice_manager(&mut scenario, registry_id);
    let expiry = FAKE_EXPIRY_ID.to_id();

    assert_eq!(manager.trading_fees_paid(expiry), 0);
    assert_eq!(manager.cash_paid_to_expiry(expiry), 0);
    assert_eq!(manager.cash_received_from_expiry(expiry), 0);

    destroy(manager);
    scenario.end();
}

// === resolve_expiry_summary ===

#[test]
fun resolve_expiry_summary_returns_zeros_for_untouched_expiry() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);
    let expiry = FAKE_EXPIRY_ID.to_id();

    let (fees, paid, received) = manager.resolve_expiry_summary(expiry);
    assert_eq!(fees, 0);
    assert_eq!(paid, 0);
    assert_eq!(received, 0);

    destroy(manager);
    scenario.end();
}

#[test]
fun resolve_expiry_summary_returns_recorded_cash_flows_when_no_open_positions() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);
    let expiry = FAKE_EXPIRY_ID.to_id();

    manager.record_trading_fee_paid(expiry, FEE_AMOUNT);
    manager.record_cash_paid_to_expiry(expiry, CASH_PAID);
    manager.record_cash_received_from_expiry(expiry, CASH_RECEIVED);

    let (fees, paid, received) = manager.resolve_expiry_summary(expiry);
    assert_eq!(fees, FEE_AMOUNT);
    assert_eq!(paid, CASH_PAID);
    assert_eq!(received, CASH_RECEIVED);

    // Summary entry has been removed — second call returns zeros.
    let (fees_again, paid_again, received_again) = manager.resolve_expiry_summary(expiry);
    assert_eq!(fees_again, 0);
    assert_eq!(paid_again, 0);
    assert_eq!(received_again, 0);

    destroy(manager);
    scenario.end();
}

#[test, expected_failure(abort_code = predict_manager::EExpirySummaryHasOpenPositions)]
fun resolve_expiry_summary_with_open_positions_aborts() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);
    let expiry = FAKE_EXPIRY_ID.to_id();

    manager.add_position(expiry, ORDER_ID_A);
    let (_, _, _) = manager.resolve_expiry_summary(expiry);
    abort 999
}

// === assert_owner ===

#[test]
fun assert_owner_passes_for_creator() {
    let (mut scenario, registry_id) = setup();
    let manager = create_alice_manager(&mut scenario, registry_id);

    // Alice is the manager owner.
    manager.assert_owner(scenario.ctx());

    destroy(manager);
    scenario.end();
}

#[test, expected_failure(abort_code = predict_manager::ENotOwner)]
fun assert_owner_aborts_for_non_owner() {
    let (mut scenario, registry_id) = setup();
    let manager = create_alice_manager(&mut scenario, registry_id);

    scenario.next_tx(test_constants::bob());
    manager.assert_owner(scenario.ctx());
    abort 999
}
