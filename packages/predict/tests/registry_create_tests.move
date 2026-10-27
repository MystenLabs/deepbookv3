// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::registry_create_tests;

use deepbook_predict::{config_constants, config_events::CadenceAdded, market_manager, test_helpers};
use std::unit_test::{assert_eq, destroy};
use sui::event;

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
const BELOW_EXPIRY_CASH_FLOOR: u64 = 999_999_999;
const MINIMUM_EXPIRY_CASH: u64 = 1_000_000_000;
const SMALL_EXPIRY_CASH: u64 = 2_000_000_000;
const BELOW_INITIAL_EXPIRY_CASH: u64 = BTC_INITIAL_EXPIRY_CASH - 1;

// Cadence periods in milliseconds, written out by hand (1 minute = 60,000 ms) so the
// expected table does not reuse the contract's time constants.
const ONE_MINUTE_MS: u64 = 60_000;
const FIVE_MINUTES_MS: u64 = 300_000;
const FIFTEEN_MINUTES_MS: u64 = 900_000;
const ONE_HOUR_MS: u64 = 3_600_000;
const ONE_DAY_MS: u64 = 86_400_000;
const ONE_WEEK_MS: u64 = 604_800_000;
const THIRTY_DAYS_MS: u64 = 2_592_000_000;
// 365 days, the longest period `add_cadence` accepts.
const ONE_YEAR_MS: u64 = 31_536_000_000;
// 90 seconds: not a whole number of minutes.
const NINETY_SECONDS_MS: u64 = 90_000;
const BUILTIN_CADENCE_COUNT: u64 = 6;
const MAX_CADENCES: u64 = 16;
const FIRST_ADDED_CADENCE_ID: u8 = 6;
const WINDOW_SIZE_TEN: u64 = 10;
const WINDOW_SIZE_FOUR: u64 = 4;
const WINDOW_SIZE_ONE: u64 = 1;
// Window sums for `win_sum_ok`: the cap is 24 live markets.
const WINDOW_CAP: u64 = 24;
const LEGACY_OVER_CAP_SUM: u64 = 40;
const REDUCED_OVER_CAP_SUM: u64 = 30;

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

#[test]
fun set_cadence_config_accepts_1000_and_2000_usdc_targets() {
    let (scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();
    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC);
    vector[MINIMUM_EXPIRY_CASH, SMALL_EXPIRY_CASH].do!(|target| {
        reg.set_template_cadence_config(
            &config,
            &admin_cap,
            UNDERLYING_BTC,
            market_manager::cadence_one_minute!(),
            BTC_TICK_SIZE,
            BTC_ADMISSION_TICK_SIZE,
            target,
            target,
            WINDOW_SIZE_TWO,
        );
        let cadence = reg.cadence_config(UNDERLYING_BTC, market_manager::cadence_one_minute!());
        assert!(cadence.cadence_enabled());
        assert_eq!(cadence.cadence_initial_expiry_cash(), target);
        assert_eq!(cadence.cadence_max_expiry_allocation(), target);
    });
    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

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
    let (_scenario, reg, _config, _admin_cap) = test_helpers::begin_registry_test();

    let _configs = reg.cadence_configs(UNDERLYING_BTC);
    abort EUnexpectedSuccess
}

// === cadence table ===

#[test]
fun cadence_periods_start_with_the_six_builtins() {
    let (scenario, reg, config, admin_cap) = test_helpers::begin_registry_test();

    assert_eq!(
        reg.cadence_periods(),
        vector[
            ONE_MINUTE_MS,
            FIVE_MINUTES_MS,
            ONE_HOUR_MS,
            ONE_DAY_MS,
            ONE_WEEK_MS,
            THIRTY_DAYS_MS,
        ],
    );

    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

#[test]
fun add_cadence_appends_period_and_emits_event() {
    let (scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    let cadence_id = reg.add_cadence(&config, &admin_cap, FIFTEEN_MINUTES_MS);

    assert_eq!(cadence_id, FIRST_ADDED_CADENCE_ID);
    let periods = reg.cadence_periods();
    assert_eq!(periods.length(), BUILTIN_CADENCE_COUNT + 1);
    assert_eq!(periods[FIRST_ADDED_CADENCE_ID as u64], FIFTEEN_MINUTES_MS);
    assert_eq!(periods[market_manager::cadence_five_minute!() as u64], FIVE_MINUTES_MS);
    assert_eq!(event::events_by_type<CadenceAdded>().length(), 1);

    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

#[test]
fun add_cadence_extends_rows_of_an_existing_underlying_as_disabled() {
    let (scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();
    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC);

    let cadence_id = reg.add_cadence(&config, &admin_cap, FIFTEEN_MINUTES_MS);

    let configs = reg.cadence_configs(UNDERLYING_BTC);
    assert_eq!(configs.length(), BUILTIN_CADENCE_COUNT + 1);
    configs.do_ref!(|cadence| assert_all_zero_disabled(cadence));
    assert_all_zero_disabled(&reg.cadence_config(UNDERLYING_BTC, cadence_id));

    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

#[test]
fun register_underlying_after_add_cadence_covers_the_whole_table() {
    let (scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();
    reg.add_cadence(&config, &admin_cap, FIFTEEN_MINUTES_MS);

    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC);

    let configs = reg.cadence_configs(UNDERLYING_BTC);
    assert_eq!(configs.length(), BUILTIN_CADENCE_COUNT + 1);
    configs.do_ref!(|cadence| assert_all_zero_disabled(cadence));

    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

#[test]
fun set_cadence_config_on_added_cadence_round_trips() {
    let (scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();
    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC);
    let cadence_id = reg.add_cadence(&config, &admin_cap, FIFTEEN_MINUTES_MS);

    reg.set_template_cadence_config(
        &config,
        &admin_cap,
        UNDERLYING_BTC,
        cadence_id,
        BTC_TICK_SIZE,
        BTC_ADMISSION_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        BTC_INITIAL_EXPIRY_CASH,
        WINDOW_SIZE_TWO,
    );

    let fifteen = &reg.cadence_configs(UNDERLYING_BTC)[cadence_id as u64];
    assert!(fifteen.cadence_enabled());
    assert_eq!(fifteen.cadence_tick_size(), BTC_TICK_SIZE);
    assert_eq!(fifteen.cadence_admission_tick_size(), BTC_ADMISSION_TICK_SIZE);
    assert_eq!(fifteen.cadence_max_expiry_allocation(), BTC_MAX_EXPIRY_ALLOCATION);
    assert_eq!(fifteen.cadence_initial_expiry_cash(), BTC_INITIAL_EXPIRY_CASH);
    assert_eq!(fifteen.cadence_window_size(), WINDOW_SIZE_TWO);
    assert_all_zero_disabled(
        &reg.cadence_config(UNDERLYING_BTC, market_manager::cadence_five_minute!()),
    );

    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

#[test, expected_failure(abort_code = market_manager::EInvalidCadence)]
fun set_cadence_config_id_past_the_table_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();
    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC);
    let cadence_id = reg.add_cadence(&config, &admin_cap, FIFTEEN_MINUTES_MS);

    reg.set_template_cadence_config(
        &config,
        &admin_cap,
        UNDERLYING_BTC,
        cadence_id + 1,
        BTC_TICK_SIZE,
        BTC_ADMISSION_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        BTC_INITIAL_EXPIRY_CASH,
        WINDOW_SIZE_TWO,
    );
    abort EUnexpectedSuccess
}

#[test]
fun add_cadence_accepts_one_minute_multiples_up_to_one_year() {
    let (scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.add_cadence(&config, &admin_cap, 2 * ONE_MINUTE_MS);
    reg.add_cadence(&config, &admin_cap, ONE_YEAR_MS);

    let periods = reg.cadence_periods();
    assert_eq!(periods[BUILTIN_CADENCE_COUNT], 2 * ONE_MINUTE_MS);
    assert_eq!(periods[BUILTIN_CADENCE_COUNT + 1], ONE_YEAR_MS);

    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

#[test, expected_failure(abort_code = market_manager::EInvalidCadencePeriod)]
fun add_cadence_zero_period_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.add_cadence(&config, &admin_cap, DISABLED_VALUE);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_manager::EInvalidCadencePeriod)]
fun add_cadence_period_off_the_minute_grid_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.add_cadence(&config, &admin_cap, NINETY_SECONDS_MS);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_manager::EInvalidCadencePeriod)]
fun add_cadence_period_above_one_year_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.add_cadence(&config, &admin_cap, ONE_YEAR_MS + ONE_MINUTE_MS);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_manager::ECadencePeriodExists)]
fun add_cadence_builtin_period_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.add_cadence(&config, &admin_cap, FIVE_MINUTES_MS);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = market_manager::ECadencePeriodExists)]
fun add_cadence_same_period_twice_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    reg.add_cadence(&config, &admin_cap, FIFTEEN_MINUTES_MS);
    reg.add_cadence(&config, &admin_cap, FIFTEEN_MINUTES_MS);
    abort EUnexpectedSuccess
}

#[test]
fun add_cadence_fills_the_table_to_sixteen() {
    let (scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();

    add_ten_cadences(&mut reg, &config, &admin_cap);

    let periods = reg.cadence_periods();
    assert_eq!(periods.length(), MAX_CADENCES);
    assert_eq!(periods[MAX_CADENCES - 1], 12 * ONE_MINUTE_MS);

    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

#[test, expected_failure(abort_code = market_manager::ECadenceTableFull)]
fun add_cadence_past_sixteen_aborts() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();
    add_ten_cadences(&mut reg, &config, &admin_cap);

    reg.add_cadence(&config, &admin_cap, 13 * ONE_MINUTE_MS);
    abort EUnexpectedSuccess
}

#[test]
fun set_cadence_config_windows_may_sum_to_the_live_market_cap() {
    let (scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();
    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC);

    // 10 + 10 + 4 = 24, the pool's live-market cap.
    set_btc_window(
        &mut reg,
        &config,
        &admin_cap,
        market_manager::cadence_one_minute!(),
        WINDOW_SIZE_TEN,
    );
    set_btc_window(
        &mut reg,
        &config,
        &admin_cap,
        market_manager::cadence_five_minute!(),
        WINDOW_SIZE_TEN,
    );
    set_btc_window(
        &mut reg,
        &config,
        &admin_cap,
        market_manager::cadence_one_hour!(),
        WINDOW_SIZE_FOUR,
    );
    // Re-setting a cadence replaces its window rather than adding to it.
    set_btc_window(
        &mut reg,
        &config,
        &admin_cap,
        market_manager::cadence_one_hour!(),
        WINDOW_SIZE_FOUR,
    );

    let configs = reg.cadence_configs(UNDERLYING_BTC);
    assert_eq!(
        configs[market_manager::cadence_one_minute!() as u64].cadence_window_size(),
        WINDOW_SIZE_TEN,
    );
    assert_eq!(
        configs[market_manager::cadence_five_minute!() as u64].cadence_window_size(),
        WINDOW_SIZE_TEN,
    );
    assert_eq!(
        configs[market_manager::cadence_one_hour!() as u64].cadence_window_size(),
        WINDOW_SIZE_FOUR,
    );

    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

#[test, expected_failure(abort_code = market_manager::ECadenceWindowBudgetExceeded)]
fun set_cadence_config_windows_past_the_live_market_cap_abort() {
    let (_scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();
    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC);
    set_btc_window(
        &mut reg,
        &config,
        &admin_cap,
        market_manager::cadence_one_minute!(),
        WINDOW_SIZE_TEN,
    );
    set_btc_window(
        &mut reg,
        &config,
        &admin_cap,
        market_manager::cadence_five_minute!(),
        WINDOW_SIZE_TEN,
    );
    set_btc_window(
        &mut reg,
        &config,
        &admin_cap,
        market_manager::cadence_one_hour!(),
        WINDOW_SIZE_FOUR,
    );

    // 24 + 1 = 25.
    set_btc_window(
        &mut reg,
        &config,
        &admin_cap,
        market_manager::cadence_one_day!(),
        WINDOW_SIZE_ONE,
    );
    abort EUnexpectedSuccess
}

#[test]
fun set_cadence_config_window_budget_is_per_underlying() {
    let (scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();
    reg.register_underlying(&config, &admin_cap, UNDERLYING_BTC);
    reg.register_underlying(&config, &admin_cap, UNDERLYING_ETH);
    set_btc_window(
        &mut reg,
        &config,
        &admin_cap,
        market_manager::cadence_one_minute!(),
        WINDOW_SIZE_TEN,
    );
    set_btc_window(
        &mut reg,
        &config,
        &admin_cap,
        market_manager::cadence_five_minute!(),
        WINDOW_SIZE_TEN,
    );
    set_btc_window(
        &mut reg,
        &config,
        &admin_cap,
        market_manager::cadence_one_hour!(),
        WINDOW_SIZE_FOUR,
    );

    // ETH's own sum starts at zero, so a full window on ETH is accepted.
    reg.set_template_cadence_config(
        &config,
        &admin_cap,
        UNDERLYING_ETH,
        market_manager::cadence_one_minute!(),
        ETH_TICK_SIZE,
        ETH_ADMISSION_TICK_SIZE,
        ETH_MAX_EXPIRY_ALLOCATION,
        ETH_INITIAL_EXPIRY_CASH,
        WINDOW_SIZE_TEN,
    );

    let eth_one_minute = reg.cadence_config(UNDERLYING_ETH, market_manager::cadence_one_minute!());
    assert_eq!(eth_one_minute.cadence_window_size(), WINDOW_SIZE_TEN);

    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

// === stored rows and old package versions ===

#[test]
fun builtin_terms_after_add_cadence_keep_six_stored_rows() {
    let mut ctx = tx_context::dummy();
    let mut manager = market_manager::new(&mut ctx);
    let mut periods = market_manager::base_periods();
    manager.register_underlying(UNDERLYING_BTC);
    let fifteen = market_manager::add_period(&mut periods, FIFTEEN_MINUTES_MS);

    // Writing a built-in cadence leaves the rows at six, so package versions from
    // before the cadence table keep creating built-in markets.
    set_manager_window(
        &mut manager,
        &periods,
        market_manager::cadence_one_minute!(),
        WINDOW_SIZE_TWO,
    );
    assert_eq!(manager.stored_rows_for_testing(UNDERLYING_BTC), BUILTIN_CADENCE_COUNT);

    // Enabling the added cadence is what extends them.
    set_manager_window(&mut manager, &periods, fifteen, WINDOW_SIZE_TWO);
    assert_eq!(manager.stored_rows_for_testing(UNDERLYING_BTC), BUILTIN_CADENCE_COUNT + 1);

    destroy(manager);
}

#[test]
fun register_underlying_after_add_cadence_stores_six_rows() {
    let (scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();
    reg.add_cadence(&config, &admin_cap, FIFTEEN_MINUTES_MS);
    let mut ctx = tx_context::dummy();
    let mut manager = market_manager::new(&mut ctx);

    manager.register_underlying(UNDERLYING_BTC);

    assert_eq!(manager.stored_rows_for_testing(UNDERLYING_BTC), BUILTIN_CADENCE_COUNT);
    destroy(manager);
    test_helpers::finish_registry_test(scenario, reg, config, admin_cap);
}

// === window budget predicate ===

#[test]
fun window_budget_allows_sums_up_to_the_cap_and_any_non_increase() {
    assert!(market_manager::win_sum_ok(DISABLED_VALUE, WINDOW_CAP));
    assert!(!market_manager::win_sum_ok(WINDOW_CAP, WINDOW_CAP + 1));
    // A sum set over the cap before the check existed may shrink or stay, but not grow.
    assert!(market_manager::win_sum_ok(LEGACY_OVER_CAP_SUM, REDUCED_OVER_CAP_SUM));
    assert!(market_manager::win_sum_ok(LEGACY_OVER_CAP_SUM, LEGACY_OVER_CAP_SUM));
    assert!(!market_manager::win_sum_ok(REDUCED_OVER_CAP_SUM, REDUCED_OVER_CAP_SUM + 1));
}

fun set_manager_window(
    manager: &mut market_manager::MarketManager,
    periods: &vector<u64>,
    cadence_id: u8,
    window_size: u64,
) {
    manager.set_template_cadence_config(
        periods,
        UNDERLYING_BTC,
        cadence_id,
        BTC_TICK_SIZE,
        BTC_ADMISSION_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        BTC_INITIAL_EXPIRY_CASH,
        window_size,
    );
}

fun set_btc_window(
    reg: &mut deepbook_predict::registry::Registry,
    config: &deepbook_predict::protocol_config::ProtocolConfig,
    admin_cap: &deepbook_predict::admin::AdminCap,
    cadence_id: u8,
    window_size: u64,
) {
    reg.set_template_cadence_config(
        config,
        admin_cap,
        UNDERLYING_BTC,
        cadence_id,
        BTC_TICK_SIZE,
        BTC_ADMISSION_TICK_SIZE,
        BTC_MAX_EXPIRY_ALLOCATION,
        BTC_INITIAL_EXPIRY_CASH,
        window_size,
    );
}

/// Add ten cadences, 2 to 12 minutes without the built-in 5 minutes, taking IDs
/// 6 to 15 and filling the 16-entry table.
fun add_ten_cadences(
    reg: &mut deepbook_predict::registry::Registry,
    config: &deepbook_predict::protocol_config::ProtocolConfig,
    admin_cap: &deepbook_predict::admin::AdminCap,
) {
    vector[2, 3, 4, 6, 7, 8, 9, 10, 11, 12].do!(|minutes| {
        reg.add_cadence(config, admin_cap, minutes * ONE_MINUTE_MS);
    });
}
