// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Structural guards on production market creation.
#[test_only]
module deepbook_predict::scope_structure__intent_guard__market_creation_tests;

use deepbook_predict::{
    market_manager,
    market_setup,
    oracle_setup,
    protocol_config,
    registry,
    test_values,
    test_world
};
use sui::test_scenario::return_shared;

#[test, expected_failure(abort_code = protocol_config::ETradingPaused)]
fun global_pause_blocks_market_creation() {
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
    let mut vault = test_world::take_vault(&world);
    let mut config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let lifecycle_cap = registry.mint_lifecycle_cap(
        &config,
        &admin_cap,
        test_world::ctx(&mut world),
    );
    config.set_trading_paused(&admin_cap, true);
    let _ = registry.create_and_share_expiry_market(
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        test_values::propbook_underlying_id(),
        test_values::cadence_id(),
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(vault);
    return_shared(registry);
    lifecycle_cap.destroy();
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
    abort 999
}

#[test, expected_failure(abort_code = registry::ELifecycleCapNotValid)]
fun revoked_lifecycle_cap_cannot_create_market() {
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
    let mut vault = test_world::take_vault(&world);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let lifecycle_cap = registry.mint_lifecycle_cap(
        &config,
        &admin_cap,
        test_world::ctx(&mut world),
    );
    registry.revoke_lifecycle_cap(&admin_cap, lifecycle_cap.id());
    let _ = registry.create_and_share_expiry_market(
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        test_values::propbook_underlying_id(),
        test_values::cadence_id(),
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(vault);
    return_shared(registry);
    lifecycle_cap.destroy();
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
    abort 999
}

#[test, expected_failure(abort_code = market_manager::ECadenceWindowExceeded)]
fun creating_beyond_the_configured_window_aborts() {
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
    let _first = market_setup::create_default_market(&mut world, &resources, &admin_cap);
    test_world::return_predict_admin_cap(&world, admin_cap);

    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let mut vault = test_world::take_vault(&world);
    let config = test_world::take_config(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let lifecycle_cap = registry.mint_lifecycle_cap(
        &config,
        &admin_cap,
        test_world::ctx(&mut world),
    );
    let _ = registry.create_and_share_expiry_market(
        &mut vault,
        &config,
        &oracle_registry,
        &lifecycle_cap,
        test_values::propbook_underlying_id(),
        test_values::cadence_id(),
        test_world::clock(&resources),
        test_world::ctx(&mut world),
    );
    return_shared(oracle_registry);
    return_shared(config);
    return_shared(vault);
    return_shared(registry);
    lifecycle_cap.destroy();
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
    abort 999
}
