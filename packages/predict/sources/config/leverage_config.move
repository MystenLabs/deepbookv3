// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored leverage template and pure time-to-expiry borrow index math.
///
/// Protocol config stores the admin-tunable terminal borrow fee used by future
/// expiry markets. Each market should snapshot that value at creation, then use
/// the pure index formula so later admin updates do not reprice active markets.
module deepbook_predict::leverage_config;

use deepbook_predict::{config_constants, constants, math};

const EInvalidExpiryWindow: u64 = 0;

/// Leverage parameters expressed in Predict's 1e9 fixed-point price scaling.
public struct LeverageConfig has store {
    /// Maximum total time-only borrow premium over one expiry.
    /// `200_000_000` means the borrow index rises from 1.00 to 1.20.
    max_expiry_borrow_fee: u64,
}

// === Public-Package Functions ===

public(package) fun max_expiry_borrow_fee(config: &LeverageConfig): u64 {
    config.max_expiry_borrow_fee
}

public(package) fun new(): LeverageConfig {
    LeverageConfig {
        max_expiry_borrow_fee: config_constants::default_max_expiry_borrow_fee!(),
    }
}

public(package) fun set_max_expiry_borrow_fee(config: &mut LeverageConfig, value: u64) {
    config_constants::assert_max_expiry_borrow_fee(value);
    config.max_expiry_borrow_fee = value;
}

public(package) fun debt_terms(
    max_expiry_borrow_fee: u64,
    expiry_ms: u64,
    inserted_at_ms: u64,
    now_ms: u64,
    borrowed_principal: u64,
): (u64, u64) {
    let initial_index = borrow_index(max_expiry_borrow_fee, expiry_ms, inserted_at_ms);
    let current_index = borrow_index(max_expiry_borrow_fee, expiry_ms, now_ms);
    let debt_amount = math::mul_div_round_up(borrowed_principal, current_index, initial_index);
    (debt_amount, debt_amount - borrowed_principal)
}

// === Private Functions ===

fun borrow_index(max_expiry_borrow_fee: u64, expiry_ms: u64, now_ms: u64): u64 {
    assert!(expiry_ms > 0, EInvalidExpiryWindow);

    let window = constants::leverage_borrow_window_ms!();
    let remaining = if (now_ms >= expiry_ms) {
        0
    } else {
        expiry_ms - now_ms
    };
    let elapsed = if (remaining >= window) {
        0
    } else {
        window - remaining
    };
    let phase = math::mul_div_round_down(elapsed, constants::float_scaling!(), window);
    let phase_squared = math::mul_div_round_down(
        phase,
        phase,
        constants::float_scaling!(),
    );

    constants::float_scaling!()
        + math::mul_div_round_down(
            max_expiry_borrow_fee,
            phase_squared,
            constants::float_scaling!(),
        )
}
