// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::registry_create_tests;

use deepbook_predict::{config_constants, constants, registry, test_constants, test_helpers};
use std::unit_test::destroy;
use sui::test_scenario::{Self as test, return_shared};

const UNDERLYING_BTC: u32 = 100;
const UNDERLYING_ETH: u32 = 200;
const BTC_TICK_SIZE: u64 = 1_000_000_000; // $1.00 in 1e9 price scaling
const ETH_TICK_SIZE: u64 = 100_000_000; // $0.10 in 1e9 price scaling
const INVALID_TICK_SIZE: u64 = BTC_TICK_SIZE + 1;

// === register_underlying ===

#[test]
fun register_underlying_records_min_tick_size() {
    let (scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();

    registry::register_underlying(&mut reg, &admin_cap, UNDERLYING_BTC, BTC_TICK_SIZE);
    let tick_size = registry::underlying_min_tick_size(&reg, UNDERLYING_BTC);
    assert!(tick_size.is_some());
    assert!(*tick_size.borrow() == BTC_TICK_SIZE);
    assert!(registry::underlying_min_tick_size(&reg, UNDERLYING_ETH).is_none());

    test_helpers::finish_registry_test(scenario, reg, admin_cap);
}

#[test]
fun register_underlying_distinct_underlyings_store_distinct_min_tick_sizes() {
    let (scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();

    registry::register_underlying(&mut reg, &admin_cap, UNDERLYING_BTC, BTC_TICK_SIZE);
    registry::register_underlying(&mut reg, &admin_cap, UNDERLYING_ETH, ETH_TICK_SIZE);

    let btc_tick = registry::underlying_min_tick_size(&reg, UNDERLYING_BTC);
    let eth_tick = registry::underlying_min_tick_size(&reg, UNDERLYING_ETH);
    assert!(*btc_tick.borrow() == BTC_TICK_SIZE);
    assert!(*eth_tick.borrow() == ETH_TICK_SIZE);
    assert!(*btc_tick.borrow() != *eth_tick.borrow());

    test_helpers::finish_registry_test(scenario, reg, admin_cap);
}

#[test, expected_failure(abort_code = registry::EUnderlyingAlreadyRegistered)]
fun register_underlying_duplicate_aborts() {
    let (_scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();

    registry::register_underlying(&mut reg, &admin_cap, UNDERLYING_BTC, BTC_TICK_SIZE);
    registry::register_underlying(&mut reg, &admin_cap, UNDERLYING_BTC, BTC_TICK_SIZE);
    abort 999
}

#[test, expected_failure(abort_code = registry::EPackageVersionDisabled)]
fun register_underlying_with_current_version_disabled_aborts() {
    let (_scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();
    let current = constants::current_version!();
    let next = current + 1;
    registry::enable_version(&mut reg, &admin_cap, next);
    registry::disable_version(&mut reg, &admin_cap, current);

    registry::register_underlying(&mut reg, &admin_cap, UNDERLYING_BTC, BTC_TICK_SIZE);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMarketTickSize)]
fun register_underlying_unaligned_tick_size_aborts() {
    let (_scenario, mut reg, admin_cap) = test_helpers::begin_registry_test();

    registry::register_underlying(&mut reg, &admin_cap, UNDERLYING_BTC, INVALID_TICK_SIZE);
    abort 999
}

#[test]
fun underlying_min_tick_size_returns_none_for_unmapped_underlying() {
    let (scenario, reg, admin_cap) = test_helpers::begin_registry_test();

    assert!(registry::underlying_min_tick_size(&reg, UNDERLYING_BTC).is_none());

    test_helpers::finish_registry_test(scenario, reg, admin_cap);
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
