// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::rate_limiter_tests;

use deepbook_predict::rate_limiter;
use sui::clock;

// Vault holds $10M. Withdrawal capacity = $5M (half of vault).
const VAULT_SIZE: u64 = 10_000_000_000_000;
const TEST_CAPACITY: u64 = 5_000_000_000_000;
const TEST_RATE: u64 = 16_667; // ~$1M/min

fun setup(): (rate_limiter::RateLimiter, clock::Clock) {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let limiter = rate_limiter::new_for_testing(TEST_CAPACITY, TEST_RATE, true, &clock);
    (limiter, clock)
}

// --- Basic operations ---

#[test]
fun new_default_is_disabled() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let limiter = rate_limiter::new(&clock);
    assert!(!limiter.is_enabled());
    assert!(limiter.capacity() == 0);
    assert!(limiter.available() == 0);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun new_for_testing_starts_full() {
    let (limiter, clock) = setup();
    assert!(limiter.available() == TEST_CAPACITY);
    assert!(limiter.capacity() == TEST_CAPACITY);
    assert!(limiter.refill_rate_per_ms() == TEST_RATE);
    assert!(limiter.is_enabled());
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun consume_reduces_available() {
    let (mut limiter, clock) = setup();
    let amount = 1_000_000_000_000;
    limiter.consume(amount, &clock);
    assert!(limiter.available() == TEST_CAPACITY - amount);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun consume_zero_is_noop() {
    let (mut limiter, clock) = setup();
    limiter.consume(0, &clock);
    assert!(limiter.available() == TEST_CAPACITY);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun consume_entire_bucket() {
    let (mut limiter, clock) = setup();
    limiter.consume(TEST_CAPACITY, &clock);
    assert!(limiter.available() == 0);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun disabled_limiter_allows_anything() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let mut limiter = rate_limiter::new_for_testing(TEST_CAPACITY, TEST_RATE, false, &clock);
    assert!(!limiter.is_enabled());
    limiter.consume(VAULT_SIZE, &clock);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

// --- Abort cases ---

#[test, expected_failure(abort_code = rate_limiter::EInsufficientWithdrawalBudget)]
fun consume_exceeds_available_aborts() {
    let (mut limiter, clock) = setup();
    limiter.consume(TEST_CAPACITY, &clock);
    limiter.consume(1, &clock);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EExceedsCapacity)]
fun consume_exceeds_capacity_aborts() {
    let (mut limiter, clock) = setup();
    limiter.consume(TEST_CAPACITY + 1, &clock);
    abort 999
}

#[test, expected_failure(abort_code = rate_limiter::EExceedsCapacity)]
fun single_withdrawal_of_full_vault_aborts() {
    let (mut limiter, clock) = setup();
    limiter.consume(VAULT_SIZE, &clock);
    abort 999
}

// --- Draining half the vault (capacity boundary) ---

#[test]
fun can_withdraw_exactly_half_vault() {
    let (mut limiter, clock) = setup();
    limiter.consume(VAULT_SIZE / 2, &clock);
    assert!(limiter.available() == 0);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun two_withdrawals_drain_bucket() {
    let (mut limiter, clock) = setup();
    let half_capacity = TEST_CAPACITY / 2;
    limiter.consume(half_capacity, &clock);
    assert!(limiter.available() == TEST_CAPACITY - half_capacity);
    limiter.consume(half_capacity, &clock);
    assert!(limiter.available() == TEST_CAPACITY - 2 * half_capacity);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test, expected_failure(abort_code = rate_limiter::EInsufficientWithdrawalBudget)]
fun third_large_withdrawal_blocked_without_refill() {
    let (mut limiter, clock) = setup();
    let amount = 2_000_000_000_000;
    limiter.consume(amount, &clock);
    limiter.consume(amount, &clock);
    limiter.consume(amount, &clock);
    abort
}

// --- Refill behavior ---

#[test]
fun refill_after_drain() {
    let (mut limiter, mut clock) = setup();
    limiter.consume(TEST_CAPACITY, &clock);
    assert!(limiter.available() == 0);
    clock.increment_for_testing(60_000);
    let expected_refill = 60_000 * TEST_RATE;
    limiter.consume(1, &clock);
    assert!(limiter.available() == expected_refill - 1);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun refill_caps_at_capacity_not_vault_size() {
    let (mut limiter, mut clock) = setup();
    limiter.consume(1_000_000, &clock);
    clock.increment_for_testing(1_000_000_000);
    limiter.consume(1, &clock);
    assert!(limiter.available() == TEST_CAPACITY - 1);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun partial_refill_allows_partial_withdrawal() {
    let (mut limiter, mut clock) = setup();
    limiter.consume(TEST_CAPACITY, &clock);
    clock.increment_for_testing(30_000);
    let refilled = 30_000 * TEST_RATE;
    limiter.consume(refilled, &clock);
    assert!(limiter.available() == 0);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test, expected_failure(abort_code = rate_limiter::EInsufficientWithdrawalBudget)]
fun partial_refill_rejects_larger_withdrawal() {
    let (mut limiter, mut clock) = setup();
    limiter.consume(TEST_CAPACITY, &clock);
    clock.increment_for_testing(30_000);
    let refilled = 30_000 * TEST_RATE;
    limiter.consume(refilled + 1, &clock);
    abort
}

#[test]
fun full_refill_time_to_capacity() {
    let (mut limiter, mut clock) = setup();
    limiter.consume(TEST_CAPACITY, &clock);
    let refill_time = TEST_CAPACITY / TEST_RATE;
    clock.increment_for_testing(refill_time);
    let refilled = refill_time * TEST_RATE;
    limiter.consume(1, &clock);
    assert!(limiter.available() == refilled - 1);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

// --- Deposit interactions ---

#[test]
fun deposit_replenishes_after_withdrawal() {
    let (mut limiter, clock) = setup();
    limiter.consume(3_000_000_000_000, &clock);
    assert!(limiter.available() == 2_000_000_000_000);
    limiter.record_deposit(3_000_000_000_000, &clock);
    assert!(limiter.available() == TEST_CAPACITY);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun deposit_larger_than_capacity_caps() {
    let (mut limiter, clock) = setup();
    limiter.record_deposit(VAULT_SIZE, &clock);
    assert!(limiter.available() == TEST_CAPACITY);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun deposit_after_full_drain_partial_restore() {
    let (mut limiter, clock) = setup();
    limiter.consume(TEST_CAPACITY, &clock);
    assert!(limiter.available() == 0);
    let deposit = 1_000_000_000_000;
    limiter.record_deposit(deposit, &clock);
    assert!(limiter.available() == deposit);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun deposit_plus_refill_interaction() {
    let (mut limiter, mut clock) = setup();
    limiter.consume(TEST_CAPACITY, &clock);
    clock.increment_for_testing(30_000);
    let deposit = 2_000_000_000_000;
    limiter.record_deposit(deposit, &clock);
    let refilled = 30_000 * TEST_RATE;
    let expected = refilled + deposit;
    assert!(limiter.available() == expected);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun deposit_plus_refill_caps_at_capacity() {
    let (mut limiter, mut clock) = setup();
    limiter.consume(1_000_000_000_000, &clock);
    clock.increment_for_testing(120_000);
    limiter.record_deposit(3_000_000_000_000, &clock);
    assert!(limiter.available() == TEST_CAPACITY);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

// --- Withdraw-deposit-withdraw cycle ---

#[test]
fun withdraw_deposit_withdraw_cycle() {
    let (mut limiter, clock) = setup();
    limiter.consume(4_000_000_000_000, &clock);
    assert!(limiter.available() == 1_000_000_000_000);
    limiter.record_deposit(2_000_000_000_000, &clock);
    assert!(limiter.available() == 3_000_000_000_000);
    limiter.consume(3_000_000_000_000, &clock);
    assert!(limiter.available() == 0);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test, expected_failure(abort_code = rate_limiter::EInsufficientWithdrawalBudget)]
fun withdraw_deposit_withdraw_exceeds() {
    let (mut limiter, clock) = setup();
    limiter.consume(4_000_000_000_000, &clock);
    limiter.record_deposit(2_000_000_000_000, &clock);
    limiter.consume(3_000_000_000_000, &clock);
    limiter.consume(1, &clock);
    abort
}

// --- Available withdrawal (read-only) ---

#[test]
fun available_withdrawal_reflects_refill() {
    let (mut limiter, mut clock) = setup();
    limiter.consume(TEST_CAPACITY, &clock);
    clock.increment_for_testing(60_000);
    let expected = 60_000 * TEST_RATE;
    assert!(limiter.available_withdrawal(&clock) == expected);
    assert!(limiter.available() == 0);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun available_withdrawal_when_disabled_returns_max() {
    let ctx = &mut tx_context::dummy();
    let clock = clock::create_for_testing(ctx);
    let limiter = rate_limiter::new_for_testing(TEST_CAPACITY, TEST_RATE, false, &clock);
    assert!(limiter.available_withdrawal(&clock) == std::u64::max_value!());
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

// --- Enable / disable ---

#[test]
fun enable_then_consume() {
    let ctx = &mut tx_context::dummy();
    let mut clock = clock::create_for_testing(ctx);
    let mut limiter = rate_limiter::new(&clock);
    assert!(!limiter.is_enabled());
    // Configure first, then enable.
    limiter.update_config(TEST_CAPACITY, TEST_RATE, &clock);
    limiter.enable(&clock);
    assert!(limiter.is_enabled());
    assert!(limiter.capacity() == TEST_CAPACITY);
    // Available is 0 because new() starts at 0 and update_config caps at capacity but doesn't increase.
    // Need to record a deposit or wait for refill.
    clock.increment_for_testing(60_000);
    let refilled = 60_000 * TEST_RATE;
    limiter.consume(refilled, &clock);
    assert!(limiter.available() == 0);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun disable_allows_any_consume() {
    let (mut limiter, clock) = setup();
    limiter.disable();
    assert!(!limiter.is_enabled());
    limiter.consume(VAULT_SIZE * 100, &clock);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

// --- Config updates ---

#[test]
fun update_config_preserves_refilled_tokens() {
    let (mut limiter, mut clock) = setup();
    limiter.consume(TEST_CAPACITY, &clock);
    clock.increment_for_testing(60_000);
    let old_refill = 60_000 * TEST_RATE;
    let new_capacity = 10_000_000_000_000;
    let new_rate = 33_334;
    limiter.update_config(new_capacity, new_rate, &clock);
    assert!(limiter.available() == old_refill);
    assert!(limiter.capacity() == new_capacity);
    assert!(limiter.refill_rate_per_ms() == new_rate);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun update_config_shrink_capacity_caps_available() {
    let (mut limiter, clock) = setup();
    let smaller = 2_000_000_000_000;
    limiter.update_config(smaller, TEST_RATE, &clock);
    assert!(limiter.available() == smaller);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test, expected_failure(abort_code = rate_limiter::EInvalidConfig)]
fun update_config_rate_exceeds_capacity_aborts() {
    let (mut limiter, clock) = setup();
    limiter.update_config(100, 100, &clock);
    abort
}

#[test, expected_failure(abort_code = rate_limiter::EInvalidConfig)]
fun update_config_zero_rate_aborts() {
    let (mut limiter, clock) = setup();
    limiter.update_config(TEST_CAPACITY, 0, &clock);
    abort
}

// --- Rapid cycle ---

#[test]
fun rapid_withdraw_refill_cycle() {
    let (mut limiter, mut clock) = setup();
    let amount = 1_000_000_000_000;
    limiter.consume(amount, &clock);
    clock.increment_for_testing(10_000);
    limiter.consume(amount, &clock);
    clock.increment_for_testing(10_000);
    limiter.consume(amount, &clock);
    clock.increment_for_testing(10_000);
    limiter.consume(amount, &clock);
    clock.increment_for_testing(10_000);
    limiter.consume(amount, &clock);
    let total_consumed = 5 * amount;
    let total_refilled = 4 * 10_000 * TEST_RATE;
    assert!(limiter.available() == TEST_CAPACITY - total_consumed + total_refilled);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test, expected_failure(abort_code = rate_limiter::EInsufficientWithdrawalBudget)]
fun rapid_withdrawals_eventually_blocked() {
    let (mut limiter, mut clock) = setup();
    let amount = 2_000_000_000_000;
    limiter.consume(amount, &clock);
    clock.increment_for_testing(10_000);
    limiter.consume(amount, &clock);
    clock.increment_for_testing(10_000);
    limiter.consume(amount, &clock);
    abort
}
