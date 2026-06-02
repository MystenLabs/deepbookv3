// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for the gas-price EWMA penalty math. Expected mean, variance,
/// and z-score crossings are derived by hand in comments (all values in 1e9
/// scaling), independent of the contract implementation.
#[test_only]
module deepbook_predict::ewma_tests;

use deepbook_predict::{
    config_constants,
    constants::float_scaling as float,
    ewma,
    ewma_config::{Self, EwmaConfig}
};
use std::unit_test::{assert_eq, destroy};
use sui::{clock, test_scenario::{begin, end, Scenario}};

const QUANTITY: u64 = 1_000_000_000; // 1.0 contract unit in 1e9 scaling
const ADDITIONAL_FEE: u64 = 1_000_000; // 0.1% surcharge rate
// 0.1% of 1.0 = 0.001 = 1_000_000 base units. Independent of the contract.
const EXPECTED_PENALTY: u64 = 1_000_000;
const ONE_SIGMA: u64 = 1_000_000_000; // float!() == 1 standard deviation
const THREE_SIGMA: u64 = 3_000_000_000;

// Seed gas 1000 -> first observation 2000:
//   mean'     = 0.01*2000 + 0.99*1000 = 1010
//   variance' = (2000 - 1000)^2 = 1_000_000   (seeded from the first deviation)
const MEAN_AFTER_FIRST: u64 = 1_010_000_000_000; // 1010 * 1e9
const VARIANCE_AFTER_FIRST: u64 = 1_000_000_000_000_000; // 1_000_000 * 1e9

// Second observation 3000:
//   mean'     = 0.01*3000 + 0.99*1010 = 1029.9
//   variance' = 0.99*1_000_000 + 0.01*(3000 - 1010)^2 = 990_000 + 39_601 = 1_029_601
const MEAN_AFTER_SECOND: u64 = 1_029_900_000_000; // 1029.9 * 1e9
const VARIANCE_AFTER_SECOND: u64 = 1_029_601_000_000_000; // 1_029_601 * 1e9

fun advance_with_gas(test: &mut Scenario, gas_price: u64, timestamp_advance: u64) {
    let ts = test.ctx().epoch_timestamp_ms() + timestamp_advance;
    let ctx = test.ctx_builder().set_gas_price(gas_price).set_epoch_timestamp(ts);
    test.next_with_context(ctx);
}

fun config_with(threshold: u64, enabled: bool): EwmaConfig {
    let mut config = ewma_config::new();
    config.set_params(config_constants::default_ewma_alpha!(), threshold, ADDITIONAL_FEE);
    config.set_enabled(enabled);
    config
}

#[test]
fun new_seeds_mean_from_gas_price() {
    let mut test = begin(@0xF);
    advance_with_gas(&mut test, 1_000, 0);
    let state = ewma::new(test.ctx());

    assert_eq!(state.mean(), 1_000 * float!());
    assert_eq!(state.variance(), 0);
    assert_eq!(state.last_updated_timestamp_ms(), 0);

    destroy(state);
    end(test);
}

#[test]
fun first_update_seeds_variance_from_deviation() {
    let mut test = begin(@0xF);
    let config = config_with(ONE_SIGMA, true);
    advance_with_gas(&mut test, 1_000, 0);
    let mut state = ewma::new(test.ctx());
    let mut clock = clock::create_for_testing(test.ctx());

    advance_with_gas(&mut test, 2_000, 1_000);
    clock.set_for_testing(1_000);
    state.update(&config, &clock, test.ctx());

    assert_eq!(state.mean(), MEAN_AFTER_FIRST);
    assert_eq!(state.variance(), VARIANCE_AFTER_FIRST);
    // z = (2000 - 1010) / sqrt(1_000_000) = 990 / 1000 = 0.99 < 1 sigma, so no penalty
    // fires even at the minimum threshold.
    assert_eq!(state.penalty_fee(&config, QUANTITY, test.ctx()), 0);

    destroy(state);
    destroy(config);
    destroy(clock);
    end(test);
}

#[test]
fun update_is_noop_within_same_millisecond() {
    let mut test = begin(@0xF);
    let config = config_with(ONE_SIGMA, true);
    advance_with_gas(&mut test, 1_000, 0);
    let mut state = ewma::new(test.ctx());
    let mut clock = clock::create_for_testing(test.ctx());

    advance_with_gas(&mut test, 2_000, 1_000);
    clock.set_for_testing(1_000);
    state.update(&config, &clock, test.ctx());

    // A second observation at a wildly different gas price but the same clock ms
    // must not move the estimate.
    advance_with_gas(&mut test, 9_999, 0);
    state.update(&config, &clock, test.ctx());

    assert_eq!(state.mean(), MEAN_AFTER_FIRST);
    assert_eq!(state.variance(), VARIANCE_AFTER_FIRST);

    destroy(state);
    destroy(config);
    destroy(clock);
    end(test);
}

#[test]
fun penalty_fires_once_z_score_crosses_threshold() {
    let mut test = begin(@0xF);
    let mut config = config_with(ONE_SIGMA, true);
    advance_with_gas(&mut test, 1_000, 0);
    let mut state = ewma::new(test.ctx());
    let mut clock = clock::create_for_testing(test.ctx());

    advance_with_gas(&mut test, 2_000, 1_000);
    clock.set_for_testing(1_000);
    state.update(&config, &clock, test.ctx());

    advance_with_gas(&mut test, 3_000, 1_000);
    clock.set_for_testing(2_000);
    state.update(&config, &clock, test.ctx());

    assert_eq!(state.mean(), MEAN_AFTER_SECOND);
    assert_eq!(state.variance(), VARIANCE_AFTER_SECOND);

    // z = (3000 - 1029.9) / sqrt(1_029_601) ~= 1970.1 / 1014.69 ~= 1.94 sigma.
    // > 1 sigma -> penalty fires; < 3 sigma -> default threshold does not.
    assert_eq!(state.penalty_fee(&config, QUANTITY, test.ctx()), EXPECTED_PENALTY);

    config.set_params(config_constants::default_ewma_alpha!(), THREE_SIGMA, ADDITIONAL_FEE);
    assert_eq!(state.penalty_fee(&config, QUANTITY, test.ctx()), 0);

    destroy(state);
    destroy(config);
    destroy(clock);
    end(test);
}

#[test]
fun disabled_config_never_penalizes() {
    let mut test = begin(@0xF);
    let config = config_with(ONE_SIGMA, false);
    advance_with_gas(&mut test, 1_000, 0);
    let mut state = ewma::new(test.ctx());
    let mut clock = clock::create_for_testing(test.ctx());

    advance_with_gas(&mut test, 2_000, 1_000);
    clock.set_for_testing(1_000);
    state.update(&config, &clock, test.ctx());
    advance_with_gas(&mut test, 3_000, 1_000);
    clock.set_for_testing(2_000);
    state.update(&config, &clock, test.ctx());

    // Same firing state as the previous test, but the master switch is off.
    assert_eq!(state.penalty_fee(&config, QUANTITY, test.ctx()), 0);

    destroy(state);
    destroy(config);
    destroy(clock);
    end(test);
}

#[test]
fun fresh_state_with_zero_variance_never_penalizes() {
    let mut test = begin(@0xF);
    let config = config_with(ONE_SIGMA, true);
    advance_with_gas(&mut test, 1_000, 0);
    let state = ewma::new(test.ctx());

    // Gas far above the seed mean, but variance is still zero so there is no
    // dispersion to measure against.
    advance_with_gas(&mut test, 100_000, 1_000);
    assert_eq!(state.penalty_fee(&config, QUANTITY, test.ctx()), 0);

    destroy(state);
    destroy(config);
    end(test);
}

#[test]
fun gas_below_mean_never_penalizes() {
    let mut test = begin(@0xF);
    let config = config_with(ONE_SIGMA, true);
    advance_with_gas(&mut test, 1_000, 0);
    let mut state = ewma::new(test.ctx());
    let mut clock = clock::create_for_testing(test.ctx());

    advance_with_gas(&mut test, 2_000, 1_000);
    clock.set_for_testing(1_000);
    state.update(&config, &clock, test.ctx());
    advance_with_gas(&mut test, 3_000, 1_000);
    clock.set_for_testing(2_000);
    state.update(&config, &clock, test.ctx());

    // Mean is ~1029.9; observe a low gas price without folding it in. A penalty
    // only applies above the mean.
    advance_with_gas(&mut test, 10, 1_000);
    assert_eq!(state.penalty_fee(&config, QUANTITY, test.ctx()), 0);

    destroy(state);
    destroy(config);
    destroy(clock);
    end(test);
}
