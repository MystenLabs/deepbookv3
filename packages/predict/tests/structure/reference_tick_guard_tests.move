// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Exact-history and canonical-feed guards for reference ticks.
#[test_only]
module deepbook_predict::scope_structure__intent_guard__reference_tick_tests;

use deepbook_predict::{expiry_market, market_setup, oracle_setup, pricing, test_values, test_world};
use propbook::{pyth_feed::PythFeed, registry as propbook_registry};

const ROGUE_PYTH_SOURCE_ID: u32 = 2;
const EUnexpectedSuccess: u64 = 999;

#[test, expected_failure(abort_code = expiry_market::EReferenceTickObservationMissing)]
fun set_reference_tick_missing_exact_history_aborts() {
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
    oracle_setup::seed_pyth(
        &mut pyth,
        100_000_000_000,
        source_timestamp_ms - 2,
        test_values::now_ms(),
    );
    oracle_setup::seed_exact_pyth(
        &mut pyth,
        101_000_000_000,
        source_timestamp_ms - 1,
        test_values::now_ms(),
    );

    let _ = market.set_reference_tick(
        &config,
        &oracle_registry,
        &pyth,
        test_world::clock(&resources),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = pricing::EWrongPythFeed)]
fun set_reference_tick_wrong_pyth_feed_aborts() {
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
    let mut oracle_registry = test_world::take_oracle_registry(&world);
    let rogue_pyth_id = propbook_registry::create_and_share_pyth_feed(
        &mut oracle_registry,
        ROGUE_PYTH_SOURCE_ID,
        test_world::ctx(&mut world),
    );
    sui::test_scenario::return_shared(oracle_registry);

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
    let rogue_pyth = test_world::take_shared_by_id<PythFeed>(&world, rogue_pyth_id);

    let _ = market.set_reference_tick(
        &config,
        &oracle_registry,
        &rogue_pyth,
        test_world::clock(&resources),
    );
    abort EUnexpectedSuccess
}
