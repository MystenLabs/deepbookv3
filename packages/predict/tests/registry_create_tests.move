// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::registry_create_tests;

use deepbook_predict::{config_constants, constants, protocol_config, registry, test_helpers};

const UNDERLYING_BTC: u32 = 100;
const UNDERLYING_ETH: u32 = 200;
const BTC_TICK_SIZE: u64 = 1_000_000_000; // $1.00 in 1e9 price scaling
const ETH_TICK_SIZE: u64 = 100_000_000; // $0.10 in 1e9 price scaling
const INVALID_TICK_SIZE: u64 = BTC_TICK_SIZE + 1;

// === register_underlying ===

#[test]
fun register_underlying_records_min_tick_size() {
    let (scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC, BTC_TICK_SIZE);
    let tick_size = reg.underlying_min_tick_size(UNDERLYING_BTC);
    assert!(tick_size.is_some());
    assert!(*tick_size.borrow() == BTC_TICK_SIZE);
    assert!(reg.underlying_min_tick_size(UNDERLYING_ETH).is_none());

    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

#[test]
fun register_underlying_distinct_underlyings_store_distinct_min_tick_sizes() {
    let (scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC, BTC_TICK_SIZE);
    reg.register_underlying(&config, &admin_cap, UNDERLYING_ETH, ETH_TICK_SIZE);

    let btc_tick = reg.underlying_min_tick_size(UNDERLYING_BTC);
    let eth_tick = reg.underlying_min_tick_size(UNDERLYING_ETH);
    assert!(*btc_tick.borrow() == BTC_TICK_SIZE);
    assert!(*eth_tick.borrow() == ETH_TICK_SIZE);
    assert!(*btc_tick.borrow() != *eth_tick.borrow());

    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

#[test, expected_failure(abort_code = registry::EUnderlyingAlreadyRegistered)]
fun register_underlying_duplicate_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC, BTC_TICK_SIZE);
    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC, BTC_TICK_SIZE);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EPackageVersionDisabled)]
fun register_underlying_with_current_version_disabled_aborts() {
    let (_scenario, mut reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    // Push the watermark above the running version so the package is "disabled".
    config.set_version_watermark_for_testing(constants::current_version!() + 1);

    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC, BTC_TICK_SIZE);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMarketTickSize)]
fun register_underlying_unaligned_tick_size_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC, INVALID_TICK_SIZE);
    abort 999
}

#[test]
fun underlying_min_tick_size_returns_none_for_unmapped_underlying() {
    let (scenario, reg, config, admin_cap) = test_helpers::begin_registry_test();

    assert!(reg.underlying_min_tick_size(UNDERLYING_BTC).is_none());

    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}
