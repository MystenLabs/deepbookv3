// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::registry_create_tests;

use deepbook_predict::{constants, registry, test_constants};
use std::unit_test::destroy;
use sui::test_scenario::{Self as test, return_shared};

const PYTH_FEED_BTC: u32 = 100;
const PYTH_FEED_ETH: u32 = 200;
const EXPIRY_FEE_WINDOW_DISABLED: u64 = 0;
const EXPIRY_FEE_MAX_MULTIPLIER_DISABLED: u64 = 1_000_000_000; // 1.0 — sentinel disables ramp

// === create_pyth_source ===

#[test]
fun create_pyth_source_returns_id_and_registers() {
    let ctx = &mut tx_context::dummy();
    let (mut reg, admin_cap) = registry::new_for_testing(ctx);

    let pyth_id = registry::create_pyth_source(
        &mut reg,
        &admin_cap,
        PYTH_FEED_BTC,
        EXPIRY_FEE_WINDOW_DISABLED,
        EXPIRY_FEE_MAX_MULTIPLIER_DISABLED,
        ctx,
    );
    let registered = registry::pyth_source_id(&reg, PYTH_FEED_BTC);
    assert!(registered.is_some());
    assert!(*registered.borrow() == pyth_id);
    // Other feed ids must remain unmapped.
    assert!(registry::pyth_source_id(&reg, PYTH_FEED_ETH).is_none());

    registry::destroy_registry_drop_for_testing(reg);
    destroy(admin_cap);
}

#[test]
fun create_pyth_source_distinct_feeds_yield_distinct_ids() {
    let ctx = &mut tx_context::dummy();
    let (mut reg, admin_cap) = registry::new_for_testing(ctx);

    let btc_id = registry::create_pyth_source(
        &mut reg,
        &admin_cap,
        PYTH_FEED_BTC,
        EXPIRY_FEE_WINDOW_DISABLED,
        EXPIRY_FEE_MAX_MULTIPLIER_DISABLED,
        ctx,
    );
    let eth_id = registry::create_pyth_source(
        &mut reg,
        &admin_cap,
        PYTH_FEED_ETH,
        EXPIRY_FEE_WINDOW_DISABLED,
        EXPIRY_FEE_MAX_MULTIPLIER_DISABLED,
        ctx,
    );
    assert!(btc_id != eth_id);

    registry::destroy_registry_drop_for_testing(reg);
    destroy(admin_cap);
}

#[test, expected_failure(abort_code = registry::EPythSourceAlreadyCreated)]
fun create_pyth_source_duplicate_feed_aborts() {
    let ctx = &mut tx_context::dummy();
    let (mut reg, admin_cap) = registry::new_for_testing(ctx);

    registry::create_pyth_source(
        &mut reg,
        &admin_cap,
        PYTH_FEED_BTC,
        EXPIRY_FEE_WINDOW_DISABLED,
        EXPIRY_FEE_MAX_MULTIPLIER_DISABLED,
        ctx,
    );
    registry::create_pyth_source(
        &mut reg,
        &admin_cap,
        PYTH_FEED_BTC,
        EXPIRY_FEE_WINDOW_DISABLED,
        EXPIRY_FEE_MAX_MULTIPLIER_DISABLED,
        ctx,
    );
    abort 999
}

#[test, expected_failure(abort_code = registry::EPackageVersionDisabled)]
fun create_pyth_source_with_current_version_disabled_aborts() {
    // Admin can disable current_version via the version-management path (which
    // bypasses the version gate). Subsequent create_pyth_source then fails the
    // mirrored-version check.
    let ctx = &mut tx_context::dummy();
    let (mut reg, admin_cap) = registry::new_for_testing(ctx);
    let current = constants::current_version!();
    let next = current + 1;
    registry::enable_version(&mut reg, &admin_cap, next);
    registry::disable_version(&mut reg, &admin_cap, current);

    registry::create_pyth_source(
        &mut reg,
        &admin_cap,
        PYTH_FEED_BTC,
        EXPIRY_FEE_WINDOW_DISABLED,
        EXPIRY_FEE_MAX_MULTIPLIER_DISABLED,
        ctx,
    );
    abort 999
}

// === pyth_source_id getter for unknown feed ===

#[test]
fun pyth_source_id_returns_none_for_unmapped_feed() {
    let ctx = &mut tx_context::dummy();
    let (reg, admin_cap) = registry::new_for_testing(ctx);

    assert!(registry::pyth_source_id(&reg, PYTH_FEED_BTC).is_none());

    registry::destroy_registry_for_testing(reg);
    destroy(admin_cap);
}

// === create_manager / create_and_share_manager ===

#[test]
fun create_manager_yields_distinct_objects_per_caller() {
    // The PredictManager key includes the sender, so two different addresses
    // can each claim their own derived manager.
    let mut scenario = test::begin(test_constants::alice());
    let registry_id = registry::init_for_testing(scenario.ctx());

    scenario.next_tx(test_constants::alice());
    let mut reg = scenario.take_shared_by_id<registry::Registry>(registry_id);
    let alice_mgr = registry::create_manager(&mut reg, scenario.ctx());
    return_shared(reg);

    scenario.next_tx(test_constants::bob());
    let mut reg = scenario.take_shared_by_id<registry::Registry>(registry_id);
    let bob_mgr = registry::create_manager(&mut reg, scenario.ctx());
    return_shared(reg);

    // Different senders produce different derived ids.
    assert!(object::id(&alice_mgr) != object::id(&bob_mgr));

    destroy(alice_mgr);
    destroy(bob_mgr);
    scenario.end();
}

// create_expiry_market requires PoolVault and is the largest end-to-end
// constructor in the package. Covered in the PR that adds plp / expiry_market
// scaffolding (PR 6).
