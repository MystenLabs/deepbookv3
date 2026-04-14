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

// === Public Functions ===

public fun is_enabled(self: &RateLimiter): bool {
    self.enabled
}

public fun capacity(self: &RateLimiter): u64 {
    self.capacity
}

public fun refill_rate_per_ms(self: &RateLimiter): u64 {
    self.refill_rate_per_ms
}

public fun available(self: &RateLimiter): u64 {
    self.available
}

/// Returns the currently available withdrawal amount (read-only).
public fun available_withdrawal(self: &RateLimiter, clock: &Clock): u64 {
    if (!self.enabled) return std::u64::max_value!();

    let elapsed = elapsed_ms(self.last_updated_ms, clock);
    // u128 needed: elapsed (u64) * refill_rate_per_ms (u64) can overflow u64
    // when large time gaps accumulate (e.g. 1M seconds × 16667 rate = 1.6e13,
    // plus available up to 5e12, sum can approach u64::MAX).
    let refill_amount = (elapsed as u128) * (self.refill_rate_per_ms as u128);
    let new_available = (self.available as u128) + refill_amount;

    new_available.min(self.capacity as u128) as u64
}

// === Public-Package Functions ===

/// Create a new rate limiter. Starts disabled with zero capacity.
/// Admin must call enable() and update_config() to activate.
public(package) fun new(clock: &Clock): RateLimiter {
    RateLimiter {
        available: 0,
        last_updated_ms: clock.timestamp_ms(),
        capacity: 0,
        refill_rate_per_ms: 0,
        enabled: false,
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

    // u128 needed: available (up to capacity, u64) + amount (u64) can overflow u64
    // when a large deposit arrives on top of a nearly-full bucket.
    let new_available = (self.available as u128) + (amount as u128);
    self.available = new_available.min(self.capacity as u128) as u64;
}

/// Enable the rate limiter. Requires capacity and rate to be configured first.
public(package) fun enable(self: &mut RateLimiter, clock: &Clock) {
    assert!(self.refill_rate_per_ms > 0 && self.refill_rate_per_ms < self.capacity, EInvalidConfig);
    self.refill(clock);
    self.enabled = true;
}

/// Disable the rate limiter without changing capacity or rate.
public(package) fun disable(self: &mut RateLimiter) {
    self.enabled = false;
}

/// Update capacity and refill rate. Does not change the enabled flag.
public(package) fun update_config(
    self: &mut RateLimiter,
    capacity: u64,
    refill_rate_per_ms: u64,
    clock: &Clock,
) {
    assert!(refill_rate_per_ms > 0 && refill_rate_per_ms < capacity, EInvalidConfig);

    self.refill(clock);
    self.capacity = capacity;
    self.refill_rate_per_ms = refill_rate_per_ms;
    if (self.available > capacity) {
        self.available = capacity;
    };
}

// === Internal Functions ===

/// Refill the bucket based on time elapsed since last update.
fun refill(self: &mut RateLimiter, clock: &Clock) {
    let elapsed = elapsed_ms(self.last_updated_ms, clock);

    if (elapsed > 0) {
        // u128 needed: see available_withdrawal() comment for overflow reasoning.
        let refill_amount = (elapsed as u128) * (self.refill_rate_per_ms as u128);
        let new_available = (self.available as u128) + refill_amount;
        self.available = new_available.min(self.capacity as u128) as u64;
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
public fun destroy_for_testing(self: RateLimiter) {
    let RateLimiter { available: _, last_updated_ms: _, capacity: _, refill_rate_per_ms: _, enabled: _ } = self;
}

#[test_only]
public fun new_for_testing(
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
