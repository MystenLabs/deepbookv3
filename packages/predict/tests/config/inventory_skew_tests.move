// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for `strike_exposure_config::skewed_up_price`, the read-time
/// inventory skew applied to one strike boundary's UP probability.
///
/// Every expected value here is derived from the mechanism's specification, not
/// from the implementation's expression: the shift is
/// `max_skew_shift · min(1, |aggregate| / depth) · 4·p·(1-p)`, added when the
/// pool is net short UP (negative aggregate) and subtracted when it is net long.
/// Each constant below shows that arithmetic worked out by hand.
///
/// Setter-envelope coverage for `EInvalidSkewDepthLots` / `EInvalidMaxSkewShift`
/// lives here too, driven through the package setters that the admin
/// entrypoints delegate to.
#[test_only]
module deepbook_predict::inventory_skew_tests;

use deepbook_predict::{config_constants, strike_exposure_config};
use fixed_math::i64;
use std::unit_test::{assert_eq, destroy};

/// 2% — the shift a fully-loaded book applies at the money.
const MAX_SHIFT_TWO_PERCENT: u64 = 20_000_000;
/// Net one-sided position, in lots, at which the skew reaches its full shift.
const DEPTH_LOTS: u64 = 1_000_000;
const HALF_DEPTH_LOTS: u64 = 500_000;
/// Ten times the depth, to exercise the saturation clamp on the depth ratio.
const TEN_TIMES_DEPTH_LOTS: u64 = 10_000_000;

/// p = 0.50 — at the money, where the moneyness weight `4·p·(1-p)` is exactly 1.
const P_AT_THE_MONEY: u64 = 500_000_000;
/// p = 0.25 — moneyness weight `4 · 0.25 · 0.75 = 0.75`.
const P_QUARTER: u64 = 250_000_000;
/// p = 0.01 — moneyness weight `4 · 0.01 · 0.99 = 0.0396`.
const P_ONE_PERCENT: u64 = 10_000_000;
/// p = 0.99 — moneyness weight `4 · 0.99 · 0.01 = 0.0396`, the mirror of the above.
const P_NINETY_NINE_PERCENT: u64 = 990_000_000;
/// `P(-inf) = 1`: the certain end of the range, where the skew must be inert.
const P_NEGATIVE_INFINITY_SENTINEL: u64 = 1_000_000_000;
/// `P(+inf) = 0`: the impossible end of the range, likewise inert.
const P_POSITIVE_INFINITY_SENTINEL: u64 = 0;

/// 0.50 + (0.02 · 1 · 1) = 0.52. Pool is short UP, so UP gets dearer.
const ATM_FULL_SHORT: u64 = 520_000_000;
/// 0.50 - (0.02 · 1 · 1) = 0.48. Pool is long UP, so UP gets cheaper.
const ATM_FULL_LONG: u64 = 480_000_000;
/// 0.50 + (0.02 · 0.5 · 1) = 0.51.
const ATM_HALF_DEPTH_SHORT: u64 = 510_000_000;
/// 0.25 + (0.02 · 1 · 0.75) = 0.25 + 0.015 = 0.265.
const QUARTER_FULL_SHORT: u64 = 265_000_000;
/// 0.01 - (0.05 · 1 · 0.0396) = 0.01 - 0.00198 = 0.00802. Still strictly above 0.
const ONE_PERCENT_FULL_LONG_AT_CEILING: u64 = 8_020_000;
/// 0.99 + (0.05 · 1 · 0.0396) = 0.99 + 0.00198 = 0.99198. Still strictly below 1.
const NINETY_NINE_PERCENT_FULL_SHORT_AT_CEILING: u64 = 991_980_000;

/// A config with the skew enabled at 2% over a 1,000,000-lot depth.
fun skewed_config(): strike_exposure_config::StrikeExposureConfig {
    let mut config = strike_exposure_config::new();
    config.set_max_skew_shift(MAX_SHIFT_TWO_PERCENT);
    config.set_skew_depth_lots(DEPTH_LOTS);
    config
}

/// A config at the hard ceiling of the shift envelope, for the no-clamp tests.
fun ceiling_config(): strike_exposure_config::StrikeExposureConfig {
    let mut config = strike_exposure_config::new();
    config.set_max_skew_shift(config_constants::max_max_skew_shift!());
    config.set_skew_depth_lots(DEPTH_LOTS);
    config
}

/// The pool is net SHORT UP by `lots` (traders bought UP): aggregate negative.
fun short_up(lots: u64): i64::I64 {
    i64::from_parts(lots, true)
}

/// The pool is net LONG UP by `lots`: aggregate positive.
fun long_up(lots: u64): i64::I64 {
    i64::from_u64(lots)
}

#[test]
fun at_the_money_short_inventory_adds_the_full_shift() {
    let config = skewed_config();
    assert_eq!(config.skewed_up_price(P_AT_THE_MONEY, &short_up(DEPTH_LOTS)), ATM_FULL_SHORT);
    destroy(config);
}

#[test]
fun at_the_money_long_inventory_subtracts_the_full_shift() {
    let config = skewed_config();
    assert_eq!(config.skewed_up_price(P_AT_THE_MONEY, &long_up(DEPTH_LOTS)), ATM_FULL_LONG);
    destroy(config);
}

/// The shift is linear in inventory up to the depth.
#[test]
fun half_depth_moves_half_the_shift() {
    let config = skewed_config();
    assert_eq!(
        config.skewed_up_price(P_AT_THE_MONEY, &short_up(HALF_DEPTH_LOTS)),
        ATM_HALF_DEPTH_SHORT,
    );
    destroy(config);
}

/// Off the money the moneyness weight scales the shift down: a strike the oracle
/// prices at 0.25 moves by 0.75 of what an at-the-money strike moves.
#[test]
fun moneyness_weight_scales_the_shift_off_the_money() {
    let config = skewed_config();
    assert_eq!(config.skewed_up_price(P_QUARTER, &short_up(DEPTH_LOTS)), QUARTER_FULL_SHORT);
    destroy(config);
}

/// Inventory past the depth saturates: the shift never exceeds `max_skew_shift`.
#[test]
fun inventory_beyond_depth_saturates_at_the_configured_shift() {
    let config = skewed_config();
    assert_eq!(
        config.skewed_up_price(P_AT_THE_MONEY, &short_up(TEN_TIMES_DEPTH_LOTS)),
        ATM_FULL_SHORT,
    );
    destroy(config);
}

/// `P(-inf) = 1` is a constant, not a directional price. The moneyness weight
/// takes it to zero, so a one-sided range's infinity boundary never shifts —
/// this is what keeps `(-inf, K]` and `(K, +inf]` complementary under skew.
#[test]
fun negative_infinity_sentinel_is_inert() {
    let config = skewed_config();
    assert_eq!(
        config.skewed_up_price(P_NEGATIVE_INFINITY_SENTINEL, &short_up(DEPTH_LOTS)),
        P_NEGATIVE_INFINITY_SENTINEL,
    );
    destroy(config);
}

#[test]
fun positive_infinity_sentinel_is_inert() {
    let config = skewed_config();
    assert_eq!(
        config.skewed_up_price(P_POSITIVE_INFINITY_SENTINEL, &short_up(DEPTH_LOTS)),
        P_POSITIVE_INFINITY_SENTINEL,
    );
    destroy(config);
}

/// A flat book quotes the oracle's mark untouched.
#[test]
fun zero_inventory_quotes_the_fair_mark() {
    let config = skewed_config();
    assert_eq!(config.skewed_up_price(P_AT_THE_MONEY, &i64::zero()), P_AT_THE_MONEY);
    destroy(config);
}

/// The shipped default: markets quote fair until an admin snapshots a shift in.
#[test]
fun default_config_leaves_every_quote_at_the_fair_mark() {
    let config = strike_exposure_config::new();
    assert_eq!(config.max_skew_shift(), 0);
    assert_eq!(config.skewed_up_price(P_AT_THE_MONEY, &short_up(DEPTH_LOTS)), P_AT_THE_MONEY);
    destroy(config);
}

/// At the hard ceiling of the shift envelope, a deep out-of-the-money strike
/// under maximum opposing inventory still prices strictly above zero. This is
/// the property that lets `skewed_up_price` omit a saturating clamp; raising
/// `max_max_skew_shift` breaks it.
#[test]
fun ceiling_shift_stays_above_zero_at_the_low_tail() {
    let config = ceiling_config();
    assert_eq!(
        config.skewed_up_price(P_ONE_PERCENT, &long_up(DEPTH_LOTS)),
        ONE_PERCENT_FULL_LONG_AT_CEILING,
    );
    destroy(config);
}

/// The mirror bound: a near-certain strike stays strictly below 1.
#[test]
fun ceiling_shift_stays_below_one_at_the_high_tail() {
    let config = ceiling_config();
    assert_eq!(
        config.skewed_up_price(P_NINETY_NINE_PERCENT, &short_up(DEPTH_LOTS)),
        NINETY_NINE_PERCENT_FULL_SHORT_AT_CEILING,
    );
    destroy(config);
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxSkewShift)]
fun max_skew_shift_above_ceiling_aborts() {
    let mut config = strike_exposure_config::new();
    config.set_max_skew_shift(config_constants::max_max_skew_shift!() + 1);
    abort 1337
}

#[test, expected_failure(abort_code = config_constants::EInvalidSkewDepthLots)]
fun zero_skew_depth_aborts() {
    let mut config = strike_exposure_config::new();
    config.set_skew_depth_lots(0);
    abort 1337
}

#[test, expected_failure(abort_code = config_constants::EInvalidSkewDepthLots)]
fun skew_depth_above_ceiling_aborts() {
    let mut config = strike_exposure_config::new();
    config.set_skew_depth_lots(config_constants::max_skew_depth_lots!() + 1);
    abort 1337
}
