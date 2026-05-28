// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::builder_code_tests;

use deepbook_predict::{
    builder_code::{Self, BuilderCode},
    registry::Registry,
    test_constants,
    test_helpers
};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::{Self as test, return_shared};

const INDEX_ZERO: u64 = 0;
const INDEX_42: u64 = 42;
const INDEX_OTHER: u64 = 7;

// === Getters ===

#[test]
fun getters_return_constructor_values() {
    let ctx = &mut tx_context::dummy();
    let code = builder_code::new_for_testing(test_constants::alice(), INDEX_42, ctx);
    assert_eq!(code.owner(), test_constants::alice());
    assert_eq!(code.index(), INDEX_42);
    // `id()` returns the same ID across calls (it just reads the UID).
    assert_eq!(code.id(), code.id());
    builder_code::destroy_for_testing(code);
}

// === create_and_share (via registry::create_builder_code) ===

#[test]
fun create_via_registry_shares_object_with_sender_as_owner() {
    let (mut scenario, registry_id) = test_helpers::setup_test();

    scenario.next_tx(test_constants::alice());
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);
    let returned_id = registry.create_builder_code(INDEX_42, scenario.ctx());
    return_shared(registry);

    // The shared object Alice just created is visible in the next tx.
    scenario.next_tx(test_constants::alice());
    let code = test::take_shared<BuilderCode>(&scenario);
    assert_eq!(code.id(), returned_id);
    assert_eq!(code.owner(), test_constants::alice());
    assert_eq!(code.index(), INDEX_42);
    return_shared(code);

    scenario.end();
}

#[test]
fun create_distinct_owners_yields_distinct_objects() {
    // The (owner, index) key derives a fresh shared object even when the index
    // collides across owners. Alice and Bob can both claim index 0.
    let (mut scenario, registry_id) = test_helpers::setup_test();

    scenario.next_tx(test_constants::alice());
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);
    let alice_id = registry.create_builder_code(INDEX_ZERO, scenario.ctx());
    return_shared(registry);

    scenario.next_tx(test_constants::bob());
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);
    let bob_id = registry.create_builder_code(INDEX_ZERO, scenario.ctx());
    return_shared(registry);

    assert!(alice_id != bob_id);
    scenario.end();
}

#[test]
fun same_owner_distinct_indices_yields_distinct_objects() {
    let (mut scenario, registry_id) = test_helpers::setup_test();

    scenario.next_tx(test_constants::alice());
    let mut registry = scenario.take_shared_by_id<Registry>(registry_id);
    let id_a = registry.create_builder_code(INDEX_42, scenario.ctx());
    let id_b = registry.create_builder_code(INDEX_OTHER, scenario.ctx());
    return_shared(registry);

    assert!(id_a != id_b);
    scenario.end();
}

// === Ownership check ===

#[test]
fun owner_passes_assert_owner() {
    // No abort -> the function must complete normally.
    let mut scenario = test::begin(test_constants::alice());
    let code = builder_code::new_for_testing(test_constants::alice(), INDEX_42, scenario.ctx());

    code.assert_owner_for_testing(scenario.ctx());

    destroy(code);
    scenario.end();
}

#[test, expected_failure(abort_code = builder_code::ENotOwner)]
fun non_owner_assert_owner_aborts() {
    // `claim_all_builder_fees` calls `assert_owner` first, so this also
    // protects the public claim path. We test the assertion directly because
    // `AccumulatorRoot` has no test-only constructor.
    let mut scenario = test::begin(test_constants::bob());
    let code = builder_code::new_for_testing(test_constants::alice(), INDEX_42, scenario.ctx());

    code.assert_owner_for_testing(scenario.ctx());

    abort 999
}
