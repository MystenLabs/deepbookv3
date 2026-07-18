// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::registry_create_tests;

use deepbook_predict::{config_constants, market_manager, test_helpers};
use std::unit_test::assert_eq;

const UNDERLYING_BTC: u32 = 100;
const UNDERLYING_ETH: u32 = 200;
const BTC_TICK_SIZE: u64 = 1_000_000_000;
const BTC_ADMISSION_TICK_SIZE: u64 = 10_000_000_000;
const BTC_MAX_EXPIRY_ALLOCATION: u64 = 250_000_000_000;
const BTC_INITIAL_EXPIRY_CASH: u64 = 50_000_000_000;
const ETH_TICK_SIZE: u64 = 2_000_000_000;
const ETH_ADMISSION_TICK_SIZE: u64 = 4_000_000_000;
const ETH_MAX_EXPIRY_ALLOCATION: u64 = 500_000_000_000;
const ETH_INITIAL_EXPIRY_CASH: u64 = 100_000_000_000;
const WINDOW_SIZE_THREE: u64 = 3;
const WINDOW_SIZE_TWO: u64 = 2;
const SUPPORTED_CADENCE_COUNT: u64 = 6;
const ABOVE_MAX_CADENCE_WINDOW_SIZE: u64 = 11;
const DISABLED_VALUE: u64 = 0;
const INVALID_CADENCE_ID: u8 = 6;
const INVALID_TICK_SIZE: u64 = BTC_TICK_SIZE + 1;
const INVALID_ADMISSION_TICK_SIZE: u64 = BTC_ADMISSION_TICK_SIZE + 1;
const BELOW_TICK_SIZE_ADMISSION_TICK_SIZE: u64 = BTC_TICK_SIZE / 10;
const NON_MULTIPLE_ADMISSION_TICK_SIZE: u64 = BTC_TICK_SIZE + BTC_TICK_SIZE / 2;
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

// === set_template_cadence_config ===

#[test, expected_failure(abort_code = market_manager::EInvalidCadence)]
fun set_cadence_config_invalid_cadence_id_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_template_cadence_config(
        &config,
        &admin_cap,
        UNDERLYING_BTC,
        INVALID_CADENCE_ID,
        BTC_TICK_SIZE,
        BTC_ADMISSION_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        BTC_INITIAL_EXPIRY_CASH,
        WINDOW_SIZE_THREE,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_manager::EUnderlyingNotRegistered)]
fun set_cadence_config_unregistered_underlying_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_template_cadence_config(
        &config,
        &admin_cap,
        UNDERLYING_BTC,
        market_manager::cadence_one_minute!(),
        BTC_TICK_SIZE,
        BTC_ADMISSION_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        BTC_INITIAL_EXPIRY_CASH,
        WINDOW_SIZE_THREE,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = config_constants::EInvalidMarketTickSize)]
fun set_cadence_config_unaligned_tick_size_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_template_cadence_config(
        &config,
        &admin_cap,
        UNDERLYING_BTC,
        market_manager::cadence_one_minute!(),
        INVALID_TICK_SIZE,
        BTC_ADMISSION_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        BTC_INITIAL_EXPIRY_CASH,
        WINDOW_SIZE_THREE,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = config_constants::EInvalidMarketTickSize)]
fun set_cadence_config_unaligned_admission_tick_size_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_template_cadence_config(
        &config,
        &admin_cap,
        UNDERLYING_BTC,
        market_manager::cadence_one_minute!(),
        BTC_TICK_SIZE,
        INVALID_ADMISSION_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        BTC_INITIAL_EXPIRY_CASH,
        WINDOW_SIZE_THREE,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_manager::EInvalidCadenceConfig)]
fun set_cadence_config_admission_tick_size_below_tick_size_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_template_cadence_config(
        &config,
        &admin_cap,
        UNDERLYING_BTC,
        market_manager::cadence_one_minute!(),
        BTC_TICK_SIZE,
        BELOW_TICK_SIZE_ADMISSION_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        BTC_INITIAL_EXPIRY_CASH,
        WINDOW_SIZE_THREE,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_manager::EInvalidCadenceConfig)]
fun set_cadence_config_admission_tick_size_not_multiple_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_template_cadence_config(
        &config,
        &admin_cap,
        UNDERLYING_BTC,
        market_manager::cadence_one_minute!(),
        BTC_TICK_SIZE,
        NON_MULTIPLE_ADMISSION_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        BTC_INITIAL_EXPIRY_CASH,
        WINDOW_SIZE_THREE,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = config_constants::EInvalidCadenceWindowSize)]
fun set_cadence_config_above_max_window_size_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_template_cadence_config(
        &config,
        &admin_cap,
        UNDERLYING_BTC,
        market_manager::cadence_one_minute!(),
        BTC_TICK_SIZE,
        BTC_ADMISSION_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        BTC_INITIAL_EXPIRY_CASH,
        ABOVE_MAX_CADENCE_WINDOW_SIZE,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_manager::EInvalidCadenceConfig)]
fun set_cadence_config_initial_cash_below_floor_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_template_cadence_config(
        &config,
        &admin_cap,
        UNDERLYING_BTC,
        market_manager::cadence_one_minute!(),
        BTC_TICK_SIZE,
        BTC_ADMISSION_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        BELOW_EXPIRY_CASH_FLOOR,
        WINDOW_SIZE_THREE,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_manager::EInvalidCadenceConfig)]
fun set_cadence_config_initial_cash_above_allocation_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_template_cadence_config(
        &config,
        &admin_cap,
        UNDERLYING_BTC,
        market_manager::cadence_one_minute!(),
        BTC_TICK_SIZE,
        BTC_ADMISSION_TICK_SIZE,
        BELOW_INITIAL_EXPIRY_CASH,
        BTC_INITIAL_EXPIRY_CASH,
        WINDOW_SIZE_THREE,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_manager::EInvalidCadenceConfig)]
fun set_cadence_config_partial_disable_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_template_cadence_config(
        &config,
        &admin_cap,
        UNDERLYING_BTC,
        market_manager::cadence_one_minute!(),
        DISABLED_VALUE,
        BTC_ADMISSION_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        BTC_INITIAL_EXPIRY_CASH,
        WINDOW_SIZE_THREE,
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_manager::EInvalidCadenceConfig)]
fun set_cadence_config_partial_disable_admission_tick_size_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.set_template_cadence_config(
        &config,
        &admin_cap,
        UNDERLYING_BTC,
        market_manager::cadence_one_minute!(),
        BTC_TICK_SIZE,
        DISABLED_VALUE,
        BTC_MAX_EXPIRY_ALLOCATION,
        BTC_INITIAL_EXPIRY_CASH,
        WINDOW_SIZE_THREE,
    );
    abort EUnexpectedSuccess
}

// === cadence_configs ===

fun assert_all_zero_disabled(cadence: &market_manager::CadenceConfig) {
    assert!(!cadence.cadence_enabled());
    assert_eq!(cadence.cadence_tick_size(), DISABLED_VALUE);
    assert_eq!(cadence.cadence_admission_tick_size(), DISABLED_VALUE);
    assert_eq!(cadence.cadence_max_expiry_allocation(), DISABLED_VALUE);
    assert_eq!(cadence.cadence_initial_expiry_cash(), DISABLED_VALUE);
    assert_eq!(cadence.cadence_window_size(), DISABLED_VALUE);
}

#[test]
fun cadence_configs_initial_all_disabled() {
    let (scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();
    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC);

    let configs = reg.cadence_configs(UNDERLYING_BTC);
    assert_eq!(configs.length(), SUPPORTED_CADENCE_COUNT);
    configs.do_ref!(|cadence| assert_all_zero_disabled(cadence));

    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

#[test]
fun cadence_configs_non_sequential_updates_round_trip() {
    let (scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();
    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC);

    // Update one-week (ID 4) before five-minute (ID 1): entries must land by
    // cadence ID, not by update order.
    reg.set_template_cadence_config(
        &config,
        &admin_cap,
        UNDERLYING_BTC,
        market_manager::cadence_one_week!(),
        ETH_TICK_SIZE,
        ETH_ADMISSION_TICK_SIZE,
        ETH_MAX_EXPIRY_ALLOCATION,
        ETH_INITIAL_EXPIRY_CASH,
        WINDOW_SIZE_TWO,
    );
    reg.set_template_cadence_config(
        &config,
        &admin_cap,
        UNDERLYING_BTC,
        market_manager::cadence_five_minute!(),
        BTC_TICK_SIZE,
        BTC_ADMISSION_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        BTC_INITIAL_EXPIRY_CASH,
        WINDOW_SIZE_THREE,
    );

    let configs = reg.cadence_configs(UNDERLYING_BTC);
    assert_eq!(configs.length(), SUPPORTED_CADENCE_COUNT);

    let five_minute = &configs[market_manager::cadence_five_minute!() as u64];
    assert!(five_minute.cadence_enabled());
    assert_eq!(five_minute.cadence_tick_size(), BTC_TICK_SIZE);
    assert_eq!(five_minute.cadence_admission_tick_size(), BTC_ADMISSION_TICK_SIZE);
    assert_eq!(five_minute.cadence_max_expiry_allocation(), BTC_MAX_EXPIRY_ALLOCATION);
    assert_eq!(five_minute.cadence_initial_expiry_cash(), BTC_INITIAL_EXPIRY_CASH);
    assert_eq!(five_minute.cadence_window_size(), WINDOW_SIZE_THREE);

    let one_week = &configs[market_manager::cadence_one_week!() as u64];
    assert!(one_week.cadence_enabled());
    assert_eq!(one_week.cadence_tick_size(), ETH_TICK_SIZE);
    assert_eq!(one_week.cadence_admission_tick_size(), ETH_ADMISSION_TICK_SIZE);
    assert_eq!(one_week.cadence_max_expiry_allocation(), ETH_MAX_EXPIRY_ALLOCATION);
    assert_eq!(one_week.cadence_initial_expiry_cash(), ETH_INITIAL_EXPIRY_CASH);
    assert_eq!(one_week.cadence_window_size(), WINDOW_SIZE_TWO);

    assert_all_zero_disabled(&configs[market_manager::cadence_one_minute!() as u64]);
    assert_all_zero_disabled(&configs[market_manager::cadence_one_hour!() as u64]);
    assert_all_zero_disabled(&configs[market_manager::cadence_one_day!() as u64]);
    assert_all_zero_disabled(&configs[market_manager::cadence_one_month!() as u64]);

    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

#[test]
fun cadence_configs_disable_round_trip() {
    let (scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();
    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC);

    reg.set_template_cadence_config(
        &config,
        &admin_cap,
        UNDERLYING_BTC,
        market_manager::cadence_five_minute!(),
        BTC_TICK_SIZE,
        BTC_ADMISSION_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        BTC_INITIAL_EXPIRY_CASH,
        WINDOW_SIZE_THREE,
    );
    let enabled_configs = reg.cadence_configs(UNDERLYING_BTC);
    assert!(enabled_configs[market_manager::cadence_five_minute!() as u64].cadence_enabled());
    reg.set_template_cadence_config(
        &config,
        &admin_cap,
        UNDERLYING_BTC,
        market_manager::cadence_five_minute!(),
        DISABLED_VALUE,
        DISABLED_VALUE,
        DISABLED_VALUE,
        DISABLED_VALUE,
        DISABLED_VALUE,
    );

    let configs = reg.cadence_configs(UNDERLYING_BTC);
    assert_eq!(configs.length(), SUPPORTED_CADENCE_COUNT);
    assert_all_zero_disabled(&configs[market_manager::cadence_five_minute!() as u64]);

    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

#[test]
fun cadence_configs_two_underlyings_isolated() {
    let (scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();
    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC);
    reg.register_underlying(&config, &admin_cap, UNDERLYING_ETH);

    // Same cadence ID, different values per underlying: a cross-underlying mixup
    // would surface as the wrong value set.
    reg.set_template_cadence_config(
        &config,
        &admin_cap,
        UNDERLYING_BTC,
        market_manager::cadence_five_minute!(),
        BTC_TICK_SIZE,
        BTC_ADMISSION_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        BTC_INITIAL_EXPIRY_CASH,
        WINDOW_SIZE_THREE,
    );
    reg.set_template_cadence_config(
        &config,
        &admin_cap,
        UNDERLYING_ETH,
        market_manager::cadence_five_minute!(),
        ETH_TICK_SIZE,
        ETH_ADMISSION_TICK_SIZE,
        ETH_MAX_EXPIRY_ALLOCATION,
        ETH_INITIAL_EXPIRY_CASH,
        WINDOW_SIZE_TWO,
    );

    let btc_configs = reg.cadence_configs(UNDERLYING_BTC);
    let btc_five_minute = &btc_configs[market_manager::cadence_five_minute!() as u64];
    assert_eq!(btc_five_minute.cadence_tick_size(), BTC_TICK_SIZE);
    assert_eq!(btc_five_minute.cadence_window_size(), WINDOW_SIZE_THREE);

    let eth_configs = reg.cadence_configs(UNDERLYING_ETH);
    let eth_five_minute = &eth_configs[market_manager::cadence_five_minute!() as u64];
    assert_eq!(eth_five_minute.cadence_tick_size(), ETH_TICK_SIZE);
    assert_eq!(eth_five_minute.cadence_window_size(), WINDOW_SIZE_TWO);

    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

#[test, expected_failure(abort_code = market_manager::EUnderlyingNotRegistered)]
fun cadence_configs_unregistered_underlying_aborts() {
    let (_scenario, reg, config, admin_cap) = test_helpers::begin_registry_test();

    let _configs = reg.cadence_configs(UNDERLYING_BTC);
    abort EUnexpectedSuccess
}
