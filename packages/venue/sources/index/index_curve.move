// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Prices one convex index spread with the normal curve.
/// `d(k) = (mid − k) / std`.
/// The unit price is the floor leg minus the cap leg.
/// A leg is `(mid − k) Φ(d) + std φ(d)`.
/// Every input and the result use 1e9 fixed point.
module venue::index_curve;

use fixed_math::{i64::{Self, I64}, math::{Self, mul_div_down}};

const EStdZero: u64 = 0;
const ERange: u64 = 1;
const ENegative: u64 = 2;

const SCALE: u64 = 1_000_000_000;

/// Returns the 1e9 scale used by prices, mids, and standard deviations.
public fun scale(): u64 { SCALE }

/// Returns `size × (floor leg − cap leg)`.
/// `floor` and `cap` are the ticket bounds. `std` is the standard deviation.
public fun spread_price(mid: u64, floor: u64, cap: u64, std: u64, size: u64): u64 {
    assert!(std > 0, EStdZero);
    assert!(cap > floor, ERange);
    let floor_leg = leg(mid, floor, std);
    let cap_leg = leg(mid, cap, std);
    let unit = i64::sub(&floor_leg, &cap_leg);
    assert!(!i64::is_negative(&unit), ENegative);
    mul_div_down(size, i64::magnitude(&unit), SCALE)
}

/// Returns the fee on `amount` at `bps` out of 10_000.
public fun fee_on(amount: u64, bps: u64): u64 {
    mul_div_down(amount, bps, 10_000)
}

/// Returns the complement of `spread_price` on the same bounds.
/// A short pays this to buy the slice from `floor` up to `cap`.
public fun short_price(mid: u64, floor: u64, cap: u64, std: u64, size: u64): u64 {
    let full = worst_case(floor, cap, size);
    let long = spread_price(mid, floor, cap, std, size);
    assert!(full >= long, ENegative);
    full - long
}

/// Returns `size × max(0, min(result, cap) − floor)` at 1e9 scale.
public fun claim_payout(size: u64, floor: u64, cap: u64, result: u64): u64 {
    let capped = if (result < cap) { result } else { cap };
    if (capped <= floor) { 0 } else { mul_div_down(size, capped - floor, SCALE) }
}

/// Returns the complement of `claim_payout` on the same bounds.
public fun short_payout(size: u64, floor: u64, cap: u64, result: u64): u64 {
    let full = worst_case(floor, cap, size);
    let long = claim_payout(size, floor, cap, result);
    full - long
}

/// Returns `(cap − floor) × size` at 1e9 scale.
public fun worst_case(floor: u64, cap: u64, size: u64): u64 {
    assert!(cap > floor, ERange);
    mul_div_down(size, cap - floor, SCALE)
}

fun leg(mid: u64, strike: u64, std: u64): I64 {
    let gap = signed_diff(mid, strike);
    let std_i = i64::from_u64(std);
    let d = i64::div_scaled(&gap, &std_i);
    let phi = i64::from_u64(math::normal_cdf(&d));
    let density = i64::from_u64(math::normal_pdf(&d));
    let first = i64::mul_scaled(&gap, &phi);
    let second = i64::mul_scaled(&std_i, &density);
    i64::add(&first, &second)
}

fun signed_diff(a: u64, b: u64): I64 {
    if (a >= b) {
        i64::from_u64(a - b)
    } else {
        i64::from_parts(b - a, true)
    }
}
