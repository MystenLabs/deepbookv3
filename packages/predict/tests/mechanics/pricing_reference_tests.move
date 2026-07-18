// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Production-pricer accuracy against independently generated true-model values
/// and ex-ante fixed-point error intervals.
#[test_only]
module deepbook_predict::mechanics_pricing_reference_tests;

use deepbook_predict::{
    market_setup,
    oracle_setup,
    pricing_reference_data as reference,
    range_codec::strike_for_testing as strike,
    test_values,
    test_world
};
use sui::test_scenario::return_shared;

#[test]
fun synthetic_profiles_stay_within_independent_precision_contract() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    market_setup::configure_default_cadence(&mut world, &resources);
    let oracles = oracle_setup::create_default_oracles(&mut world);

    test_world::next_tx(&mut world, test_values::admin());
    oracle_setup::bind_default_oracles(&world, &resources, &oracles);

    test_world::next_tx(&mut world, test_values::admin());
    let (market_handle, lifecycle_cap) = market_setup::create_default_market(
        &mut world,
        &resources,
    );

    let mut profile_index = 0;
    while (profile_index < reference::profile_count()) {
        let profile = reference::profile(profile_index);
        test_world::next_tx(&mut world, test_values::admin());
        let market = market_setup::take_market(&world, &market_handle);
        let config = test_world::take_config(&world);
        let oracle_registry = test_world::take_oracle_registry(&world);
        let mut pyth = oracle_setup::take_pyth(&world, &oracles);
        let mut bs_spot = oracle_setup::take_bs_spot(&world, &oracles);
        let mut bs_forward = oracle_setup::take_bs_forward(&world, &oracles);
        let mut bs_svi = oracle_setup::take_bs_svi(&world, &oracles);
        oracle_setup::seed_surface(
            &mut pyth,
            &mut bs_spot,
            &mut bs_forward,
            &mut bs_svi,
            market_setup::expiry_ms(&market_handle),
            &profile,
            test_values::now_ms(),
            test_world::clock(&resources),
            test_world::ctx(&mut world),
        );
        let pricer = market.load_live_pricer(
            &config,
            &oracle_registry,
            &pyth,
            &bs_spot,
            &bs_forward,
            &bs_svi,
            test_world::clock(&resources),
        );

        let points = reference::points(profile_index);
        let mut point_index = 0;
        while (point_index < points.length()) {
            let point = &points[point_index];
            let actual = pricer.range_price(strike(point.lower()), strike(point.higher()));
            assert_within(actual, point.reference(), point.tolerance());
            point_index = point_index + 1;
        };

        return_shared(bs_svi);
        return_shared(bs_forward);
        return_shared(bs_spot);
        return_shared(pyth);
        return_shared(oracle_registry);
        return_shared(config);
        return_shared(market);
        profile_index = profile_index + 1;
    };

    lifecycle_cap.destroy();
    test_world::finish(world, resources);
}

fun assert_within(actual: u64, expected: u64, tolerance: u64) {
    let difference = if (actual >= expected) { actual - expected } else { expected - actual };
    assert!(difference <= tolerance);
}
