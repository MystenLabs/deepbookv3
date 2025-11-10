// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook_margin::rate_limiter;

use sui::clock::Clock;

public struct RateLimiter has store {
    transactions: vector<Transaction>,
    window_duration_ms: u64,
    max_net_withdrawal: u64,
    enabled: bool,
}

public struct Transaction has copy, drop, store {
    amount: u64,
    is_deposit: bool,
    timestamp_ms: u64,
}

// === Public-Package Functions ===

public(package) fun new(
    window_duration_ms: u64,
    max_net_withdrawal: u64,
    enabled: bool,
): RateLimiter {
    RateLimiter {
        transactions: vector::empty(),
        window_duration_ms,
        max_net_withdrawal,
        enabled,
    }
}

public(package) fun record_deposit(self: &mut RateLimiter, amount: u64, clock: &Clock) {
    if (!self.enabled) return;

    self.clean_old_transactions(clock);
    self
        .transactions
        .push_back(Transaction {
            amount,
            is_deposit: true,
            timestamp_ms: clock.timestamp_ms(),
        });
}

public(package) fun check_and_record_withdrawal(
    self: &mut RateLimiter,
    amount: u64,
    clock: &Clock,
): bool {
    if (!self.enabled) return true;

    self.clean_old_transactions(clock);

    let net_withdrawal = self.calculate_net_withdrawal();
    let new_net = if (net_withdrawal > 0) {
        net_withdrawal + amount
    } else {
        amount
    };

    if (new_net > self.max_net_withdrawal) {
        return false
    };

    self
        .transactions
        .push_back(Transaction {
            amount,
            is_deposit: false,
            timestamp_ms: clock.timestamp_ms(),
        });
    true
}

public(package) fun get_available_withdrawal(self: &RateLimiter, clock: &Clock): u64 {
    if (!self.enabled) return self.max_net_withdrawal;

    let net_withdrawal = self.calculate_net_withdrawal_at_time(clock.timestamp_ms());

    if (net_withdrawal >= self.max_net_withdrawal) {
        0
    } else {
        self.max_net_withdrawal - net_withdrawal
    }
}

public(package) fun update_config(
    self: &mut RateLimiter,
    window_duration_ms: u64,
    max_net_withdrawal: u64,
    enabled: bool,
) {
    self.window_duration_ms = window_duration_ms;
    self.max_net_withdrawal = max_net_withdrawal;
    self.enabled = enabled;
}

// === Public View Functions ===

public fun is_enabled(self: &RateLimiter): bool {
    self.enabled
}

public fun max_net_withdrawal(self: &RateLimiter): u64 {
    self.max_net_withdrawal
}

public fun window_duration_ms(self: &RateLimiter): u64 {
    self.window_duration_ms
}

public fun current_net_withdrawal(self: &RateLimiter, clock: &Clock): u64 {
    self.calculate_net_withdrawal_at_time(clock.timestamp_ms())
}

// === Internal Functions ===

fun calculate_net_withdrawal(self: &RateLimiter): u64 {
    let mut total_deposits = 0;
    let mut total_withdrawals = 0;

    self.transactions.do_ref!(|tx| {
        if (tx.is_deposit) {
            total_deposits = total_deposits + tx.amount;
        } else {
            total_withdrawals = total_withdrawals + tx.amount;
        };
    });

    if (total_withdrawals > total_deposits) {
        total_withdrawals - total_deposits
    } else {
        0
    }
}

fun calculate_net_withdrawal_at_time(self: &RateLimiter, current_time: u64): u64 {
    let mut total_deposits = 0;
    let mut total_withdrawals = 0;
    let cutoff_time = if (current_time > self.window_duration_ms) {
        current_time - self.window_duration_ms
    } else {
        0
    };

    self.transactions.filter!(|tx| tx.timestamp_ms >= cutoff_time).do_ref!(|tx| {
        if (tx.is_deposit) {
            total_deposits = total_deposits + tx.amount;
        } else {
            total_withdrawals = total_withdrawals + tx.amount;
        };
    });

    if (total_withdrawals > total_deposits) {
        total_withdrawals - total_deposits
    } else {
        0
    }
}

fun clean_old_transactions(self: &mut RateLimiter, clock: &Clock) {
    let current_time = clock.timestamp_ms();
    let cutoff_time = if (current_time > self.window_duration_ms) {
        current_time - self.window_duration_ms
    } else {
        0
    };

    self.transactions = self.transactions.filter!(|tx| tx.timestamp_ms >= cutoff_time);
}
