// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

module deepbook::math {
    /// scaling setting for float
    const FLOAT_SCALING_U128: u128 = 1_000_000_000;

    // <<<<<<<<<<<<<<<<<<<<<<<< Error codes <<<<<<<<<<<<<<<<<<<<<<<<
    const EUnderflow: u64 = 1;
    // <<<<<<<<<<<<<<<<<<<<<<<< Error codes <<<<<<<<<<<<<<<<<<<<<<<<

    // multiply two floating numbers and assert the result is non zero
    // Note that this function will still round down
    public(package) fun mul(x: u64, y: u64): u64 {
        let (_, result) = unsafe_mul_round(x, y);
        assert!(result > 0, EUnderflow);
        result
    }

    // TODO: verify logic here
    public(package) fun mul_round_up(x: u64, y: u64): u64 {
        let (is_round_down, result) = unsafe_mul_round(x, y);
        assert!(result > 0, EUnderflow);
        if (is_round_down) {
            result + 1
        } else {
            result
        }
    }

    // multiply two floating numbers
    // also returns whether the result is rounded down
    public(package) fun unsafe_mul_round(x: u64, y: u64): (bool, u64) {
        let x = x as u128;
        let y = y as u128;
        let mut is_round_down = true;
        if ((x * y) % FLOAT_SCALING_U128 == 0) is_round_down = false;
        (is_round_down, (x * y / FLOAT_SCALING_U128) as u64)
    }

    /// divide two floating numbers
    public(package) fun div(x: u64, y: u64): u64 {
        let (_, result) = unsafe_div_round(x, y);
        result
    }

    /// divide two floating numbers
    /// also returns whether the result is rounded down
    public(package) fun unsafe_div_round(x: u64, y: u64): (bool, u64) {
        let x = x as u128;
        let y = y as u128;
        let mut is_round_down = true;
        if ((x * FLOAT_SCALING_U128 % y) == 0) is_round_down = false;
        (is_round_down, (x * FLOAT_SCALING_U128 / y) as u64)
    }

    public(package) fun min(x: u64, y: u64): u64 {
        if (x <= y) {
            x
        } else {
            y
        }
    }

    public(package) fun max(x: u64, y: u64): u64 {
        if (x > y) {
            x
        } else {
            y
        }
    }
}
