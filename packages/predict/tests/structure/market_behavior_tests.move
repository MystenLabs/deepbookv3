// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Structural coverage for production market construction and live-pricer bindings.
#[test_only]
module deepbook_predict::scope_structure__intent_behavior__market_tests;

use block_scholes_oracle::update;
use deepbook_predict::{
    expiry_market::ExpiryMarket,
    market_manager,
    oracle_profile,
    pricing,
    test_values,
    test_world
};
use propbook::{
    block_scholes_forward_feed::BlockScholesForwardFeed,
    block_scholes_spot_feed::BlockScholesSpotFeed,
    block_scholes_svi_feed::BlockScholesSVIFeed,
    pyth_feed::{Self, PythFeed},
    registry
};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

const PYTH_EXPONENT_NEGATIVE_NINE: u16 = 9;
#[test]
fun production_market_loads_bound_live_surface() {
    let profile = oracle_profile::smoke();
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let mut predict_registry = test_world::take_registry(&world);
    let config = test_world::take_config(&world);
    predict_registry.register_underlying(
        &config,
        test_world::predict_admin_cap(&resources),
        test_values::propbook_underlying_id(),
    );
    predict_registry.set_template_cadence_config(
        &config,
        test_world::predict_admin_cap(&resources),
        test_values::propbook_underlying_id(),
        test_values::cadence_id(),
        test_values::tick_size(),
        test_values::admission_tick_size(),
        test_values::max_expiry_allocation(),
        test_values::initial_expiry_cash(),
        test_values::cadence_window_size(),
    );
    let cadence = predict_registry.cadence_config(
        test_values::propbook_underlying_id(),
        test_values::cadence_id(),
    );
    assert_eq!(market_manager::cadence_tick_size(&cadence), test_values::tick_size());
    assert_eq!(
        market_manager::cadence_admission_tick_size(&cadence),
        test_values::admission_tick_size(),
    );
    assert_eq!(
        market_manager::cadence_max_expiry_allocation(&cadence),
        test_values::max_expiry_allocation(),
    );
    assert_eq!(
        market_manager::cadence_initial_expiry_cash(&cadence),
        test_values::initial_expiry_cash(),
    );
    assert!(market_manager::cadence_enabled(&cadence));
    return_shared(config);
    return_shared(predict_registry);

    let mut oracle_registry = test_world::take_oracle_registry(&world);
    let pyth_id = registry::create_and_share_pyth_feed(
        &mut oracle_registry,
        test_values::pyth_source_id(),
        test_world::ctx(&mut world),
    );
    let bs_spot_id = registry::create_and_share_block_scholes_spot_feed(
        &mut oracle_registry,
        test_values::pyth_source_id(),
        test_world::ctx(&mut world),
    );
    let bs_forward_id = registry::create_and_share_block_scholes_forward_feed(
        &mut oracle_registry,
        test_values::pyth_source_id(),
        test_world::ctx(&mut world),
    );
    let bs_svi_id = registry::create_and_share_block_scholes_svi_feed(
        &mut oracle_registry,
        test_values::pyth_source_id(),
        test_world::ctx(&mut world),
    );
    return_shared(oracle_registry);

    test_world::next_tx(&mut world, test_values::admin());
    let mut oracle_registry = test_world::take_oracle_registry(&world);
    let pyth = test_world::take_shared_by_id<PythFeed>(&world, pyth_id);
    let bs_spot = test_world::take_shared_by_id<BlockScholesSpotFeed>(&world, bs_spot_id);
    let bs_forward = test_world::take_shared_by_id<BlockScholesForwardFeed>(&world, bs_forward_id);
    let bs_svi = test_world::take_shared_by_id<BlockScholesSVIFeed>(&world, bs_svi_id);
    oracle_registry.bind_pyth_to_underlying(
        test_world::propbook_admin_cap(&resources),
        &pyth,
        test_values::propbook_underlying_id(),
    );
    oracle_registry.bind_block_scholes_spot_to_underlying(
        test_world::propbook_admin_cap(&resources),
        &bs_spot,
        test_values::propbook_underlying_id(),
    );
    oracle_registry.bind_block_scholes_surface_to_underlying(
        test_world::propbook_admin_cap(&resources),
        &bs_forward,
        &bs_svi,
        test_values::propbook_underlying_id(),
    );
    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    return_shared(oracle_registry);

    test_world::next_tx(&mut world, test_values::admin());
    let mut predict_registry = test_world::take_registry(&world);
    let mut vault = test_world::take_vault(&world);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let lifecycle_cap = predict_registry.mint_lifecycle_cap(
        &config,
        test_world::predict_admin_cap(&resources),
        test_world::ctx(&mut world),
    );
    let market_id = predict_registry.create_and_share_expiry_market(
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        test_values::propbook_underlying_id(),
        test_values::cadence_id(),
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    assert!(
        predict_registry
            .expiry_market_id(test_values::propbook_underlying_id(), test_values::expiry_ms())
            .contains(&market_id),
    );
    assert!(vault.active_expiry_markets().contains(&market_id));
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(vault);
    return_shared(predict_registry);

    test_world::next_tx(&mut world, test_values::admin());
    let market = test_world::take_shared_by_id<ExpiryMarket>(&world, market_id);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let mut pyth = test_world::take_shared_by_id<PythFeed>(&world, pyth_id);
    let mut bs_spot = test_world::take_shared_by_id<BlockScholesSpotFeed>(&world, bs_spot_id);
    let mut bs_forward = test_world::take_shared_by_id<BlockScholesForwardFeed>(
        &world,
        bs_forward_id,
    );
    let mut bs_svi = test_world::take_shared_by_id<BlockScholesSVIFeed>(&world, bs_svi_id);

    assert_eq!(market.id(), market_id);
    assert_eq!(market.expiry(), test_values::expiry_ms());
    assert_eq!(market.cash_balance(), 0);
    assert_eq!(market.tick_size(), test_values::tick_size());
    assert_eq!(market.admission_tick_size(), test_values::admission_tick_size());

    pyth_feed::record_raw_for_testing(
        &mut pyth,
        profile.pyth_spot(),
        false,
        PYTH_EXPONENT_NEGATIVE_NINE,
        true,
        profile.source_timestamp_ms() * 1000,
        test_values::now_ms(),
        false,
    );
    bs_spot.update(
        update::new_spot_update(
            test_values::pyth_source_id(),
            profile.source_timestamp_ms(),
            profile.block_scholes_spot(),
        ),
        test_world::clock(&resources),
    );
    bs_forward.update(
        update::new_forward_update(
            test_values::pyth_source_id(),
            test_values::expiry_ms(),
            profile.source_timestamp_ms(),
            profile.block_scholes_forward(),
        ),
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    bs_svi.update(
        update::new_svi_update(
            test_values::pyth_source_id(),
            test_values::expiry_ms(),
            profile.source_timestamp_ms(),
            profile.svi_a(),
            profile.svi_a_is_negative(),
            profile.svi_b(),
            profile.svi_sigma(),
            profile.svi_rho_magnitude(),
            profile.svi_rho_is_negative(),
            profile.svi_m_magnitude(),
            profile.svi_m_is_negative(),
        ),
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
    assert_eq!(pricing::expiry_market_id(&pricer), market_id);
    assert_eq!(pricing::pyth_spot_source_timestamp_ms(&pricer), profile.source_timestamp_ms());
    assert_eq!(
        pricing::block_scholes_spot_source_timestamp_ms(&pricer),
        profile.source_timestamp_ms(),
    );
    assert_eq!(
        pricing::block_scholes_forward_source_timestamp_ms(&pricer),
        profile.source_timestamp_ms(),
    );
    assert_eq!(
        pricing::block_scholes_svi_source_timestamp_ms(&pricer),
        profile.source_timestamp_ms(),
    );

    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(market);
    lifecycle_cap.destroy();
    test_world::finish(world, resources);
}
