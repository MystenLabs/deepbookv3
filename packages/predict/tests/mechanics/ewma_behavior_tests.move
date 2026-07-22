// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Observable gas-price EWMA state transitions and penalty behavior.
#[test_only]
module deepbook_predict::scope_mechanics__intent_behavior__ewma_tests;

use deepbook_predict::{
    config_constants,
    ewma,
    ewma_config::{Self, EwmaConfig},
    test_values,
    test_world
};
use std::unit_test::{assert_eq, destroy};

const SEED_GAS: u64 = 1_000;
const FIRST_GAS: u64 = 2_000;
const SECOND_GAS: u64 = 3_000;
const EXTREME_GAS: u64 = 100_000;
const QUANTITY: u64 = 1_000_000_000;
const EXPECTED_PENALTY: u64 = 1_000_000;

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

#[test]
fun zero_variance_suppresses_every_penalty() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    let config = config_with(config_constants::min_ewma_z_score_threshold!(), true);

    test_world::next_tx_with_gas_price(&mut world, test_values::admin(), SEED_GAS);
    let state = ewma::new(test_world::ctx(&mut world));

    test_world::next_tx_with_gas_price(&mut world, test_values::admin(), EXTREME_GAS);
    assert_eq!(state.penalty_fee(&config, QUANTITY, test_world::ctx(&mut world)), 0);

    destroy(config);
    test_world::finish(world, resources);
}

#[test]
fun extreme_first_observation_suppresses_penalty_for_later_trades() {
    let (mut world, mut resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    let config = config_with(config_constants::min_ewma_z_score_threshold!(), true);

    test_world::next_tx_with_gas_price(&mut world, test_values::admin(), SEED_GAS);
    let mut state = ewma::new(test_world::ctx(&mut world));

    test_world::next_tx_with_gas_price(&mut world, test_values::admin(), EXTREME_GAS);
    assert_eq!(state.penalty_fee(&config, QUANTITY, test_world::ctx(&mut world)), 0);
    test_world::clock_mut(&mut resources).set_for_testing(test_values::now_ms() + 1);
    state.update(
        &config,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );

    test_world::next_tx_with_gas_price(&mut world, test_values::admin(), SECOND_GAS);
    assert_eq!(state.penalty_fee(&config, QUANTITY, test_world::ctx(&mut world)), 0);
    test_world::clock_mut(&mut resources).set_for_testing(test_values::now_ms() + 2);
    state.update(
        &config,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(state.penalty_fee(&config, QUANTITY, test_world::ctx(&mut world)), 0);

    destroy(config);
    test_world::finish(world, resources);
}

#[test]
fun penalty_fires_only_above_the_configured_z_score() {
    let (mut world, mut resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    let mut config = config_with(config_constants::min_ewma_z_score_threshold!(), true);

    test_world::next_tx_with_gas_price(&mut world, test_values::admin(), SEED_GAS);
    let mut state = ewma::new(test_world::ctx(&mut world));
    test_world::next_tx_with_gas_price(&mut world, test_values::admin(), FIRST_GAS);
    test_world::clock_mut(&mut resources).set_for_testing(test_values::now_ms() + 1);
    state.update(
        &config,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    test_world::next_tx_with_gas_price(&mut world, test_values::admin(), SECOND_GAS);
    test_world::clock_mut(&mut resources).set_for_testing(test_values::now_ms() + 2);
    state.update(
        &config,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );

    assert_eq!(state.penalty_fee(&config, QUANTITY, test_world::ctx(&mut world)), EXPECTED_PENALTY);
    config.set_params(
        config_constants::default_ewma_alpha!(),
        config_constants::default_ewma_z_score_threshold!(),
        config_constants::default_ewma_penalty_rate!(),
    );
    assert_eq!(state.penalty_fee(&config, QUANTITY, test_world::ctx(&mut world)), 0);

    destroy(config);
    test_world::finish(world, resources);
}

#[test]
fun same_millisecond_update_is_ignored() {
    let (mut world, mut resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    let config = config_with(config_constants::min_ewma_z_score_threshold!(), true);

    test_world::next_tx_with_gas_price(&mut world, test_values::admin(), SEED_GAS);
    let mut state = ewma::new(test_world::ctx(&mut world));
    test_world::next_tx_with_gas_price(&mut world, test_values::admin(), FIRST_GAS);
    test_world::clock_mut(&mut resources).set_for_testing(test_values::now_ms() + 1);
    state.update(
        &config,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );

    test_world::next_tx_with_gas_price(&mut world, test_values::admin(), 1_000_000);
    state.update(
        &config,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );

    test_world::next_tx_with_gas_price(&mut world, test_values::admin(), SECOND_GAS);
    test_world::clock_mut(&mut resources).set_for_testing(test_values::now_ms() + 2);
    state.update(
        &config,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert_eq!(state.penalty_fee(&config, QUANTITY, test_world::ctx(&mut world)), EXPECTED_PENALTY);

    destroy(config);
    test_world::finish(world, resources);
}

#[test]
fun disabled_and_below_mean_states_do_not_penalize() {
    let (mut world, mut resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    let mut config = config_with(config_constants::min_ewma_z_score_threshold!(), true);

    test_world::next_tx_with_gas_price(&mut world, test_values::admin(), SEED_GAS);
    let mut state = ewma::new(test_world::ctx(&mut world));
    test_world::next_tx_with_gas_price(&mut world, test_values::admin(), FIRST_GAS);
    test_world::clock_mut(&mut resources).set_for_testing(test_values::now_ms() + 1);
    state.update(
        &config,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );

    test_world::next_tx_with_gas_price(&mut world, test_values::admin(), 500);
    assert_eq!(state.penalty_fee(&config, QUANTITY, test_world::ctx(&mut world)), 0);
    test_world::next_tx_with_gas_price(&mut world, test_values::admin(), SECOND_GAS);
    config.set_enabled(false);
    assert_eq!(state.penalty_fee(&config, QUANTITY, test_world::ctx(&mut world)), 0);

    destroy(config);
    test_world::finish(world, resources);
}
