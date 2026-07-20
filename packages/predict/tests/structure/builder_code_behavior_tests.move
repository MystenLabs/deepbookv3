// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Structural coverage for derived builder-code identity and ownership.
#[test_only]
module deepbook_predict::scope_structure__intent_behavior__builder_code_tests;

use deepbook_predict::{builder_code::BuilderCode, test_values, test_world};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

const BUILDER_INDEX: u64 = 17;

#[test]
fun registry_derives_builder_code_for_the_calling_owner_and_index() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    test_world::next_tx(&mut world, test_values::alice());
    let mut registry = test_world::take_registry(&world);
    let config = test_world::take_config(&world);
    let code_id = registry.create_and_share_builder_code(
        &config,
        BUILDER_INDEX,
        test_world::ctx(&mut world),
    );
    return_shared(config);
    return_shared(registry);

    test_world::next_tx(&mut world, test_values::bob());
    let code = test_world::take_shared_by_id<BuilderCode>(&world, code_id);
    assert_eq!(code.id(), code_id);
    assert_eq!(code.owner(), test_values::alice());
    assert_eq!(code.index(), BUILDER_INDEX);
    return_shared(code);
    test_world::finish(world, resources);
}
