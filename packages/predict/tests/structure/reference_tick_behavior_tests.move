// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Exact-history reference-tick projection and idempotence.
#[test_only]
module deepbook_predict::scope_structure__intent_behavior__reference_tick_tests;

use deepbook_predict::{market_setup, oracle_setup, test_values, test_world};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

const REFERENCE_SPOT_WITH_DUST: u64 = 101_123_456_789;
const EXPECTED_REFERENCE_TICK: u64 = 101;

#[test]
fun set_reference_tick_floors_spot_and_is_idempotent() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_default_cadence(&world, &predict_admin_cap);
    test_world::return_predict_admin_cap(&world, predict_admin_cap);
    let oracles = oracle_setup::create_default_oracles(&mut world);

    test_world::next_tx(&mut world, test_values::admin());
    let propbook_admin_cap = test_world::take_propbook_admin_cap(&world);
    oracle_setup::bind_default_oracles(&world, &propbook_admin_cap, &oracles);
    test_world::return_propbook_admin_cap(&world, propbook_admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    let market_handle = market_setup::create_default_market(
        &mut world,
        &resources,
        &predict_admin_cap,
    );
    test_world::return_predict_admin_cap(&world, predict_admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let mut market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = oracle_setup::take_pyth(&world, &oracles);
    let source_timestamp_ms = market.reference_tick_source_timestamp_ms();
    oracle_setup::seed_exact_pyth(
        &mut pyth,
        REFERENCE_SPOT_WITH_DUST,
        source_timestamp_ms,
        test_values::now_ms(),
    );

    let first = market.set_reference_tick(
        &config,
        &oracle_registry,
        &pyth,
        test_world::clock(&resources),
    );
    let second = market.set_reference_tick(
        &config,
        &oracle_registry,
        &pyth,
        test_world::clock(&resources),
    );

    assert_eq!(source_timestamp_ms, test_values::now_ms());
    assert_eq!(first, EXPECTED_REFERENCE_TICK);
    assert_eq!(second, EXPECTED_REFERENCE_TICK);
    assert_eq!(market.reference_tick().destroy_some(), EXPECTED_REFERENCE_TICK);

    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(market);
    test_world::finish(world, resources);
}
