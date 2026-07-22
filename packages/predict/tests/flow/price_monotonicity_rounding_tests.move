// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The price memo asserts `price <= previous` over active boundary ticks, so a
/// truly monotone surface that merely *computes* as inverted would abort NAV
/// valuation and, because the flush prices every LP fill at one frozen mark,
/// block LP fills pool-wide with nothing for the surface publisher to correct.
///
/// This walks the computed UP-price curve tick by tick on a monotone surface
/// chosen so consecutive true prices differ by a fraction of one raw unit —
/// far below the evaluation error — and asserts the computed curve is still
/// non-increasing. It holds because the approximation error is a smooth
/// function of strike: adjacent strikes carry nearly the same error, so it
/// cancels in the comparison instead of deciding it. That is a property of
/// this comparison's shape, not of the error being small, and it is what makes
/// the point-comparison guard safe here.
#[test_only]
module deepbook_predict::scope_flow__intent_rounding__price_monotonicity_tests;

use deepbook_predict::{
    market_setup,
    oracle_profile,
    oracle_setup,
    pool_setup,
    range_codec,
    test_values,
    test_world
};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

const SCAN_START_TICK: u64 = 16_000;
const SCAN_END_TICK: u64 = 16_200;
const SPOT: u64 = 100_000_000_000;
const SOURCE_MS: u64 = 118_000;

#[test]
fun computed_up_price_stays_ordered_where_true_gaps_are_subunit() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_low_fee_unrestricted_leverage_market(&world, &admin_cap);
    test_world::return_predict_admin_cap(&world, admin_cap);
    let oracles = oracle_setup::create_default_oracles(&mut world);
    test_world::next_tx(&mut world, test_values::admin());
    let oracle_admin_cap = test_world::take_propbook_admin_cap(&world);
    oracle_setup::bind_default_oracles(&world, &oracle_admin_cap, &oracles);
    test_world::return_propbook_admin_cap(&world, oracle_admin_cap);
    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let market_handle = market_setup::create_default_market(&mut world, &resources, &admin_cap);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::next_tx(&mut world, test_values::admin());
    pool_setup::fund_market(&mut world, &resources, &market_handle, test_values::pool_capital());

    // Flat high-variance surface. In the scanned band its true UP prices fall
    // by well under one raw unit per tick while remaining resolvable (around
    // 10,500 units), so ordering here cannot survive on gap size alone.
    test_world::next_tx(&mut world, test_values::admin());
    let surface = oracle_profile::new(
        oracle_profile::spot_prices(SPOT, SPOT, SPOT),
        oracle_profile::svi_params(
            50_000_000_000,
            false,
            0,
            1_000_000,
            0,
            false,
            0,
            false,
        ),
        SOURCE_MS,
    );
    oracle_setup::seed_market_surface(
        &mut world,
        &resources,
        &oracles,
        &market_handle,
        &surface,
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let market = market_setup::take_market(&world, &market_handle);
    let config = test_world::take_config(&world);
    let (pricer, feeds) = oracle_setup::load_pricer(&world, &resources, &oracles, &market, &config);

    let mut tick = SCAN_START_TICK;
    let mut previous = pricer.up_price(
        range_codec::strike_from_tick(tick, test_values::tick_size()),
    );
    let mut inversions = 0;
    tick = tick + 1;
    while (tick <= SCAN_END_TICK) {
        let price = pricer.up_price(
            range_codec::strike_from_tick(tick, test_values::tick_size()),
        );
        if (price > previous) inversions = inversions + 1;
        previous = price;
        tick = tick + 1;
    };
    assert_eq!(inversions, 0);

    oracle_setup::return_feeds(feeds);
    return_shared(config);
    return_shared(market);
    test_world::finish(world, resources);
}
