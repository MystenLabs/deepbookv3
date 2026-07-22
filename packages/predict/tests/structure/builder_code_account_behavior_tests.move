// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Sticky builder-code attribution on a production AccountWrapper.
#[test_only]
module deepbook_predict::scope_structure__intent_behavior__builder_code_account_tests;

use account::account;
use deepbook_predict::{
    account_setup,
    builder_code::BuilderCode,
    predict_account,
    test_values,
    test_world
};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

const BUILDER_INDEX: u64 = 3;

#[test]
fun owner_can_set_and_clear_sticky_builder_attribution() {
    let (mut world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    test_world::next_tx(&mut world, test_values::alice());
    let handle = account_setup::create_account(&mut world);
    let mut registry = test_world::take_registry(&world);
    let config = test_world::take_config(&world);
    let code_id = registry.create_and_share_builder_code(
        &config,
        BUILDER_INDEX,
        test_world::ctx(&mut world),
    );
    return_shared(config);
    return_shared(registry);

    test_world::next_tx(&mut world, test_values::alice());
    let mut wrapper = account_setup::take_account(&world, &handle);
    let code = test_world::take_shared_by_id<BuilderCode>(&world, code_id);
    let auth = account::generate_auth(test_world::ctx(&mut world));
    predict_account::set_builder_code(&mut wrapper, auth, &code, test_world::ctx(&mut world));
    assert!(predict_account::builder_code_id(wrapper.load_account()).contains(&code_id));
    let auth = account::generate_auth(test_world::ctx(&mut world));
    predict_account::unset_builder_code(&mut wrapper, auth, test_world::ctx(&mut world));
    assert!(predict_account::builder_code_id(wrapper.load_account()).is_none());
    assert_eq!(code.owner(), test_values::alice());
    return_shared(code);
    return_shared(wrapper);
    test_world::finish(world, resources);
}
