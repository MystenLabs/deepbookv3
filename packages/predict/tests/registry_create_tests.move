// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::registry_create_tests;

use deepbook_predict::{config_constants, constants, registry, test_constants, test_helpers};
use std::unit_test::destroy;
use sui::test_scenario::{Self as test, return_shared};

const PYTH_FEED_BTC: u32 = 100;
const PYTH_FEED_ETH: u32 = 200;
const BTC_TICK_SIZE: u64 = 1_000_000_000; // $1.00 in 1e9 price scaling
const WIDER_BTC_TICK_SIZE: u64 = 10_000_000_000; // $10.00 in 1e9 price scaling
const ETH_TICK_SIZE: u64 = 100_000_000; // $0.10 in 1e9 price scaling
const INVALID_TICK_SIZE: u64 = BTC_TICK_SIZE + 1;

// === register_pyth_feed ===

#[test]
fun register_pyth_feed_records_tick_size() {
    let (scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();

    registry::register_pyth_feed(&mut reg, &admin_cap, PYTH_FEED_BTC, BTC_TICK_SIZE);
    let tick_size = registry::pyth_feed_tick_size(&reg, PYTH_FEED_BTC);
    assert!(tick_size.is_some());
    assert!(*tick_size.borrow() == BTC_TICK_SIZE);
    assert!(registry::pyth_feed_tick_size(&reg, PYTH_FEED_ETH).is_none());

    test_helpers::finish_registry_test(scenario, reg, admin_cap);
}

#[test]
fun register_pyth_feed_distinct_feeds_store_distinct_tick_sizes() {
    let (scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();

    registry::register_pyth_feed(&mut reg, &admin_cap, PYTH_FEED_BTC, BTC_TICK_SIZE);
    registry::register_pyth_feed(&mut reg, &admin_cap, PYTH_FEED_ETH, ETH_TICK_SIZE);

    let btc_tick = registry::pyth_feed_tick_size(&reg, PYTH_FEED_BTC);
    let eth_tick = registry::pyth_feed_tick_size(&reg, PYTH_FEED_ETH);
    assert!(*btc_tick.borrow() == BTC_TICK_SIZE);
    assert!(*eth_tick.borrow() == ETH_TICK_SIZE);
    assert!(*btc_tick.borrow() != *eth_tick.borrow());

    test_helpers::finish_registry_test(scenario, reg, admin_cap);
}

#[test, expected_failure(abort_code = registry::EPythFeedAlreadyRegistered)]
fun register_pyth_feed_duplicate_aborts() {
    let (_scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();

    registry::register_pyth_feed(&mut reg, &admin_cap, PYTH_FEED_BTC, BTC_TICK_SIZE);
    registry::register_pyth_feed(&mut reg, &admin_cap, PYTH_FEED_BTC, BTC_TICK_SIZE);
    abort 999
}

#[test, expected_failure(abort_code = registry::EPackageVersionDisabled)]
fun register_pyth_feed_with_current_version_disabled_aborts() {
    let (_scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();
    let current = constants::current_version!();
    let next = current + 1;
    registry::enable_version(&mut reg, &admin_cap, next);
    registry::disable_version(&mut reg, &admin_cap, current);

    registry::register_pyth_feed(&mut reg, &admin_cap, PYTH_FEED_BTC, BTC_TICK_SIZE);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidOracleTickSize)]
fun register_pyth_feed_unaligned_tick_size_aborts() {
    let (_scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();

    registry::register_pyth_feed(&mut reg, &admin_cap, PYTH_FEED_BTC, INVALID_TICK_SIZE);
    abort 999
}

#[test]
fun pyth_feed_tick_size_returns_none_for_unmapped_feed() {
    let (scenario, reg, admin_cap) = test_helpers::begin_registry_test();

    assert!(registry::pyth_feed_tick_size(&reg, PYTH_FEED_BTC).is_none());

    test_helpers::finish_registry_test(scenario, reg, admin_cap);
}

// === pyth feed tick size admin setter ===

#[test]
fun set_pyth_feed_tick_size_updates_registered_feed() {
    let (scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();

    registry::register_pyth_feed(&mut reg, &admin_cap, PYTH_FEED_BTC, BTC_TICK_SIZE);
    registry::set_pyth_feed_tick_size(&mut reg, &admin_cap, PYTH_FEED_BTC, WIDER_BTC_TICK_SIZE);

    let tick_size = registry::pyth_feed_tick_size(&reg, PYTH_FEED_BTC);
    assert!(tick_size.is_some());
    assert!(*tick_size.borrow() == WIDER_BTC_TICK_SIZE);

    test_helpers::finish_registry_test(scenario, reg, admin_cap);
}

#[test, expected_failure(abort_code = registry::EPythFeedNotRegistered)]
fun set_pyth_feed_tick_size_unknown_feed_aborts() {
    let (_scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();

    registry::set_pyth_feed_tick_size(&mut reg, &admin_cap, PYTH_FEED_BTC, BTC_TICK_SIZE);
    abort 999
}

// === create_manager / create_and_share_manager ===

#[test]
fun create_manager_yields_distinct_objects_per_caller() {
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

    assert!(alice_mgr.id() != bob_mgr.id());

    destroy(alice_mgr);
    destroy(bob_mgr);
    scenario.end();
}
