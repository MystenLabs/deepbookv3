// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Structural guards for actor-bound and revocable protocol authority.
#[test_only]
module deepbook_predict::scope_structure__intent_guard__capability_tests;

use account::account_registry;
use deepbook_predict::{
    market_lifecycle_cap,
    market_setup,
    oracle_setup,
    pause_cap,
    predict_account::PredictApp,
    registry,
    test_values,
    test_world
};
use propbook::registry as propbook_registry;
use std::unit_test::assert_eq;
use sui::{test_scenario::return_shared, transfer};

#[test]
fun account_admin_authorizes_and_deauthorizes_predict_app() {
    let (world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    let account_admin_cap = test_world::take_account_admin_cap(&world);
    let mut account_registry = test_world::take_account_registry(&world);
    assert!(!account_registry.is_app_authorized<PredictApp>());
    account_registry.authorize_app<PredictApp>(&account_admin_cap);
    assert!(account_registry.is_app_authorized<PredictApp>());
    account_registry.deauthorize_app<PredictApp>(&account_admin_cap);
    assert!(!account_registry.is_app_authorized<PredictApp>());
    return_shared(account_registry);
    test_world::return_account_admin_cap(&world, account_admin_cap);
    test_world::finish(world, resources);
}

#[test]
fun propbook_admin_cap_follows_actor_inventory() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    let cap = test_world::take_propbook_admin_cap(&world);
    let cap_id = propbook_registry::registry_admin_cap_id(&cap);
    transfer::public_transfer(cap, test_values::alice());

    test_world::next_tx(&mut world, test_values::alice());
    let cap = test_world::take_propbook_admin_cap(&world);
    assert_eq!(propbook_registry::registry_admin_cap_id(&cap), cap_id);
    transfer::public_transfer(cap, test_values::admin());

    test_world::next_tx(&mut world, test_values::admin());
    let cap = test_world::take_propbook_admin_cap(&world);
    assert_eq!(propbook_registry::registry_admin_cap_id(&cap), cap_id);
    test_world::return_propbook_admin_cap(&world, cap);
    test_world::finish(world, resources);
}

#[test]
fun pause_cap_scopes_market_and_global_pauses_independently() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    let admin_cap = test_world::take_predict_admin_cap(&world);
    market_setup::configure_default_cadence(&world, &admin_cap);
    test_world::return_predict_admin_cap(&world, admin_cap);
    let oracles = oracle_setup::create_default_oracles(&mut world);

    test_world::next_tx(&mut world, test_values::admin());
    let propbook_admin_cap = test_world::take_propbook_admin_cap(&world);
    oracle_setup::bind_default_oracles(&world, &propbook_admin_cap, &oracles);
    test_world::return_propbook_admin_cap(&world, propbook_admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let pause_cap = registry.mint_pause_cap(&admin_cap, test_world::ctx(&mut world));
    let pause_cap_id = pause_cap::id(&pause_cap);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    transfer::public_transfer(pause_cap, test_values::alice());

    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let market_handle = market_setup::create_default_market(
        &mut world,
        &resources,
        &admin_cap,
    );
    test_world::return_predict_admin_cap(&world, admin_cap);

    test_world::next_tx(&mut world, test_values::alice());
    let pause_cap = test_world::take_pause_cap(&world, pause_cap_id);
    let registry = test_world::take_registry(&world);
    let mut config = test_world::take_config(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    registry::pause_expiry_market_mint_pause_cap(&mut market, &registry, &pause_cap);
    assert!(market.mint_paused());
    assert!(!config.trading_paused());
    registry::pause_trading_pause_cap(&mut config, &registry, &pause_cap);
    assert!(config.trading_paused());
    return_shared(market);
    return_shared(config);
    return_shared(registry);
    transfer::public_transfer(pause_cap, test_values::admin());

    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let mut config = test_world::take_config(&world);
    let mut market = market_setup::take_market(&world, &market_handle);
    let pause_cap = test_world::take_pause_cap(&world, pause_cap_id);
    config.set_trading_paused(&admin_cap, false);
    market.set_mint_paused(&config, &admin_cap, false);
    assert!(!config.trading_paused());
    assert!(!market.mint_paused());
    registry.revoke_pause_cap(&admin_cap, pause_cap_id);
    pause_cap.destroy();
    return_shared(market);
    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
}

#[test, expected_failure(abort_code = registry::EPauseCapNotValid)]
fun revoked_pause_cap_cannot_pause_trading() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let mut config = test_world::take_config(&world);
    let pause_cap = registry.mint_pause_cap(&admin_cap, test_world::ctx(&mut world));
    registry.revoke_pause_cap(&admin_cap, pause_cap::id(&pause_cap));
    registry::pause_trading_pause_cap(&mut config, &registry, &pause_cap);
    return_shared(config);
    return_shared(registry);
    pause_cap.destroy();
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
    abort 999
}

#[test, expected_failure(abort_code = registry::ELifecycleCapNotValid)]
fun revoked_lifecycle_cap_cannot_generate_proof() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let config = test_world::take_config(&world);
    let lifecycle_cap = registry.mint_lifecycle_cap(
        &config,
        &predict_admin_cap,
        test_world::ctx(&mut world),
    );
    let lifecycle_cap_id = market_lifecycle_cap::id(&lifecycle_cap);
    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, predict_admin_cap);
    transfer::public_transfer(lifecycle_cap, test_values::alice());

    test_world::next_tx(&mut world, test_values::alice());
    let lifecycle_cap = test_world::take_lifecycle_cap(&world, lifecycle_cap_id);
    assert_eq!(market_lifecycle_cap::id(&lifecycle_cap), lifecycle_cap_id);
    transfer::public_transfer(lifecycle_cap, test_values::admin());

    test_world::next_tx(&mut world, test_values::admin());
    let predict_admin_cap = test_world::take_predict_admin_cap(&world);
    let lifecycle_cap = test_world::take_lifecycle_cap(&world, lifecycle_cap_id);
    let mut registry = test_world::take_registry(&world);
    registry.revoke_lifecycle_cap(&predict_admin_cap, lifecycle_cap_id);
    let _proof = registry.generate_lifecycle_proof(&lifecycle_cap);
    return_shared(registry);
    test_world::return_lifecycle_cap(&world, lifecycle_cap);
    test_world::return_predict_admin_cap(&world, predict_admin_cap);
    test_world::finish(world, resources);
    abort 999
}
