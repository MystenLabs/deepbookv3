// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::registry_create_tests;

use deepbook_predict::{config_constants, constants, market_manager, protocol_config, test_helpers};

const UNDERLYING_BTC: u32 = 100;
const BTC_TICK_SIZE: u64 = 1_000_000_000;
const BTC_MAX_EXPIRY_ALLOCATION: u64 = 250_000_000_000;
const BTC_INITIAL_EXPIRY_CASH: u64 = 50_000_000_000;
const WINDOW_SIZE_THREE: u64 = 3;
const ABOVE_MAX_CADENCE_WINDOW_SIZE: u64 = 11;
const DISABLED_VALUE: u64 = 0;
const INVALID_CADENCE_ID: u8 = 6;
const INVALID_TICK_SIZE: u64 = BTC_TICK_SIZE + 1;
const BELOW_EXPIRY_CASH_FLOOR: u64 = 9_999_999_999;
const BELOW_INITIAL_EXPIRY_CASH: u64 = BTC_INITIAL_EXPIRY_CASH - 1;

const EUnexpectedSuccess: u64 = 999;

// === register_underlying ===

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

#[test, expected_failure(abort_code = market_manager::EInvalidCadence)]
fun set_cadence_config_invalid_cadence_id_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_cadence_config(
        &config,
        &admin_cap,
        INVALID_CADENCE_ID,
        BTC_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        BTC_INITIAL_EXPIRY_CASH,
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
        BTC_INITIAL_EXPIRY_CASH,
        WINDOW_SIZE_THREE,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = config_constants::EInvalidCadenceWindowSize)]
fun set_cadence_config_above_max_window_size_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_cadence_config(
        &config,
        &admin_cap,
        market_manager::cadence_one_minute!(),
        BTC_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        BTC_INITIAL_EXPIRY_CASH,
        ABOVE_MAX_CADENCE_WINDOW_SIZE,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_manager::EInvalidCadenceConfig)]
fun set_cadence_config_initial_cash_below_floor_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_cadence_config(
        &config,
        &admin_cap,
        market_manager::cadence_one_minute!(),
        BTC_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        BELOW_EXPIRY_CASH_FLOOR,
        WINDOW_SIZE_THREE,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_manager::EInvalidCadenceConfig)]
fun set_cadence_config_initial_cash_above_allocation_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_cadence_config(
        &config,
        &admin_cap,
        market_manager::cadence_one_minute!(),
        BTC_TICK_SIZE,
        BELOW_INITIAL_EXPIRY_CASH,
        BTC_INITIAL_EXPIRY_CASH,
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
        BTC_INITIAL_EXPIRY_CASH,
        WINDOW_SIZE_THREE,
    );
    abort EUnexpectedSuccess
}
