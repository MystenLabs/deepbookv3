// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Composition pressure for multiple actors and multiple protocol object graphs
/// inside one World.
#[test_only]
module deepbook_predict::scope_framework__intent_behavior__world_composition_tests;

use account::{account::{Self, AccountWrapper}, account_registry};
use deepbook_predict::{
    market_setup,
    oracle_profile,
    oracle_setup,
    pricing,
    test_values,
    test_world
};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

#[test]
fun two_actors_recover_their_distinct_account_graphs() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::alice());
    let mut account_registry = test_world::take_account_registry(&world);
    let alice_expected_account = account_registry::derived_address(
        &account_registry,
        test_values::alice(),
    );
    let alice_expected_wrapper = account_registry::derived_wrapper_address(
        &account_registry,
        test_values::alice(),
    );
    let alice_wrapper = account_registry.new(test_world::ctx(&mut world));
    let alice_wrapper_id = alice_wrapper.id();
    assert_eq!(alice_wrapper_id.to_address(), alice_expected_wrapper);
    alice_wrapper.share();
    return_shared(account_registry);

    test_world::next_tx(&mut world, test_values::bob());
    let mut account_registry = test_world::take_account_registry(&world);
    let bob_expected_account = account_registry::derived_address(
        &account_registry,
        test_values::bob(),
    );
    let bob_expected_wrapper = account_registry::derived_wrapper_address(
        &account_registry,
        test_values::bob(),
    );
    let bob_wrapper = account_registry.new(test_world::ctx(&mut world));
    let bob_wrapper_id = bob_wrapper.id();
    assert_eq!(bob_wrapper_id.to_address(), bob_expected_wrapper);
    bob_wrapper.share();
    return_shared(account_registry);

    test_world::next_tx(&mut world, test_values::admin());
    let alice_wrapper = test_world::take_shared_by_id<AccountWrapper>(&world, alice_wrapper_id);
    let bob_wrapper = test_world::take_shared_by_id<AccountWrapper>(&world, bob_wrapper_id);
    assert!(alice_wrapper_id != bob_wrapper_id);
    assert_eq!(alice_wrapper.load_account().owner(), test_values::alice());
    assert_eq!(bob_wrapper.load_account().owner(), test_values::bob());
    assert_eq!(alice_wrapper.load_account().account_id().to_address(), alice_expected_account);
    assert_eq!(bob_wrapper.load_account().account_id().to_address(), bob_expected_account);
    return_shared(bob_wrapper);
    return_shared(alice_wrapper);
    test_world::finish(world, resources);
}

#[test]
fun two_markets_keep_distinct_oracle_sequences() {
    let first_profile = oracle_profile::smoke();
    let second_profile = oracle_profile::smoke_at(first_profile.source_timestamp_ms() + 1);
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::admin());
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_cadence(
        &world,
        &predict_admin_cap,
        test_values::composition_cadence_window_size(),
    );
    test_world::return_predict_admin_cap(&world, predict_admin_cap);
    let oracles = oracle_setup::create_default_oracles(&mut world);

    test_world::next_tx(&mut world, test_values::admin());
    let propbook_admin_cap = test_world::take_propbook_admin_cap(&world);
    oracle_setup::bind_default_oracles(&world, &propbook_admin_cap, &oracles);
    test_world::return_propbook_admin_cap(&world, propbook_admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    let handles = market_setup::create_markets(
        &mut world,
        &resources,
        &predict_admin_cap,
        test_values::composition_cadence_window_size(),
    );
    assert_eq!(handles.length(), test_values::composition_cadence_window_size());
    test_world::return_predict_admin_cap(&world, predict_admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let first_handle = &handles[0];
    let second_handle = &handles[1];
    let first_market = market_setup::take_market(&world, first_handle);
    let second_market = market_setup::take_market(&world, second_handle);
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
        first_market.expiry(),
        &first_profile,
        test_values::now_ms(),
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    oracle_setup::seed_bs_forward(
        &mut bs_forward,
        second_market.expiry(),
        second_profile.block_scholes_forward(),
        second_profile.source_timestamp_ms(),
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    oracle_setup::seed_bs_svi(
        &mut bs_svi,
        second_market.expiry(),
        &second_profile,
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    let first_pricer = first_market.load_live_pricer(
        &config,
        &oracle_registry,
        &pyth,
        &bs_spot,
        &bs_forward,
        &bs_svi,
        test_world::clock(&resources),
    );
    let second_pricer = second_market.load_live_pricer(
        &config,
        &oracle_registry,
        &pyth,
        &bs_spot,
        &bs_forward,
        &bs_svi,
        test_world::clock(&resources),
    );

    assert_eq!(pricing::expiry_market_id(&first_pricer), market_setup::market_id(first_handle));
    assert_eq!(pricing::expiry_market_id(&second_pricer), market_setup::market_id(second_handle));
    assert_eq!(
        pricing::block_scholes_forward_source_timestamp_ms(&first_pricer),
        first_profile.source_timestamp_ms(),
    );
    assert_eq!(
        pricing::block_scholes_forward_source_timestamp_ms(&second_pricer),
        second_profile.source_timestamp_ms(),
    );
    assert_eq!(
        pricing::block_scholes_svi_source_timestamp_ms(&first_pricer),
        first_profile.source_timestamp_ms(),
    );
    assert_eq!(
        pricing::block_scholes_svi_source_timestamp_ms(&second_pricer),
        second_profile.source_timestamp_ms(),
    );
    return_shared(bs_svi);
    return_shared(bs_forward);
    return_shared(bs_spot);
    return_shared(pyth);
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(second_market);
    return_shared(first_market);
    test_world::finish(world, resources);
}
