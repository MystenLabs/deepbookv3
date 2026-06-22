// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::registry_create_tests;

use deepbook_predict::{config_constants, constants, market_manager, protocol_config, test_helpers};
use std::unit_test::assert_eq;

const UNDERLYING_BTC: u32 = 100;
const UNDERLYING_ETH: u32 = 200;
const BTC_TICK_SIZE: u64 = 1_000_000_000;
const ETH_TICK_SIZE: u64 = 100_000_000;
const BTC_MAX_EXPIRY_ALLOCATION: u64 = 250_000_000_000;
const ETH_MAX_EXPIRY_ALLOCATION: u64 = 100_000_000_000;
const WINDOW_SIZE_THREE: u64 = 3;
const DISABLED_VALUE: u64 = 0;
const INVALID_CADENCE_ID: u8 = 6;
const INVALID_TICK_SIZE: u64 = BTC_TICK_SIZE + 1;
const BELOW_MIN_EXPIRY_ALLOCATION: u64 = 9_999_999_999;

const EUnexpectedSuccess: u64 = 999;

// === register_underlying ===

#[test]
fun register_underlying_allows_distinct_underlyings() {
    let (scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC);
    reg.register_underlying(&config, &admin_cap, UNDERLYING_ETH);
    reg.set_cadence_config(
        &config,
        &admin_cap,
        market_manager::cadence_one_day!(),
        ETH_TICK_SIZE,
        ETH_MAX_EXPIRY_ALLOCATION,
        WINDOW_SIZE_THREE,
    );
    let (tick_size, max_expiry_allocation, window_size) = reg.cadence_config(
        market_manager::cadence_one_day!(),
    );
    assert_eq!(tick_size, ETH_TICK_SIZE);
    assert_eq!(max_expiry_allocation, ETH_MAX_EXPIRY_ALLOCATION);
    assert_eq!(window_size, WINDOW_SIZE_THREE);

    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

#[test, expected_failure(abort_code = market_manager::EUnderlyingAlreadyRegistered)]
fun register_underlying_duplicate_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC);
    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = protocol_config::EPackageVersionDisabled)]
fun register_underlying_with_current_version_disabled_aborts() {
    let (_scenario, mut reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    config.set_version_watermark_for_testing(constants::current_version!() + 1);

    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC);
    abort EUnexpectedSuccess
}

// === set_cadence_config ===

#[test]
fun cadence_config_initializes_disabled() {
    let (scenario, reg, config, admin_cap) = test_helpers::begin_registry_test();

    let (tick_size, max_expiry_allocation, window_size) = reg.cadence_config(
        market_manager::cadence_one_minute!(),
    );
    assert_eq!(tick_size, DISABLED_VALUE);
    assert_eq!(max_expiry_allocation, DISABLED_VALUE);
    assert_eq!(window_size, DISABLED_VALUE);

    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

#[test]
fun set_cadence_config_updates_all_terms() {
    let (scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_cadence_config(
        &config,
        &admin_cap,
        market_manager::cadence_one_minute!(),
        BTC_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        WINDOW_SIZE_THREE,
    );
    let (tick_size, max_expiry_allocation, window_size) = reg.cadence_config(
        market_manager::cadence_one_minute!(),
    );
    assert_eq!(tick_size, BTC_TICK_SIZE);
    assert_eq!(max_expiry_allocation, BTC_MAX_EXPIRY_ALLOCATION);
    assert_eq!(window_size, WINDOW_SIZE_THREE);

    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

#[test]
fun set_cadence_config_can_disable_cadence() {
    let (scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_cadence_config(
        &config,
        &admin_cap,
        market_manager::cadence_one_minute!(),
        BTC_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        WINDOW_SIZE_THREE,
    );
    reg.set_cadence_config(
        &config,
        &admin_cap,
        market_manager::cadence_one_minute!(),
        DISABLED_VALUE,
        DISABLED_VALUE,
        DISABLED_VALUE,
    );
    let (tick_size, max_expiry_allocation, window_size) = reg.cadence_config(
        market_manager::cadence_one_minute!(),
    );
    assert_eq!(tick_size, DISABLED_VALUE);
    assert_eq!(max_expiry_allocation, DISABLED_VALUE);
    assert_eq!(window_size, DISABLED_VALUE);

    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

#[test, expected_failure(abort_code = market_manager::EInvalidCadence)]
fun set_cadence_config_invalid_cadence_id_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_cadence_config(
        &config,
        &admin_cap,
        INVALID_CADENCE_ID,
        BTC_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        WINDOW_SIZE_THREE,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = config_constants::EInvalidMarketTickSize)]
fun set_cadence_config_unaligned_tick_size_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_cadence_config(
        &config,
        &admin_cap,
        market_manager::cadence_one_minute!(),
        INVALID_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        WINDOW_SIZE_THREE,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_manager::EInvalidCadenceConfig)]
fun set_cadence_config_below_min_allocation_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_cadence_config(
        &config,
        &admin_cap,
        market_manager::cadence_one_minute!(),
        BTC_TICK_SIZE,
        BELOW_MIN_EXPIRY_ALLOCATION,
        WINDOW_SIZE_THREE,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_manager::EInvalidCadenceConfig)]
fun set_cadence_config_partial_disable_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_cadence_config(
        &config,
        &admin_cap,
        market_manager::cadence_one_minute!(),
        DISABLED_VALUE,
        BTC_MAX_EXPIRY_ALLOCATION,
        WINDOW_SIZE_THREE,
    );
    abort EUnexpectedSuccess
}
