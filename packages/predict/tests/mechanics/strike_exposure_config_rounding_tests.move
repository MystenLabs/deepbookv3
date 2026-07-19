// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Bernoulli fee, quantity floor, and expiry-ramp rounding.
#[test_only]
module deepbook_predict::mechanics_strike_exposure_config_rounding_tests;

use deepbook_predict::strike_exposure_config;
use std::unit_test::{assert_eq, destroy};

const EXPIRY_MS: u64 = 100_000_000;
const HALF_PROBABILITY: u64 = 500_000_000;
const QUANTITY: u64 = 1_000_000_000;
const HALF_PROBABILITY_FEE: u64 = 10_000_000;
const QUARTER_PROBABILITY: u64 = 250_000_000;
const THREE_QUARTER_PROBABILITY: u64 = 750_000_000;
const QUARTER_PROBABILITY_FEE: u64 = 8_660_254;
const MINIMUM_FEE_LAST_ZERO_QUANTITY: u64 = 199;
const MINIMUM_FEE_FIRST_POSITIVE_QUANTITY: u64 = 200;
const DEFAULT_MINIMUM_FEE: u64 = 5_000_000;
const RAMP_EXPIRY_MS: u64 = 1_000_000;
const RAMP_WINDOW_MS: u64 = 300_000;
const RAMP_MIDPOINT_MS: u64 = 150_000;
const TWO_X_MULTIPLIER: u64 = 2_000_000_000;
const MIDPOINT_FEE: u64 = 7_500_000;
const LAST_MILLISECOND_FEE: u64 = 9_999_983;
const ZERO_PROBABILITY: u64 = 0;
const ZERO_TIMESTAMP_MS: u64 = 0;
const ZERO_FEE: u64 = 0;
const ONE_FEE_UNIT: u64 = 1;
const ONE_MILLISECOND: u64 = 1;

#[test]
fun half_probability_has_exact_ten_million_fee_rate() {
    let config = strike_exposure_config::new();
    // sqrt(0.5 * 0.5) = 0.5; default 0.02 base fee times 0.5 = 0.01.
    assert_eq!(
        config.trading_fee(EXPIRY_MS, HALF_PROBABILITY, QUANTITY, ZERO_TIMESTAMP_MS),
        HALF_PROBABILITY_FEE,
    );
    destroy(config);
}

#[test]
fun complementary_probabilities_charge_the_same_fee() {
    let config = strike_exposure_config::new();
    // floor(1e9 * 0.02 * sqrt(0.25 * 0.75)) = 8_660_254.
    assert_eq!(
        config.trading_fee(EXPIRY_MS, QUARTER_PROBABILITY, QUANTITY, ZERO_TIMESTAMP_MS),
        QUARTER_PROBABILITY_FEE,
    );
    assert_eq!(
        config.trading_fee(
            EXPIRY_MS,
            THREE_QUARTER_PROBABILITY,
            QUANTITY,
            ZERO_TIMESTAMP_MS,
        ),
        QUARTER_PROBABILITY_FEE,
    );
    destroy(config);
}

#[test]
fun minimum_fee_quantity_boundary_is_last_zero_then_first_positive() {
    let config = strike_exposure_config::new();
    // The default minimum rate is 0.005, so floor(quantity * 0.005) changes at 200.
    assert_eq!(
        config.trading_fee(
            EXPIRY_MS,
            ZERO_PROBABILITY,
            MINIMUM_FEE_LAST_ZERO_QUANTITY,
            ZERO_TIMESTAMP_MS,
        ),
        ZERO_FEE,
    );
    assert_eq!(
        config.trading_fee(
            EXPIRY_MS,
            ZERO_PROBABILITY,
            MINIMUM_FEE_FIRST_POSITIVE_QUANTITY,
            ZERO_TIMESTAMP_MS,
        ),
        ONE_FEE_UNIT,
    );
    assert_eq!(
        config.trading_fee(EXPIRY_MS, QUANTITY, QUANTITY, ZERO_TIMESTAMP_MS),
        DEFAULT_MINIMUM_FEE,
    );
    destroy(config);
}

#[test]
fun expiry_ramp_is_one_x_at_window_and_one_point_five_x_at_midpoint() {
    let mut config = strike_exposure_config::new();
    config.set_expiry_fee_window_ms(RAMP_WINDOW_MS);
    config.set_expiry_fee_max_multiplier(TWO_X_MULTIPLIER);
    assert_eq!(
        config.trading_fee(
            RAMP_EXPIRY_MS,
            ZERO_PROBABILITY,
            QUANTITY,
            RAMP_EXPIRY_MS - RAMP_WINDOW_MS,
        ),
        DEFAULT_MINIMUM_FEE,
    );
    assert_eq!(
        config.trading_fee(
            RAMP_EXPIRY_MS,
            ZERO_PROBABILITY,
            QUANTITY,
            RAMP_EXPIRY_MS - RAMP_MIDPOINT_MS,
        ),
        MIDPOINT_FEE,
    );
    assert_eq!(
        config.trading_fee(
            RAMP_EXPIRY_MS,
            ZERO_PROBABILITY,
            QUANTITY,
            RAMP_EXPIRY_MS - ONE_MILLISECOND,
        ),
        LAST_MILLISECOND_FEE,
    );
    destroy(config);
}
