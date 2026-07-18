// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Framework coverage for shared-root identity capture and owned-resource teardown.
#[test_only]
module deepbook_predict::framework_world_behavior_tests;

use deepbook_predict::{test_values, test_world};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

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
