// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Exact mint-admission probability, leverage, and term policy.
#[test_only]
module deepbook_predict::mechanics_strike_exposure_config_policy_tests;

use deepbook_predict::{config_constants, strike_exposure_config};
use std::unit_test::{assert_eq, destroy};

const ONE_X_LEVERAGE: u64 = 1_000_000_000;
const HALF_PROBABILITY: u64 = 500_000_000;
const QUANTITY: u64 = 1_000_000_000;
const DEFAULT_HALF_PROBABILITY_CAP: u64 = 2_714_285_714;
const TWO_POINT_FIVE_X_LEVERAGE: u64 = 2_500_000_000;
const TWO_POINT_FIVE_X_NET_PREMIUM: u64 = 200_000_000;
const TWO_POINT_FIVE_X_FLOOR_SHARES: u64 = 300_000_000;
const MINIMUM_PREMIUM_QUANTITY: u64 = 2_000_000;
const MINIMUM_PROBABILITY_NET_PREMIUM: u64 = 10_000_000;
const MAXIMUM_PROBABILITY_NET_PREMIUM: u64 = 990_000_000;
const HALF_CAP_NET_PREMIUM: u64 = 184_210_526;
const HALF_CAP_FLOOR_SHARES: u64 = 315_789_474;
const MINIMUM_NET_PREMIUM: u64 = 1_000_000;
const ZERO_FLOOR_SHARES: u64 = 0;
const DISABLED_WINDOW_MS: u64 = 0;
const ONE_MILLISECOND: u64 = 1;
const HALF_PROBABILITY_NET_PREMIUM: u64 = 500_000_000;
const ONE_ABOVE_LIQUIDATION_PROBABILITY: u64 = 500_000_001;
const ONE_ABOVE_LIQUIDATION_LEVERAGE: u64 = 1_999_999_996;
const ONE_ABOVE_LIQUIDATION_NET_PREMIUM: u64 = 250_000_001;
const ONE_ABOVE_LIQUIDATION_FLOOR_SHARES: u64 = 250_000_000;

#[test]
fun probability_endpoints_and_exact_derived_cap_are_admitted() {
    let config = strike_exposure_config::new();
    let minimum = config.assert_mint_admission(
        config_constants::default_min_entry_probability!(),
        QUANTITY,
        ONE_X_LEVERAGE,
        config_constants::default_no_leverage_window_ms!(),
    );
    assert_eq!(minimum.net_premium(), MINIMUM_PROBABILITY_NET_PREMIUM);
    assert_eq!(minimum.floor_shares(), ZERO_FLOOR_SHARES);
    let maximum = config.assert_mint_admission(
        config_constants::default_max_entry_probability!(),
        QUANTITY,
        ONE_X_LEVERAGE,
        config_constants::default_no_leverage_window_ms!(),
    );
    assert_eq!(maximum.net_premium(), MAXIMUM_PROBABILITY_NET_PREMIUM);
    assert_eq!(maximum.floor_shares(), ZERO_FLOOR_SHARES);
    let capped = config.assert_mint_admission(
        HALF_PROBABILITY,
        QUANTITY,
        DEFAULT_HALF_PROBABILITY_CAP,
        config_constants::default_no_leverage_window_ms!(),
    );
    assert_eq!(capped.net_premium(), HALF_CAP_NET_PREMIUM);
    assert_eq!(capped.floor_shares(), HALF_CAP_FLOOR_SHARES);
    destroy(config);
}

#[test]
fun no_leverage_window_boundary_and_zero_disable_are_exact() {
    let mut config = strike_exposure_config::new();
    let window = config_constants::default_no_leverage_window_ms!();
    let inside = config.assert_mint_admission(
        HALF_PROBABILITY,
        QUANTITY,
        ONE_X_LEVERAGE,
        window - ONE_MILLISECOND,
    );
    assert_eq!(inside.net_premium(), HALF_PROBABILITY_NET_PREMIUM);
    assert_eq!(inside.floor_shares(), ZERO_FLOOR_SHARES);
    let boundary = config.assert_mint_admission(
        HALF_PROBABILITY,
        QUANTITY,
        DEFAULT_HALF_PROBABILITY_CAP,
        window,
    );
    assert_eq!(boundary.net_premium(), HALF_CAP_NET_PREMIUM);
    assert_eq!(boundary.floor_shares(), HALF_CAP_FLOOR_SHARES);
    config.set_no_leverage_window_ms(DISABLED_WINDOW_MS);
    let disabled = config.assert_mint_admission(
        HALF_PROBABILITY,
        QUANTITY,
        DEFAULT_HALF_PROBABILITY_CAP,
        DISABLED_WINDOW_MS,
    );
    assert_eq!(disabled.net_premium(), HALF_CAP_NET_PREMIUM);
    assert_eq!(disabled.floor_shares(), HALF_CAP_FLOOR_SHARES);
    destroy(config);
}

#[test]
fun admission_returns_independently_derived_premium_and_floor() {
    let config = strike_exposure_config::new();
    // entry = 0.5 * 1e9 = 500m; 2.5x premium = 200m; floor = 300m.
    let admission = config.assert_mint_admission(
        HALF_PROBABILITY,
        QUANTITY,
        TWO_POINT_FIVE_X_LEVERAGE,
        config_constants::default_no_leverage_window_ms!(),
    );
    assert_eq!(admission.net_premium(), TWO_POINT_FIVE_X_NET_PREMIUM);
    assert_eq!(admission.floor_shares(), TWO_POINT_FIVE_X_FLOOR_SHARES);
    destroy(config);
}

#[test]
fun net_premium_exact_minimum_is_admitted() {
    let config = strike_exposure_config::new();
    let admission = config.assert_mint_admission(
        HALF_PROBABILITY,
        MINIMUM_PREMIUM_QUANTITY,
        ONE_X_LEVERAGE,
        config_constants::default_no_leverage_window_ms!(),
    );
    assert_eq!(admission.net_premium(), MINIMUM_NET_PREMIUM);
    assert_eq!(admission.floor_shares(), ZERO_FLOOR_SHARES);
    destroy(config);
}

#[test]
fun liquidation_threshold_one_unit_above_is_admitted() {
    let mut config = strike_exposure_config::new();
    config.set_liquidation_ltv(config_constants::min_liquidation_ltv!());
    // Entry is 500,000,001 while floor / 0.5 is 500,000,000.
    let admission = config.assert_mint_admission(
        ONE_ABOVE_LIQUIDATION_PROBABILITY,
        QUANTITY,
        ONE_ABOVE_LIQUIDATION_LEVERAGE,
        config_constants::default_no_leverage_window_ms!(),
    );
    assert_eq!(admission.net_premium(), ONE_ABOVE_LIQUIDATION_NET_PREMIUM);
    assert_eq!(admission.floor_shares(), ONE_ABOVE_LIQUIDATION_FLOOR_SHARES);
    destroy(config);
}
