// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::predict_manager_tests;

use deepbook_predict::{market_key, predict_manager::{Self, PredictManager}};
use std::unit_test::assert_eq;
use sui::test_scenario;

macro fun oracle_id(): ID {
    object::id_from_address(@0xAA)
}

macro fun expiry(): u64 {
    1_000_000
}

// === Helpers ===

/// Creates a PredictManager via test_scenario and returns (test, manager).
fun setup(sender: address): (test_scenario::Scenario, PredictManager) {
    let mut test = test_scenario::begin(sender);
    predict_manager::new(test.ctx());
    test.next_tx(sender);
    let manager = test.take_shared<PredictManager>();
    (test, manager)
}

fun teardown(test: test_scenario::Scenario, manager: PredictManager) {
    test_scenario::return_shared(manager);
    test.end();
}

// === Position Basics ===

#[test]
fun new_manager_has_no_positions() {
    let (test, manager) = setup(@0x1);
    let key = market_key::up(oracle_id!(), expiry!(), 100);

    let (free, locked) = manager.position(key);
    assert_eq!(free, 0);
    assert_eq!(locked, 0);

    teardown(test, manager);
}

#[test]
fun increase_position_creates_entry() {
    let (test, mut manager) = setup(@0x1);
    let key = market_key::up(oracle_id!(), expiry!(), 100);

    manager.increase_position(key, 500);

    let (free, locked) = manager.position(key);
    assert_eq!(free, 500);
    assert_eq!(locked, 0);

    teardown(test, manager);
}

#[test]
fun increase_position_accumulates() {
    let (test, mut manager) = setup(@0x1);
    let key = market_key::up(oracle_id!(), expiry!(), 100);

    manager.increase_position(key, 100);
    manager.increase_position(key, 200);
    manager.increase_position(key, 300);

    let (free, locked) = manager.position(key);
    assert_eq!(free, 600);
    assert_eq!(locked, 0);

    teardown(test, manager);
}

#[test]
fun decrease_position_subtracts_free() {
    let (test, mut manager) = setup(@0x1);
    let key = market_key::up(oracle_id!(), expiry!(), 100);

    manager.increase_position(key, 500);
    manager.decrease_position(key, 200);

    let (free, locked) = manager.position(key);
    assert_eq!(free, 300);
    assert_eq!(locked, 0);

    teardown(test, manager);
}

#[test]
fun decrease_position_to_zero() {
    let (test, mut manager) = setup(@0x1);
    let key = market_key::down(oracle_id!(), expiry!(), 100);

    manager.increase_position(key, 500);
    manager.decrease_position(key, 500);

    let (free, locked) = manager.position(key);
    assert_eq!(free, 0);
    assert_eq!(locked, 0);

    teardown(test, manager);
}

#[test]
fun independent_keys_dont_interfere() {
    let (test, mut manager) = setup(@0x1);
    let up_key = market_key::up(oracle_id!(), expiry!(), 100);
    let down_key = market_key::down(oracle_id!(), expiry!(), 100);
    let other_strike = market_key::up(oracle_id!(), expiry!(), 200);

    manager.increase_position(up_key, 100);
    manager.increase_position(down_key, 200);
    manager.increase_position(other_strike, 300);

    let (free, _) = manager.position(up_key);
    assert_eq!(free, 100);
    let (free, _) = manager.position(down_key);
    assert_eq!(free, 200);
    let (free, _) = manager.position(other_strike);
    assert_eq!(free, 300);

    teardown(test, manager);
}

// === Decrease Position Failures ===

#[test, expected_failure(abort_code = predict_manager::EInsufficientPosition)]
fun decrease_nonexistent_position_aborts() {
    let (_test, mut manager) = setup(@0x1);
    let key = market_key::up(oracle_id!(), expiry!(), 100);

    manager.decrease_position(key, 1);

    abort
}

#[test, expected_failure(abort_code = predict_manager::EInsufficientFreePosition)]
fun decrease_more_than_free_aborts() {
    let (_test, mut manager) = setup(@0x1);
    let key = market_key::up(oracle_id!(), expiry!(), 100);

    manager.increase_position(key, 100);
    manager.decrease_position(key, 101);

    abort
}

#[test, expected_failure(abort_code = predict_manager::EInsufficientFreePosition)]
fun decrease_locked_position_aborts() {
    let (_test, mut manager) = setup(@0x1);
    let locked_key = market_key::up(oracle_id!(), expiry!(), 100);
    let minted_key = market_key::up(oracle_id!(), expiry!(), 200);

    manager.increase_position(locked_key, 100);
    manager.lock_collateral(locked_key, minted_key, 80);

    // free = 20, locked = 80 → trying to decrease 50 from free fails
    manager.decrease_position(locked_key, 50);

    abort
}

// === Collateral Locking ===

#[test]
fun lock_collateral_moves_free_to_locked() {
    let (test, mut manager) = setup(@0x1);
    let locked_key = market_key::up(oracle_id!(), expiry!(), 100);
    let minted_key = market_key::up(oracle_id!(), expiry!(), 200);

    manager.increase_position(locked_key, 500);
    manager.lock_collateral(locked_key, minted_key, 300);

    let (free, locked) = manager.position(locked_key);
    assert_eq!(free, 200);
    assert_eq!(locked, 300);

    teardown(test, manager);
}

#[test]
fun lock_all_free() {
    let (test, mut manager) = setup(@0x1);
    let locked_key = market_key::up(oracle_id!(), expiry!(), 100);
    let minted_key = market_key::up(oracle_id!(), expiry!(), 200);

    manager.increase_position(locked_key, 500);
    manager.lock_collateral(locked_key, minted_key, 500);

    let (free, locked) = manager.position(locked_key);
    assert_eq!(free, 0);
    assert_eq!(locked, 500);

    teardown(test, manager);
}

#[test]
fun multiple_locks_same_collateral_pair() {
    let (test, mut manager) = setup(@0x1);
    let locked_key = market_key::up(oracle_id!(), expiry!(), 100);
    let minted_key = market_key::up(oracle_id!(), expiry!(), 200);

    manager.increase_position(locked_key, 1000);
    manager.lock_collateral(locked_key, minted_key, 200);
    manager.lock_collateral(locked_key, minted_key, 300);

    let (free, locked) = manager.position(locked_key);
    assert_eq!(free, 500);
    assert_eq!(locked, 500);

    teardown(test, manager);
}

#[test]
fun multiple_locks_different_minted_keys() {
    let (test, mut manager) = setup(@0x1);
    let locked_key = market_key::up(oracle_id!(), expiry!(), 100);
    let minted_a = market_key::up(oracle_id!(), expiry!(), 200);
    let minted_b = market_key::up(oracle_id!(), expiry!(), 300);

    manager.increase_position(locked_key, 1000);
    manager.lock_collateral(locked_key, minted_a, 400);
    manager.lock_collateral(locked_key, minted_b, 300);

    let (free, locked) = manager.position(locked_key);
    assert_eq!(free, 300);
    assert_eq!(locked, 700);

    teardown(test, manager);
}

#[test, expected_failure(abort_code = predict_manager::EInsufficientPosition)]
fun lock_nonexistent_position_aborts() {
    let (_test, mut manager) = setup(@0x1);
    let locked_key = market_key::up(oracle_id!(), expiry!(), 100);
    let minted_key = market_key::up(oracle_id!(), expiry!(), 200);

    manager.lock_collateral(locked_key, minted_key, 1);

    abort
}

#[test, expected_failure(abort_code = predict_manager::EInsufficientFreePosition)]
fun lock_more_than_free_aborts() {
    let (_test, mut manager) = setup(@0x1);
    let locked_key = market_key::up(oracle_id!(), expiry!(), 100);
    let minted_key = market_key::up(oracle_id!(), expiry!(), 200);

    manager.increase_position(locked_key, 100);
    manager.lock_collateral(locked_key, minted_key, 101);

    abort
}

#[test, expected_failure(abort_code = predict_manager::EInsufficientFreePosition)]
fun lock_after_partial_lock_exceeds_remaining_free() {
    let (_test, mut manager) = setup(@0x1);
    let locked_key = market_key::up(oracle_id!(), expiry!(), 100);
    let minted_a = market_key::up(oracle_id!(), expiry!(), 200);
    let minted_b = market_key::up(oracle_id!(), expiry!(), 300);

    manager.increase_position(locked_key, 100);
    manager.lock_collateral(locked_key, minted_a, 60);
    // free = 40, trying to lock 50
    manager.lock_collateral(locked_key, minted_b, 50);

    abort
}

// === Collateral Releasing ===

#[test]
fun release_collateral_moves_locked_to_free() {
    let (test, mut manager) = setup(@0x1);
    let locked_key = market_key::up(oracle_id!(), expiry!(), 100);
    let minted_key = market_key::up(oracle_id!(), expiry!(), 200);

    manager.increase_position(locked_key, 500);
    manager.lock_collateral(locked_key, minted_key, 300);
    manager.release_collateral(locked_key, minted_key, 200);

    let (free, locked) = manager.position(locked_key);
    assert_eq!(free, 400);
    assert_eq!(locked, 100);

    teardown(test, manager);
}

#[test]
fun release_all_collateral() {
    let (test, mut manager) = setup(@0x1);
    let locked_key = market_key::up(oracle_id!(), expiry!(), 100);
    let minted_key = market_key::up(oracle_id!(), expiry!(), 200);

    manager.increase_position(locked_key, 500);
    manager.lock_collateral(locked_key, minted_key, 500);
    manager.release_collateral(locked_key, minted_key, 500);

    let (free, locked) = manager.position(locked_key);
    assert_eq!(free, 500);
    assert_eq!(locked, 0);

    teardown(test, manager);
}

#[test, expected_failure(abort_code = predict_manager::EInsufficientCollateral)]
fun release_nonexistent_collateral_aborts() {
    let (_test, mut manager) = setup(@0x1);
    let locked_key = market_key::up(oracle_id!(), expiry!(), 100);
    let minted_key = market_key::up(oracle_id!(), expiry!(), 200);

    manager.release_collateral(locked_key, minted_key, 1);

    abort
}

#[test, expected_failure(abort_code = predict_manager::EInsufficientCollateral)]
fun release_more_than_locked_aborts() {
    let (_test, mut manager) = setup(@0x1);
    let locked_key = market_key::up(oracle_id!(), expiry!(), 100);
    let minted_key = market_key::up(oracle_id!(), expiry!(), 200);

    manager.increase_position(locked_key, 500);
    manager.lock_collateral(locked_key, minted_key, 300);
    manager.release_collateral(locked_key, minted_key, 301);

    abort
}

#[test, expected_failure(abort_code = predict_manager::EInsufficientCollateral)]
fun release_wrong_minted_key_aborts() {
    let (_test, mut manager) = setup(@0x1);
    let locked_key = market_key::up(oracle_id!(), expiry!(), 100);
    let minted_a = market_key::up(oracle_id!(), expiry!(), 200);
    let minted_b = market_key::up(oracle_id!(), expiry!(), 300);

    manager.increase_position(locked_key, 500);
    manager.lock_collateral(locked_key, minted_a, 300);

    // Try to release against minted_b which was never locked
    manager.release_collateral(locked_key, minted_b, 100);

    abort
}

#[test, expected_failure(abort_code = predict_manager::EInsufficientCollateral)]
fun release_wrong_locked_key_aborts() {
    let (_test, mut manager) = setup(@0x1);
    let locked_key = market_key::up(oracle_id!(), expiry!(), 100);
    let wrong_locked = market_key::up(oracle_id!(), expiry!(), 150);
    let minted_key = market_key::up(oracle_id!(), expiry!(), 200);

    manager.increase_position(locked_key, 500);
    manager.lock_collateral(locked_key, minted_key, 300);

    // Try to release against a different locked_key
    manager.release_collateral(wrong_locked, minted_key, 100);

    abort
}

// === Full Cycles ===

#[test]
fun full_cycle_increase_lock_release_decrease() {
    let (test, mut manager) = setup(@0x1);
    let locked_key = market_key::up(oracle_id!(), expiry!(), 100);
    let minted_key = market_key::up(oracle_id!(), expiry!(), 200);

    // Mint 500 contracts
    manager.increase_position(locked_key, 500);

    // Lock 300 as collateral
    manager.lock_collateral(locked_key, minted_key, 300);
    let (free, locked) = manager.position(locked_key);
    assert_eq!(free, 200);
    assert_eq!(locked, 300);

    // Release 300 collateral
    manager.release_collateral(locked_key, minted_key, 300);
    let (free, locked) = manager.position(locked_key);
    assert_eq!(free, 500);
    assert_eq!(locked, 0);

    // Redeem all 500
    manager.decrease_position(locked_key, 500);
    let (free, locked) = manager.position(locked_key);
    assert_eq!(free, 0);
    assert_eq!(locked, 0);

    teardown(test, manager);
}

#[test]
fun partial_release_then_decrease() {
    let (test, mut manager) = setup(@0x1);
    let locked_key = market_key::up(oracle_id!(), expiry!(), 100);
    let minted_key = market_key::up(oracle_id!(), expiry!(), 200);

    manager.increase_position(locked_key, 1000);
    manager.lock_collateral(locked_key, minted_key, 600);

    // free=400, locked=600
    // Release 200, now free=600, locked=400
    manager.release_collateral(locked_key, minted_key, 200);

    // Decrease 600 from free
    manager.decrease_position(locked_key, 600);

    let (free, locked) = manager.position(locked_key);
    assert_eq!(free, 0);
    assert_eq!(locked, 400);

    teardown(test, manager);
}

#[test, expected_failure(abort_code = predict_manager::EInsufficientFreePosition)]
fun lock_all_then_decrease_aborts() {
    let (_test, mut manager) = setup(@0x1);
    let locked_key = market_key::up(oracle_id!(), expiry!(), 100);
    let minted_key = market_key::up(oracle_id!(), expiry!(), 200);

    manager.increase_position(locked_key, 500);
    manager.lock_collateral(locked_key, minted_key, 500);

    // free = 0, locked = 500 → can't decrease even 1
    manager.decrease_position(locked_key, 1);

    abort
}

// === Zero Quantity Edge Cases ===

#[test]
fun increase_zero_is_noop() {
    let (test, mut manager) = setup(@0x1);
    let key = market_key::up(oracle_id!(), expiry!(), 100);

    manager.increase_position(key, 0);

    let (free, locked) = manager.position(key);
    assert_eq!(free, 0);
    assert_eq!(locked, 0);

    teardown(test, manager);
}

#[test]
fun decrease_zero_is_noop() {
    let (test, mut manager) = setup(@0x1);
    let key = market_key::up(oracle_id!(), expiry!(), 100);

    manager.increase_position(key, 100);
    manager.decrease_position(key, 0);

    let (free, _) = manager.position(key);
    assert_eq!(free, 100);

    teardown(test, manager);
}

#[test]
fun lock_zero_is_noop() {
    let (test, mut manager) = setup(@0x1);
    let locked_key = market_key::up(oracle_id!(), expiry!(), 100);
    let minted_key = market_key::up(oracle_id!(), expiry!(), 200);

    manager.increase_position(locked_key, 100);
    manager.lock_collateral(locked_key, minted_key, 0);

    let (free, locked) = manager.position(locked_key);
    assert_eq!(free, 100);
    assert_eq!(locked, 0);

    teardown(test, manager);
}

#[test]
fun release_zero_is_noop() {
    let (test, mut manager) = setup(@0x1);
    let locked_key = market_key::up(oracle_id!(), expiry!(), 100);
    let minted_key = market_key::up(oracle_id!(), expiry!(), 200);

    manager.increase_position(locked_key, 100);
    manager.lock_collateral(locked_key, minted_key, 50);
    manager.release_collateral(locked_key, minted_key, 0);

    let (free, locked) = manager.position(locked_key);
    assert_eq!(free, 50);
    assert_eq!(locked, 50);

    teardown(test, manager);
}

// === Multi-key Collateral Isolation ===

#[test]
fun collateral_pairs_are_isolated() {
    let (test, mut manager) = setup(@0x1);
    let locked_key = market_key::up(oracle_id!(), expiry!(), 100);
    let minted_a = market_key::up(oracle_id!(), expiry!(), 200);
    let minted_b = market_key::up(oracle_id!(), expiry!(), 300);

    manager.increase_position(locked_key, 1000);

    // Lock 400 for minted_a, 300 for minted_b
    manager.lock_collateral(locked_key, minted_a, 400);
    manager.lock_collateral(locked_key, minted_b, 300);

    let (free, locked) = manager.position(locked_key);
    assert_eq!(free, 300);
    assert_eq!(locked, 700);

    // Release only minted_a's 400
    manager.release_collateral(locked_key, minted_a, 400);
    let (free, locked) = manager.position(locked_key);
    assert_eq!(free, 700);
    assert_eq!(locked, 300);

    // minted_b's 300 still locked
    manager.release_collateral(locked_key, minted_b, 300);
    let (free, locked) = manager.position(locked_key);
    assert_eq!(free, 1000);
    assert_eq!(locked, 0);

    teardown(test, manager);
}

#[test]
fun owner_is_set_correctly() {
    let (test, manager) = setup(@0x42);

    assert_eq!(manager.owner(), @0x42);

    teardown(test, manager);
}
