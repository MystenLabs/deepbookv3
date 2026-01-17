// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Token Bucket rate limiter for controlling withdrawal rates.
/// Reference: https://github.com/code-423n4/2024-11-chainlink/blob/main/contracts/src/ccip/libraries/RateLimiter.sol
module deepbook_margin::rate_limiter;

use std::u128::min;
use sui::clock::Clock;

public struct RateLimiter has store {
    available: u64,
    last_updated_ms: u64,
    capacity: u64,
    refill_rate_per_ms: u64,
    enabled: bool,
}

// === Public-Package Functions ===

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

public(package) fun check_and_record_withdrawal(
    self: &mut RateLimiter,
    amount: u64,
    clock: &Clock,
): bool {
    if (!self.enabled) return true;

    self.refill(clock);

    if (amount > self.available) {
        return false
    };

    self.available = self.available - amount;
    true
}

public(package) fun record_deposit(self: &mut RateLimiter, amount: u64, clock: &Clock) {
    if (!self.enabled) return;

    self.refill(clock);

    let new_available = (self.available as u128) + (amount as u128);
    self.available = min(new_available, self.capacity as u128) as u64;
}

public(package) fun get_available_withdrawal(self: &RateLimiter, clock: &Clock): u64 {
    if (!self.enabled) return std::u64::max_value!();

    let current_time = clock.timestamp_ms();
    let elapsed = if (current_time > self.last_updated_ms) {
        current_time - self.last_updated_ms
    } else {
        0
    };
    let refill_amount = (elapsed as u128) * (self.refill_rate_per_ms as u128);
    let new_available = (self.available as u128) + refill_amount;

    min(new_available, self.capacity as u128) as u64
}

public(package) fun update_config(
    self: &mut RateLimiter,
    capacity: u64,
    refill_rate_per_ms: u64,
    enabled: bool,
    clock: &Clock,
) {
    // Accumulate available using the old rate before updating config
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

fun refill(self: &mut RateLimiter, clock: &Clock) {
    let current_time = clock.timestamp_ms();
    let elapsed = if (current_time > self.last_updated_ms) {
        current_time - self.last_updated_ms
    } else {
        0
    };

    if (elapsed > 0) {
        let refill_amount = (elapsed as u128) * (self.refill_rate_per_ms as u128);
        let new_available = (self.available as u128) + refill_amount;
        self.available = min(new_available, self.capacity as u128) as u64;
        self.last_updated_ms = current_time;
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
