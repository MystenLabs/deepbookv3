// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Structural guards for actor-bound and revocable protocol authority.
#[test_only]
module deepbook_predict::scope_structure__intent_guard__capability_tests;

use deepbook_predict::{market_lifecycle_cap, registry, test_values, test_world};
use std::unit_test::assert_eq;
use sui::{test_scenario::return_shared, transfer};

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
