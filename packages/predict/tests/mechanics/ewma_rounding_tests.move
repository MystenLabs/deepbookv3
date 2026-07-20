// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// First-positive rounding for the observable EWMA penalty fee.
#[test_only]
module deepbook_predict::scope_mechanics__intent_rounding__ewma_tests;

use deepbook_predict::{config_constants, ewma, ewma_config, test_values, test_world};
use std::unit_test::{assert_eq, destroy};

#[test]
fun penalty_fee_rounds_at_the_first_positive_quantity() {
    let (mut world, mut resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    let mut config = ewma_config::new();
    config.set_params(
        config_constants::default_ewma_alpha!(),
        config_constants::min_ewma_z_score_threshold!(),
        config_constants::default_ewma_penalty_rate!(),
    );
    config.set_enabled(true);

    test_world::next_tx_with_gas_price(&mut world, test_values::admin(), 1_000);
    let mut state = ewma::new(test_world::ctx(&mut world));
    test_world::next_tx_with_gas_price(&mut world, test_values::admin(), 2_000);
    test_world::clock_mut(&mut resources).set_for_testing(test_values::now_ms() + 1);
    state.update(
        &config,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    test_world::next_tx_with_gas_price(&mut world, test_values::admin(), 3_000);
    test_world::clock_mut(&mut resources).set_for_testing(test_values::now_ms() + 2);
    state.update(
        &config,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );

    assert_eq!(state.penalty_fee(&config, 999, test_world::ctx(&mut world)), 0);
    assert_eq!(state.penalty_fee(&config, 1_000, test_world::ctx(&mut world)), 1);

    destroy(config);
    test_world::finish(world, resources);
}
