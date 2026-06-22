// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Behavioral coverage for the gas-price EWMA penalty. The smoothed mean and
/// variance are internal, so every assertion is made through the observable
/// `penalty_fee` output by driving the per-transaction gas price and bracketing
/// the z-score with the penalty threshold. The gas sequence 1000 -> 2000 -> 3000
/// is the same one DeepBook core's ewma_tests use; its z-scores (~0.99 sigma
/// after the first observation, ~1.94 sigma after the second) are derived there.
#[test_only]
module deepbook_predict::ewma_tests;

use deepbook_predict::{config_constants, ewma::{Self, EwmaState}, ewma_config::{Self, EwmaConfig}};
use std::unit_test::{assert_eq, destroy};
use sui::{clock::{Self, Clock}, test_scenario::{begin, end, Scenario}};

const QUANTITY: u64 = 1_000_000_000; // 1.0 contract unit in 1e9 scaling
// default penalty_rate is 0.1%; 0.1% of 1.0 = 0.001 = 1_000_000 base units.
const EXPECTED_PENALTY: u64 = 1_000_000;

fun advance_with_gas(test: &mut Scenario, gas_price: u64, timestamp_advance: u64) {
    let ts = test.ctx().epoch_timestamp_ms() + timestamp_advance;
    let ctx = test.ctx_builder().set_gas_price(gas_price).set_epoch_timestamp(ts);
    test.next_with_context(ctx);
}

fun config_with(threshold: u64, enabled: bool): EwmaConfig {
    let mut config = ewma_config::new();
    config.set_params(
        config_constants::default_ewma_alpha!(),
        threshold,
        config_constants::default_ewma_penalty_rate!(),
    );
    config.set_enabled(enabled);
    config
}

/// Seed at gas 1000 then fold in 2000 (ms 1000) and 3000 (ms 2000). The current
/// transaction gas is left at 3000, where the z-score is ~1.94 sigma.
fun seeded_state(test: &mut Scenario, clock: &mut Clock, config: &EwmaConfig): EwmaState {
    advance_with_gas(test, 1_000, 0);
    let mut state = ewma::new(test.ctx());

    advance_with_gas(test, 2_000, 1_000);
    clock.set_for_testing(1_000);
    state.update(config, clock, test.ctx());

    advance_with_gas(test, 3_000, 1_000);
    clock.set_for_testing(2_000);
    state.update(config, clock, test.ctx());
    state
}

#[test]
fun fresh_state_with_zero_variance_never_penalizes() {
    let mut test = begin(@0xF);
    let config = config_with(config_constants::min_ewma_z_score_threshold!(), true);
    advance_with_gas(&mut test, 1_000, 0);
    let state = ewma::new(test.ctx());

    // Gas far above the seed mean, but variance is still zero, so there is no
    // dispersion to measure against.
    advance_with_gas(&mut test, 100_000, 1_000);
    assert_eq!(state.penalty_fee(&config, QUANTITY, test.ctx()), 0);

    destroy(state);
    destroy(config);
    end(test);
}

#[test]
fun first_observation_does_not_penalize_at_min_threshold() {
    let mut test = begin(@0xF);
    let config = config_with(config_constants::min_ewma_z_score_threshold!(), true);
    let mut clock = clock::create_for_testing(test.ctx());

    advance_with_gas(&mut test, 1_000, 0);
    let mut state = ewma::new(test.ctx());
    advance_with_gas(&mut test, 2_000, 1_000);
    clock.set_for_testing(1_000);
    state.update(&config, &clock, test.ctx());

    // z = (2000 - 1010) / sqrt(1_000_000) = 0.99 sigma, below the 1-sigma floor,
    // so the very first observation cannot trip even the tightest threshold.
    assert_eq!(state.penalty_fee(&config, QUANTITY, test.ctx()), 0);

    destroy(state);
    destroy(config);
    destroy(clock);
    end(test);
}

#[test]
fun penalty_fires_once_z_score_crosses_threshold() {
    let mut test = begin(@0xF);
    let mut config = config_with(config_constants::min_ewma_z_score_threshold!(), true);
    let mut clock = clock::create_for_testing(test.ctx());
    let state = seeded_state(&mut test, &mut clock, &config);

    // z ~= 1.94 sigma at gas 3000: above 1 sigma fires the flat surcharge...
    assert_eq!(state.penalty_fee(&config, QUANTITY, test.ctx()), EXPECTED_PENALTY);

    // ...but below the default 3-sigma threshold it does not.
    config.set_params(
        config_constants::default_ewma_alpha!(),
        config_constants::default_ewma_z_score_threshold!(),
        config_constants::default_ewma_penalty_rate!(),
    );
    assert_eq!(state.penalty_fee(&config, QUANTITY, test.ctx()), 0);

    destroy(state);
    destroy(config);
    destroy(clock);
    end(test);
}

#[test]
fun extreme_first_observation_suppresses_penalty_for_later_trades() {
    let mut test = begin(@0xF);
    let config = config_with(config_constants::min_ewma_z_score_threshold!(), true);
    let mut clock = clock::create_for_testing(test.ctx());

    // Market created at gas 1000: mean seeds at 1000, variance at 0.
    advance_with_gas(&mut test, 1_000, 0);
    let mut state = ewma::new(test.ctx());

    // First post-creation trade at an extreme (trader-chosen) gas price. The
    // first observation seeds the variance directly with diff^2 (alpha 0.01):
    //   mean     = 0.01 * 100_000 + 0.99 * 1_000  = 1_990
    //   variance = (100_000 - 1_000)^2            = 9_801_000_000
    //   std_dev  = sqrt(9_801_000_000)            = 99_000
    advance_with_gas(&mut test, 100_000, 1_000);
    clock.set_for_testing(1_000);
    state.update(&config, &clock, test.ctx());

    // The poisoning trade itself pays nothing:
    //   z = (100_000 - 1_990) / 99_000 = 0.99 sigma exactly, below even the
    //   tightest 1-sigma threshold.
    assert_eq!(state.penalty_fee(&config, QUANTITY, test.ctx()), 0);

    // A later gas-3000 trade, folded in first as the market trade path does:
    //   mean     = 0.01 * 3_000 + 0.99 * 1_990                  = 2_000.1
    //   variance = 0.99 * 9_801_000_000 + 0.01 * (3_000 - 1_990)^2
    //            = 9_702_990_000 + 10_201                       = 9_703_000_201
    //   z = (3_000 - 2_000.1) / sqrt(9_703_000_201) ~= 999.9 / 98_504
    //     ~= 0.0102 sigma -> suppressed.
    // The identical gas-3000 trade on the clean 1000 -> 2000 -> 3000 path fires
    // EXPECTED_PENALTY at this same 1-sigma threshold
    // (penalty_fires_once_z_score_crosses_threshold).
    advance_with_gas(&mut test, 3_000, 1_000);
    clock.set_for_testing(2_000);
    state.update(&config, &clock, test.ctx());
    assert_eq!(state.penalty_fee(&config, QUANTITY, test.ctx()), 0);

    destroy(state);
    destroy(config);
    destroy(clock);
    end(test);
}

#[test]
fun disabled_config_never_penalizes() {
    let mut test = begin(@0xF);
    let config = config_with(config_constants::min_ewma_z_score_threshold!(), false);
    let mut clock = clock::create_for_testing(test.ctx());
    let state = seeded_state(&mut test, &mut clock, &config);

    // Same firing state as the previous test, but the master switch is off.
    assert_eq!(state.penalty_fee(&config, QUANTITY, test.ctx()), 0);

    destroy(state);
    destroy(config);
    destroy(clock);
    end(test);
}

#[test]
fun gas_at_or_below_mean_never_penalizes() {
    let mut test = begin(@0xF);
    let config = config_with(config_constants::min_ewma_z_score_threshold!(), true);
    let mut clock = clock::create_for_testing(test.ctx());
    let state = seeded_state(&mut test, &mut clock, &config);

    // Mean is ~1029.9; observe a low gas price without folding it in. A penalty
    // only applies above the mean.
    advance_with_gas(&mut test, 500, 1_000);
    assert_eq!(state.penalty_fee(&config, QUANTITY, test.ctx()), 0);

    destroy(state);
    destroy(config);
    destroy(clock);
    end(test);
}

#[test]
fun same_millisecond_update_is_skipped() {
    let mut test = begin(@0xF);
    let config = config_with(config_constants::min_ewma_z_score_threshold!(), true);
    let mut clock = clock::create_for_testing(test.ctx());

    advance_with_gas(&mut test, 1_000, 0);
    let mut state = ewma::new(test.ctx());

    advance_with_gas(&mut test, 2_000, 1_000);
    clock.set_for_testing(1_000);
    state.update(&config, &clock, test.ctx());

    // A second observation in the same millisecond, at a wild gas price, must be
    // ignored. If it were folded in, the mean would jump well above 3000 and the
    // next observation would land below the mean, yielding no penalty.
    advance_with_gas(&mut test, 1_000_000, 0);
    state.update(&config, &clock, test.ctx());

    advance_with_gas(&mut test, 3_000, 1_000);
    clock.set_for_testing(2_000);
    state.update(&config, &clock, test.ctx());

    // Identical to the clean 1000 -> 2000 -> 3000 path: z ~= 1.94 sigma fires.
    assert_eq!(state.penalty_fee(&config, QUANTITY, test.ctx()), EXPECTED_PENALTY);

    destroy(state);
    destroy(config);
    destroy(clock);
    end(test);
}
