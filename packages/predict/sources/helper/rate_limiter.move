// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Token bucket rate limiter for controlling LP withdrawal rates.
///
/// Prevents rapid vault drain by limiting how much can be withdrawn over time.
/// The bucket refills continuously at a configurable rate, and each withdrawal
/// consumes tokens from the bucket.
///
/// Reference: Chainlink CCIP RateLimiter
/// https://github.com/code-423n4/2024-11-chainlink/blob/main/contracts/src/ccip/libraries/RateLimiter.sol
module deepbook_predict::rate_limiter;

use std::u128::min;
use sui::clock::Clock;

// === Errors ===

const EExceedsCapacity: u64 = 0;
const EInsufficientWithdrawalBudget: u64 = 1;
const EInvalidConfig: u64 = 2;

// === Structs ===

public struct RateLimiter has store {
    /// Current available tokens in the bucket.
    available: u64,
    /// Timestamp of the last refill (milliseconds).
    last_updated_ms: u64,
    /// Maximum burst capacity — single withdrawal cannot exceed this.
    capacity: u64,
    /// Tokens restored per millisecond.
    refill_rate_per_ms: u64,
    /// Whether the rate limiter is active.
    enabled: bool,
}

// === Public-Package Functions ===

/// Create a new rate limiter. Starts with a full bucket.
public(package) fun new(
    capacity: u64,
    refill_rate_per_ms: u64,
    enabled: bool,
    clock: &Clock,
): RateLimiter {
    RateLimiter {
        available: capacity,
        last_updated_ms: clock.timestamp_ms(),
        capacity,
        refill_rate_per_ms,
        enabled,
    }
}

/// Attempt to consume `amount` from the bucket. Aborts if rate limited.
public(package) fun consume(self: &mut RateLimiter, amount: u64, clock: &Clock) {
    if (!self.enabled || amount == 0) return;

    self.refill(clock);

    assert!(amount <= self.capacity, EExceedsCapacity);
    assert!(amount <= self.available, EInsufficientWithdrawalBudget);

    self.available = self.available - amount;
}

/// Record a deposit — increases available tokens (capped at capacity).
/// This allows deposits to partially replenish the withdrawal budget,
/// preventing the limiter from blocking withdrawals after heavy inflows.
public(package) fun record_deposit(self: &mut RateLimiter, amount: u64, clock: &Clock) {
    if (!self.enabled) return;

    self.refill(clock);

    let new_available = (self.available as u128) + (amount as u128);
    self.available = min(new_available, self.capacity as u128) as u64;
}

/// Returns the currently available withdrawal amount (read-only).
public(package) fun available_withdrawal(self: &RateLimiter, clock: &Clock): u64 {
    if (!self.enabled) return std::u64::max_value!();

    let elapsed = elapsed_ms(self.last_updated_ms, clock);
    let refill_amount = (elapsed as u128) * (self.refill_rate_per_ms as u128);
    let new_available = (self.available as u128) + refill_amount;

    min(new_available, self.capacity as u128) as u64
}

/// Update configuration. Refills with the old rate first, then applies new config.
public(package) fun update_config(
    self: &mut RateLimiter,
    capacity: u64,
    refill_rate_per_ms: u64,
    enabled: bool,
    clock: &Clock,
) {
    if (enabled) {
        assert!(refill_rate_per_ms > 0 && refill_rate_per_ms < capacity, EInvalidConfig);
    };

    self.refill(clock);
    self.capacity = capacity;
    self.refill_rate_per_ms = refill_rate_per_ms;
    self.enabled = enabled;
    if (self.available > capacity) {
        self.available = capacity;
    };
}

// === Public View Functions ===

public fun is_enabled(self: &RateLimiter): bool {
    self.enabled
}

public fun capacity(self: &RateLimiter): u64 {
    self.capacity
}

public fun refill_rate_per_ms(self: &RateLimiter): u64 {
    self.refill_rate_per_ms
}

// === Internal Functions ===

/// Refill the bucket based on time elapsed since last update.
fun refill(self: &mut RateLimiter, clock: &Clock) {
    let elapsed = elapsed_ms(self.last_updated_ms, clock);

    if (elapsed > 0) {
        let refill_amount = (elapsed as u128) * (self.refill_rate_per_ms as u128);
        let new_available = (self.available as u128) + refill_amount;
        self.available = min(new_available, self.capacity as u128) as u64;
        self.last_updated_ms = clock.timestamp_ms();
    }
}

/// Safe elapsed time calculation (handles clock edge cases).
fun elapsed_ms(last_updated_ms: u64, clock: &Clock): u64 {
    let current_time = clock.timestamp_ms();
    if (current_time > last_updated_ms) {
        current_time - last_updated_ms
    } else {
        0
    }
}

// === Test-only Functions ===

#[test_only]
public fun available(self: &RateLimiter): u64 {
    self.available
}

#[test_only]
public fun last_updated_ms(self: &RateLimiter): u64 {
    self.last_updated_ms
}

#[test_only]
public fun destroy_for_testing(self: RateLimiter) {
    let RateLimiter { available: _, last_updated_ms: _, capacity: _, refill_rate_per_ms: _, enabled: _ } = self;
}

// === Tests ===
//
// Vault holds $10M. Withdrawal capacity = $5M (half of vault).
// This tests edge cases where deposits exceed capacity, multiple
// withdrawals drain the bucket, and refill/deposit interactions.

#[test_only]
const VAULT_SIZE: u64 = 10_000_000_000_000; // $10M
#[test_only]
const TEST_CAPACITY: u64 = 5_000_000_000_000; // $5M (half of vault)
#[test_only]
const TEST_RATE: u64 = 16_667; // ~$1M/min

#[test_only]
fun setup(): (RateLimiter, sui::clock::Clock) {
    let ctx = &mut tx_context::dummy();
    let clock = sui::clock::create_for_testing(ctx);
    let limiter = new(TEST_CAPACITY, TEST_RATE, true, &clock);
    (limiter, clock)
}

// --- Basic operations ---

#[test]
fun new_limiter_starts_full() {
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
    let amount = 1_000_000_000_000; // $1M
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
    let clock = sui::clock::create_for_testing(ctx);
    let mut limiter = new(TEST_CAPACITY, TEST_RATE, false, &clock);
    assert!(!limiter.is_enabled());
    // Even VAULT_SIZE (2x capacity) should pass when disabled.
    limiter.consume(VAULT_SIZE, &clock);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

// --- Abort cases ---

#[test, expected_failure(abort_code = EInsufficientWithdrawalBudget)]
fun consume_exceeds_available_aborts() {
    let (mut limiter, clock) = setup();
    limiter.consume(TEST_CAPACITY, &clock);
    limiter.consume(1, &clock);
    abort
}

#[test, expected_failure(abort_code = EExceedsCapacity)]
fun consume_exceeds_capacity_aborts() {
    let (mut limiter, clock) = setup();
    // A single withdrawal of $5M + 1 exceeds max burst.
    limiter.consume(TEST_CAPACITY + 1, &clock);
    abort 999
}

#[test, expected_failure(abort_code = EExceedsCapacity)]
fun single_withdrawal_of_full_vault_aborts() {
    let (mut limiter, clock) = setup();
    // Vault is $10M but capacity is $5M — can't withdraw it all at once.
    limiter.consume(VAULT_SIZE, &clock);
    abort 999
}

// --- Draining half the vault (capacity boundary) ---

#[test]
fun can_withdraw_exactly_half_vault() {
    let (mut limiter, clock) = setup();
    // Capacity = $5M = half of $10M vault. Should succeed.
    limiter.consume(VAULT_SIZE / 2, &clock);
    assert!(limiter.available() == 0);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun two_withdrawals_drain_bucket() {
    let (mut limiter, clock) = setup();
    let half_capacity = TEST_CAPACITY / 2; // $2.5M
    limiter.consume(half_capacity, &clock);
    assert!(limiter.available() == TEST_CAPACITY - half_capacity);
    limiter.consume(half_capacity, &clock);
    assert!(limiter.available() == TEST_CAPACITY - 2 * half_capacity);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test, expected_failure(abort_code = EInsufficientWithdrawalBudget)]
fun third_large_withdrawal_blocked_without_refill() {
    let (mut limiter, clock) = setup();
    let amount = 2_000_000_000_000; // $2M
    limiter.consume(amount, &clock); // $3M left
    limiter.consume(amount, &clock); // $1M left
    limiter.consume(amount, &clock); // needs $2M, only $1M → abort
    abort
}

// --- Refill behavior ---

#[test]
fun refill_after_drain() {
    let (mut limiter, mut clock) = setup();
    limiter.consume(TEST_CAPACITY, &clock);
    assert!(limiter.available() == 0);
    // Wait 60s → refill ~$1M
    clock.increment_for_testing(60_000);
    let expected_refill = 60_000 * TEST_RATE; // 1,000,020,000
    limiter.consume(1, &clock); // trigger refill
    assert!(limiter.available() == expected_refill - 1);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun refill_caps_at_capacity_not_vault_size() {
    let (mut limiter, mut clock) = setup();
    limiter.consume(1_000_000, &clock);
    // Wait a very long time — refill should cap at $5M, not $10M.
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
    // Wait 30s → refill ~$500k
    clock.increment_for_testing(30_000);
    let refilled = 30_000 * TEST_RATE;
    limiter.consume(refilled, &clock);
    assert!(limiter.available() == 0);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test, expected_failure(abort_code = EInsufficientWithdrawalBudget)]
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
    // Time to fully refill = capacity / rate = 5_000_000_000_000 / 16_667 ≈ 299,988,001 ms (~5 min)
    let refill_time = TEST_CAPACITY / TEST_RATE;
    clock.increment_for_testing(refill_time);
    let refilled = refill_time * TEST_RATE;
    // May be slightly less than capacity due to integer division.
    limiter.consume(1, &clock);
    assert!(limiter.available() == refilled - 1);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

// --- Deposit interactions ---

#[test]
fun deposit_replenishes_after_withdrawal() {
    let (mut limiter, clock) = setup();
    limiter.consume(3_000_000_000_000, &clock); // withdraw $3M → $2M left
    assert!(limiter.available() == 2_000_000_000_000);
    // Deposit $3M → should restore to capacity ($5M), not $5M + deposited
    limiter.record_deposit(3_000_000_000_000, &clock);
    assert!(limiter.available() == TEST_CAPACITY);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun deposit_larger_than_capacity_caps() {
    let (mut limiter, clock) = setup();
    // Deposit $10M (full vault size) — should cap at $5M capacity.
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
    // Small deposit — doesn't reach capacity.
    let deposit = 1_000_000_000_000; // $1M
    limiter.record_deposit(deposit, &clock);
    assert!(limiter.available() == deposit);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun deposit_plus_refill_interaction() {
    let (mut limiter, mut clock) = setup();
    limiter.consume(TEST_CAPACITY, &clock); // drain to 0
    clock.increment_for_testing(30_000); // 30s → ~$500k refill
    // Deposit $2M — refill happens first, then deposit adds on top.
    let deposit = 2_000_000_000_000;
    limiter.record_deposit(deposit, &clock);
    let refilled = 30_000 * TEST_RATE;
    let expected = refilled + deposit; // should not exceed capacity
    assert!(limiter.available() == expected);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun deposit_plus_refill_caps_at_capacity() {
    let (mut limiter, mut clock) = setup();
    limiter.consume(1_000_000_000_000, &clock); // withdraw $1M → $4M left
    clock.increment_for_testing(120_000); // 2 min → refills ~$2M → caps at $5M
    // Deposit $3M on top — still caps at $5M.
    limiter.record_deposit(3_000_000_000_000, &clock);
    assert!(limiter.available() == TEST_CAPACITY);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

// --- Withdraw-deposit-withdraw cycle ---

#[test]
fun withdraw_deposit_withdraw_cycle() {
    let (mut limiter, clock) = setup();
    // Withdraw $4M → $1M left
    limiter.consume(4_000_000_000_000, &clock);
    assert!(limiter.available() == 1_000_000_000_000);
    // Deposit $2M → $3M available
    limiter.record_deposit(2_000_000_000_000, &clock);
    assert!(limiter.available() == 3_000_000_000_000);
    // Withdraw $3M → $0 left
    limiter.consume(3_000_000_000_000, &clock);
    assert!(limiter.available() == 0);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test, expected_failure(abort_code = EInsufficientWithdrawalBudget)]
fun withdraw_deposit_withdraw_exceeds() {
    let (mut limiter, clock) = setup();
    limiter.consume(4_000_000_000_000, &clock); // $1M left
    limiter.record_deposit(2_000_000_000_000, &clock); // $3M available
    limiter.consume(3_000_000_000_000, &clock); // $0 left
    limiter.consume(1, &clock); // nothing left → abort
    abort
}

// --- Available withdrawal (read-only) ---

#[test]
fun available_withdrawal_reflects_refill() {
    let (mut limiter, mut clock) = setup();
    limiter.consume(TEST_CAPACITY, &clock);
    clock.increment_for_testing(60_000);
    let expected = 60_000 * TEST_RATE;
    // Read-only — should not modify state.
    assert!(limiter.available_withdrawal(&clock) == expected);
    assert!(limiter.available() == 0); // internal state unchanged
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun available_withdrawal_when_disabled_returns_max() {
    let ctx = &mut tx_context::dummy();
    let clock = sui::clock::create_for_testing(ctx);
    let limiter = new(TEST_CAPACITY, TEST_RATE, false, &clock);
    assert!(limiter.available_withdrawal(&clock) == std::u64::max_value!());
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
    let new_capacity = 10_000_000_000_000; // $10M
    let new_rate = 33_334;
    limiter.update_config(new_capacity, new_rate, true, &clock);
    assert!(limiter.available() == old_refill);
    assert!(limiter.capacity() == new_capacity);
    assert!(limiter.refill_rate_per_ms() == new_rate);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test]
fun update_config_shrink_capacity_caps_available() {
    let (mut limiter, clock) = setup();
    // Bucket is full at $5M. Shrink capacity to $2M.
    let smaller = 2_000_000_000_000;
    limiter.update_config(smaller, TEST_RATE, true, &clock);
    assert!(limiter.available() == smaller);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test, expected_failure(abort_code = EInvalidConfig)]
fun update_config_rate_exceeds_capacity_aborts() {
    let (mut limiter, clock) = setup();
    limiter.update_config(100, 100, true, &clock);
    abort
}

#[test, expected_failure(abort_code = EInvalidConfig)]
fun update_config_zero_rate_when_enabled_aborts() {
    let (mut limiter, clock) = setup();
    limiter.update_config(TEST_CAPACITY, 0, true, &clock);
    abort
}

#[test]
fun update_config_disable_allows_zero() {
    let (mut limiter, clock) = setup();
    limiter.update_config(0, 0, false, &clock);
    assert!(!limiter.is_enabled());
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

// --- Rapid cycle ---

#[test]
fun rapid_withdraw_refill_cycle() {
    let (mut limiter, mut clock) = setup();
    let amount = 1_000_000_000_000; // $1M per withdrawal
    // 5 withdrawals with 10s gaps between them.
    limiter.consume(amount, &clock);
    clock.increment_for_testing(10_000);
    limiter.consume(amount, &clock);
    clock.increment_for_testing(10_000);
    limiter.consume(amount, &clock);
    clock.increment_for_testing(10_000);
    limiter.consume(amount, &clock);
    clock.increment_for_testing(10_000);
    limiter.consume(amount, &clock);
    // 5 × $1M consumed, 4 × 10s × RATE refilled.
    let total_consumed = 5 * amount;
    let total_refilled = 4 * 10_000 * TEST_RATE;
    assert!(limiter.available() == TEST_CAPACITY - total_consumed + total_refilled);
    limiter.destroy_for_testing();
    clock.destroy_for_testing();
}

#[test, expected_failure(abort_code = EInsufficientWithdrawalBudget)]
fun rapid_withdrawals_eventually_blocked() {
    let (mut limiter, mut clock) = setup();
    let amount = 2_000_000_000_000; // $2M per withdrawal
    // $2M withdrawals with only 10s refill (~$166k) between.
    limiter.consume(amount, &clock); // $3M left
    clock.increment_for_testing(10_000);
    limiter.consume(amount, &clock); // ~$1.17M left
    clock.increment_for_testing(10_000);
    // ~$1.33M available, need $2M → abort
    limiter.consume(amount, &clock);
    abort
}
