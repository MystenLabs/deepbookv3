// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Account-owner and builder-code-owner guards.
#[test_only]
module deepbook_predict::scope_structure__intent_guard__builder_code_account_tests;

use account::account;
use deepbook_predict::{
    account_setup,
    builder_code::{Self, BuilderCode},
    predict_account,
    test_values,
    test_world
};
use sui::{coin, test_scenario::return_shared};

const BUILDER_INDEX: u64 = 3;

#[test, expected_failure(abort_code = account::EInvalidOwner)]
fun non_owner_cannot_set_builder_attribution() {
    let (mut world, _resources) = test_world::new(
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

    test_world::next_tx(&mut world, test_values::bob());
    let mut wrapper = account_setup::take_account(&world, &handle);
    let code = test_world::take_shared_by_id<BuilderCode>(&world, code_id);
    let auth = account::generate_auth(test_world::ctx(&mut world));
    predict_account::set_builder_code(&mut wrapper, auth, &code, test_world::ctx(&mut world));
    abort 999
}

#[test, expected_failure(abort_code = builder_code::ENotOwner)]
fun non_owner_cannot_claim_builder_fees() {
    let (mut world, _resources) = test_world::new(
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
    let mut code = test_world::take_shared_by_id<BuilderCode>(&world, code_id);
    let root = test_world::take_accumulator_root(&world);
    let empty = code.claim_all_builder_fees(&root, test_world::ctx(&mut world));
    coin::destroy_zero(empty);
    abort 999
}
