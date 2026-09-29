// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module venue::curve_tests;

use std::unit_test::assert_eq;
use venue::index_curve;

const SCALE: u64 = 1_000_000_000;
const CENT: u64 = 10_000_000;

#[test]
fun levered_open_rounds_to_the_written_price() {
    let price = index_curve::spread_price(s(88), s_floor(), s(100), s(8), s(10));
    assert_eq!(round_cents(price), 8015);
}

#[test]
fun unlevered_open_rounds_to_the_written_price() {
    let price = index_curve::spread_price(s(88), s(55), s(100), s(8), s(10));
    assert_eq!(round_cents(price), 32766);
}

#[test]
fun tighter_and_wider_std_round_to_the_written_prices() {
    let tight = index_curve::spread_price(s(88), s_floor(), s(100), s(4), s(10));
    let wide = index_curve::spread_price(s(88), s_floor(), s(100), s(16), s(10));
    assert_eq!(round_cents(tight), 7546);
    assert_eq!(round_cents(wide), 8723);
}

#[test]
fun wider_std_lowers_the_price_at_the_new_mid() {
    let tight = proceeds(4);
    let mid = proceeds(8);
    let wide = proceeds(16);
    assert_eq!(round_cents(tight), 11354);
    assert_eq!(round_cents(mid), 10992);
    assert_eq!(round_cents(wide), 10444);
}

#[test]
fun short_payout_is_the_complement_of_the_long() {
    // Size 10, bounds 0 to 100. Max payoff is 1,000.
    // Result 0 pays the short the whole 1,000. Result 40 pays 600. Result 100 pays 0.
    assert_eq!(index_curve::short_payout(s(10), 0, s(100), 0), s(1000));
    assert_eq!(index_curve::short_payout(s(10), 0, s(100), s(40)), s(600));
    assert_eq!(index_curve::short_payout(s(10), 0, s(100), s(100)), 0);
}

#[test]
fun claim_pays_the_capped_distance() {
    assert_eq!(index_curve::claim_payout(s(10), s_floor(), s(100), s(80)), 0);
    assert_eq!(index_curve::claim_payout(s(10), s_floor(), s(100), s(88)), s(75));
    assert_eq!(index_curve::claim_payout(s(10), s_floor(), s(100), s(100)), s(195));
    assert_eq!(index_curve::claim_payout(s(10), s_floor(), s(100), s(120)), s(195));
}

#[test]
fun one_percent_fee_is_one_percent_of_the_unrounded_price() {
    let price = index_curve::spread_price(s(88), s_floor(), s(100), s(8), s(10));
    assert_eq!(index_curve::fee_on(price, 100), price / 100);
}

#[test, expected_failure(abort_code = index_curve::EStdZero)]
fun zero_std_aborts() {
    index_curve::spread_price(s(88), s_floor(), s(100), 0, s(10));
}

fun proceeds(std: u64): u64 {
    let price = index_curve::spread_price(s(92), s_floor(), s(100), s(std), s(10));
    price - index_curve::fee_on(price, 100)
}

fun s(whole: u64): u64 { whole * SCALE }

fun s_floor(): u64 { 80 * SCALE + SCALE / 2 }

fun round_cents(amount: u64): u64 {
    (amount + CENT / 2) / CENT
}
