// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Framework coverage for shared-root identity, actor custody, transaction
/// context, and owned-resource teardown.
#[test_only]
module deepbook_predict::scope_framework__intent_behavior__world_tests;

use deepbook_predict::{admin, test_values, test_world};
use std::unit_test::assert_eq;
use sui::{test_scenario::return_shared, transfer};

#[test]
fun bootstrap_captures_every_shared_identity() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    assert_eq!(test_world::sender(&mut world), test_values::admin());
    assert_eq!(test_world::clock(&resources).timestamp_ms(), test_values::now_ms());

    let registry = test_world::take_registry(&world);
    let config = test_world::take_config(&world);
    let vault = test_world::take_vault(&world);
    let account_registry = test_world::take_account_registry(&world);
    let oracle_registry = test_world::take_oracle_registry(&world);
    let root = test_world::take_accumulator_root(&world);

    assert_eq!(registry.id(), test_world::registry_id(&world));
    assert_eq!(config.id(), test_world::config_id(&world));
    assert_eq!(vault.id(), test_world::vault_id(&world));
    assert_eq!(object::id(&account_registry), test_world::account_registry_id(&world));
    assert_eq!(oracle_registry.id(), test_world::oracle_registry_id(&world));
    assert_eq!(object::id(&root), test_world::accumulator_root_id(&world));

    return_shared(root);
    return_shared(oracle_registry);
    return_shared(account_registry);
    return_shared(vault);
    return_shared(config);
    return_shared(registry);
    test_world::finish(world, resources);
}

#[test]
fun root_capability_follows_actor_inventory() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    let admin_cap = test_world::take_predict_admin_cap(&world);
    let admin_cap_id = admin::id(&admin_cap);
    transfer::public_transfer(admin_cap, test_values::alice());

    test_world::next_tx(&mut world, test_values::alice());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    assert_eq!(admin::id(&admin_cap), admin_cap_id);
    transfer::public_transfer(admin_cap, test_values::admin());

    test_world::next_tx(&mut world, test_values::admin());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    assert_eq!(admin::id(&admin_cap), admin_cap_id);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
}

#[test, expected_failure(abort_code = 3, location = sui::test_scenario)]
fun non_owner_cannot_take_root_capability() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::alice());
    let admin_cap = test_world::take_predict_admin_cap(&world);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
    abort 999
}

#[test]
fun custom_transaction_context_preserves_sender_and_gas_price() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx_with_gas_price(
        &mut world,
        test_values::alice(),
        test_values::custom_gas_price(),
    );
    assert_eq!(test_world::sender(&mut world), test_values::alice());
    assert_eq!(test_world::ctx(&mut world).gas_price(), test_values::custom_gas_price());
    test_world::finish(world, resources);
}

#[test]
fun owned_clock_can_advance_between_transactions() {
    let (mut world, mut resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::alice());
    test_world::clock_mut(&mut resources).set_for_testing(test_values::later_ms());
    assert_eq!(test_world::clock(&resources).timestamp_ms(), test_values::later_ms());
    test_world::finish(world, resources);
}
