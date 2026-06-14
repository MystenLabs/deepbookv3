// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for `PredictManager`: DUSDC custody, caps/proofs, position and
/// trading-fee bookkeeping, and the lazy stake roll.
///
/// The accumulator-delivered capital path (`settled_balance` / `withdraw_settled`
/// and the private `settle`) reads a `sui::accumulator::AccumulatorRoot`, which a
/// Move unit test cannot construct (private `create`, `@0x0`-only). The
/// flush-delivery -> manager-receipt money path is exercised end-to-end through the
/// pre-approved `withdraw_delivered_for_testing` seam in `lp_flow_tests`.
#[test_only]
module deepbook_predict::predict_manager_tests;

use deepbook_predict::{predict_manager::{Self, PredictManager}, registry, test_constants};
use dusdc::dusdc::DUSDC;
use std::unit_test::{assert_eq, destroy};
use sui::{coin, test_scenario::{Self as test, return_shared}};

const DEPOSIT_AMOUNT: u64 = 1_000_000;
const WITHDRAW_AMOUNT: u64 = 400_000;
const FAKE_EXPIRY_ID: address = @0xCAFE;
const FAKE_EXPIRY_ID_2: address = @0xBABE;
const ORDER_ID_A: u256 = 42;
const ORDER_ID_B: u256 = 43;
const FEE_AMOUNT: u64 = 5_000;
const STAKE_AMOUNT: u64 = 100_000_000_000; // 100k DEEP raw (6 decimals)
const STAKE_AMOUNT_2: u64 = 30_000_000_000; // 30k DEEP raw

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

// === builder_code_id unsetter ===

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

    manager.add_position(expiry, ORDER_ID_A, ORDER_ID_A);
    assert!(manager.has_position(expiry, ORDER_ID_A));
    assert_eq!(manager.expiry_position_count(expiry), 1);

    manager.add_position(expiry, ORDER_ID_B, ORDER_ID_B);
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
    manager.add_position(expiry_a, ORDER_ID_A, ORDER_ID_A);
    manager.add_position(expiry_b, ORDER_ID_A, ORDER_ID_A);

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

    manager.add_position(FAKE_EXPIRY_ID.to_id(), ORDER_ID_A, ORDER_ID_A);
    manager.add_position(FAKE_EXPIRY_ID.to_id(), ORDER_ID_A, ORDER_ID_A);
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

// === Trading-fee recording ===

#[test]
fun record_trading_fee_paid_accumulates_per_expiry() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);
    let expiry = FAKE_EXPIRY_ID.to_id();

    manager.record_trading_fee_paid(expiry, FEE_AMOUNT);
    manager.record_trading_fee_paid(expiry, FEE_AMOUNT);
    assert_eq!(manager.trading_fees_paid(expiry), 2 * FEE_AMOUNT);

    // A different expiry accumulates independently.
    let expiry_2 = FAKE_EXPIRY_ID_2.to_id();
    manager.record_trading_fee_paid(expiry_2, FEE_AMOUNT);
    assert_eq!(manager.trading_fees_paid(expiry_2), FEE_AMOUNT);
    assert_eq!(manager.trading_fees_paid(expiry), 2 * FEE_AMOUNT);

    destroy(manager);
    scenario.end();
}

#[test]
fun record_trading_fee_paid_zero_is_no_op() {
    // The record helper short-circuits on amount == 0 and does not create a row.
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);
    let expiry = FAKE_EXPIRY_ID.to_id();

    manager.record_trading_fee_paid(expiry, 0);
    assert_eq!(manager.trading_fees_paid(expiry), 0);

    destroy(manager);
    scenario.end();
}

#[test]
fun trading_fees_paid_unknown_expiry_returns_zero() {
    let (mut scenario, registry_id) = setup();
    let manager = create_alice_manager(&mut scenario, registry_id);

    assert_eq!(manager.trading_fees_paid(FAKE_EXPIRY_ID.to_id()), 0);

    destroy(manager);
    scenario.end();
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

// === Staking state ===

#[test]
fun add_inactive_stake_goes_to_inactive() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);

    manager.add_inactive_stake(STAKE_AMOUNT);
    assert_eq!(manager.inactive_stake(), STAKE_AMOUNT);
    assert_eq!(manager.active_stake(), 0);

    destroy(manager);
    scenario.end();
}

#[test]
fun update_stake_is_noop_within_epoch() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);

    manager.add_inactive_stake(STAKE_AMOUNT);
    manager.update_stake(scenario.ctx()); // same epoch as creation
    assert_eq!(manager.inactive_stake(), STAKE_AMOUNT);
    assert_eq!(manager.active_stake(), 0);

    destroy(manager);
    scenario.end();
}

#[test]
fun update_stake_activates_inactive_next_epoch() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);

    manager.add_inactive_stake(STAKE_AMOUNT);
    scenario.next_epoch(test_constants::alice());
    manager.update_stake(scenario.ctx());

    assert_eq!(manager.active_stake(), STAKE_AMOUNT);
    assert_eq!(manager.inactive_stake(), 0);

    // Staking more after activation lands in inactive again.
    manager.add_inactive_stake(STAKE_AMOUNT_2);
    assert_eq!(manager.active_stake(), STAKE_AMOUNT);
    assert_eq!(manager.inactive_stake(), STAKE_AMOUNT_2);

    destroy(manager);
    scenario.end();
}

#[test]
fun remove_all_stake_returns_active_plus_inactive_and_zeroes() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);

    manager.add_inactive_stake(STAKE_AMOUNT);
    scenario.next_epoch(test_constants::alice());
    manager.update_stake(scenario.ctx()); // STAKE_AMOUNT now active
    manager.add_inactive_stake(STAKE_AMOUNT_2); // plus inactive

    let returned = manager.remove_all_stake();
    assert_eq!(returned, STAKE_AMOUNT + STAKE_AMOUNT_2);
    assert_eq!(manager.active_stake(), 0);
    assert_eq!(manager.inactive_stake(), 0);

    destroy(manager);
    scenario.end();
}

// === Cap system / trade proofs ===

#[test]
fun owner_can_mint_and_revoke_caps() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);

    let trade_cap = manager.mint_trade_cap(scenario.ctx());
    let deposit_cap = manager.mint_deposit_cap(scenario.ctx());
    let withdraw_cap = manager.mint_withdraw_cap(scenario.ctx());

    // Revoke each by id; the cap object remains but can no longer authorize.
    manager.revoke_cap(object::borrow_id(&trade_cap), scenario.ctx());
    manager.revoke_cap(object::borrow_id(&deposit_cap), scenario.ctx());
    manager.revoke_cap(object::borrow_id(&withdraw_cap), scenario.ctx());

    destroy(trade_cap);
    destroy(deposit_cap);
    destroy(withdraw_cap);
    destroy(manager);
    scenario.end();
}

#[test]
fun minted_caps_can_be_destroyed() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);

    let trade_cap = manager.mint_trade_cap(scenario.ctx());
    let deposit_cap = manager.mint_deposit_cap(scenario.ctx());
    let withdraw_cap = manager.mint_withdraw_cap(scenario.ctx());
    assert_eq!(trade_cap.predict_manager_id(), manager.id());
    assert_eq!(deposit_cap.predict_manager_id(), manager.id());
    assert_eq!(withdraw_cap.predict_manager_id(), manager.id());

    trade_cap.destroy();
    deposit_cap.destroy();
    withdraw_cap.destroy();

    destroy(manager);
    scenario.end();
}

#[test, expected_failure(abort_code = predict_manager::ENotOwner)]
fun non_owner_cannot_mint_trade_cap() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);

    scenario.next_tx(test_constants::bob());
    let _cap = manager.mint_trade_cap(scenario.ctx());

    abort 999
}

#[test]
fun owner_can_generate_proof() {
    let (mut scenario, registry_id) = setup();
    let manager = create_alice_manager(&mut scenario, registry_id);

    let proof = manager.generate_proof_as_owner(scenario.ctx());
    manager.validate_proof(&proof);

    destroy(manager);
    scenario.end();
}

#[test]
fun trade_cap_holder_can_generate_proof() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);
    let trade_cap = manager.mint_trade_cap(scenario.ctx());

    scenario.next_tx(test_constants::bob());
    let proof = manager.generate_proof_as_trader(&trade_cap);
    manager.validate_proof(&proof);

    destroy(trade_cap);
    destroy(manager);
    scenario.end();
}

#[test, expected_failure(abort_code = predict_manager::EInvalidCap)]
fun revoked_trade_cap_cannot_generate_proof() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);
    let trade_cap = manager.mint_trade_cap(scenario.ctx());

    manager.revoke_cap(object::borrow_id(&trade_cap), scenario.ctx());

    scenario.next_tx(test_constants::bob());
    let _proof = manager.generate_proof_as_trader(&trade_cap);

    abort 999
}

#[test, expected_failure(abort_code = predict_manager::ECapNotInList)]
fun revoking_unknown_cap_aborts() {
    let (mut scenario, registry_id) = setup();
    let mut manager = create_alice_manager(&mut scenario, registry_id);

    let fake_id = object::id_from_address(@0xDEAD);
    manager.revoke_cap(&fake_id, scenario.ctx());

    abort 999
}

#[test]
fun proof_from_one_manager_does_not_validate_against_another() {
    let (mut scenario, registry_id) = setup();
    let manager_a = create_alice_manager(&mut scenario, registry_id);

    scenario.next_tx(test_constants::bob());
    let mut reg = scenario.take_shared_by_id<registry::Registry>(registry_id);
    let manager_b = registry::create_manager(&mut reg, scenario.ctx());
    return_shared(reg);

    scenario.next_tx(test_constants::alice());
    let proof_a = manager_a.generate_proof_as_owner(scenario.ctx());
    // The two managers are distinct; A's proof validates against A only.
    assert!(manager_a.id() != manager_b.id());
    manager_a.validate_proof(&proof_a);

    destroy(manager_a);
    destroy(manager_b);
    scenario.end();
}

#[test, expected_failure(abort_code = predict_manager::EInvalidProof)]
fun cross_manager_proof_validation_aborts() {
    let (mut scenario, registry_id) = setup();
    let manager_a = create_alice_manager(&mut scenario, registry_id);

    scenario.next_tx(test_constants::bob());
    let mut reg = scenario.take_shared_by_id<registry::Registry>(registry_id);
    let manager_b = registry::create_manager(&mut reg, scenario.ctx());
    return_shared(reg);

    scenario.next_tx(test_constants::alice());
    let proof_a = manager_a.generate_proof_as_owner(scenario.ctx());
    manager_b.validate_proof(&proof_a);

    abort 999
}
