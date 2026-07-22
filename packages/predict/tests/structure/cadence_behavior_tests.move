// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Structural coverage for Registry-owned cadence configuration and public projections.
#[test_only]
module deepbook_predict::scope_structure__intent_behavior__cadence_tests;

use deepbook_predict::{market_manager, test_values, test_world};
use std::unit_test::assert_eq;
use sui::test_scenario::return_shared;

const DISTINCT_TICK_SIZE: u64 = 500_000_000;
const DISTINCT_ADMISSION_TICK_SIZE: u64 = 5_000_000_000;
const DISTINCT_MAX_ALLOCATION: u64 = 333_000_000_000;
const DISTINCT_INITIAL_CASH: u64 = 44_000_000_000;
const DISTINCT_WINDOW: u64 = 3;
// A second registered underlying for cross-underlying isolation, distinct
// from test_values::propbook_underlying_id().
const SECOND_UNDERLYING: u32 = 200;
const SECOND_WINDOW: u64 = 2;
// The fixed cadence domain has six IDs; the enumerated snapshot is indexed by
// cadence ID with disabled entries present as all-zero configuration.
const SUPPORTED_CADENCE_COUNT: u64 = 6;
const DISABLED_VALUE: u64 = 0;

#[test]
fun configured_cadence_projects_every_stored_term() {
    let (world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let config = test_world::take_config(&world);
    registry.register_underlying(&config, &admin_cap, test_values::propbook_underlying_id());
    registry.set_template_cadence_config(
        &config,
        &admin_cap,
        test_values::propbook_underlying_id(),
        test_values::cadence_id(),
        DISTINCT_TICK_SIZE,
        DISTINCT_ADMISSION_TICK_SIZE,
        DISTINCT_MAX_ALLOCATION,
        DISTINCT_INITIAL_CASH,
        DISTINCT_WINDOW,
    );

    let cadence = registry.cadence_config(
        test_values::propbook_underlying_id(),
        test_values::cadence_id(),
    );
    assert_eq!(market_manager::cadence_tick_size(&cadence), DISTINCT_TICK_SIZE);
    assert_eq!(market_manager::cadence_admission_tick_size(&cadence), DISTINCT_ADMISSION_TICK_SIZE);
    assert_eq!(market_manager::cadence_max_expiry_allocation(&cadence), DISTINCT_MAX_ALLOCATION);
    assert_eq!(market_manager::cadence_initial_expiry_cash(&cadence), DISTINCT_INITIAL_CASH);
    assert_eq!(market_manager::cadence_window_size(&cadence), DISTINCT_WINDOW);
    assert!(market_manager::cadence_enabled(&cadence));

    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
}

#[test]
fun all_zero_cadence_projects_as_disabled() {
    let (world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let config = test_world::take_config(&world);
    registry.register_underlying(&config, &admin_cap, test_values::propbook_underlying_id());
    registry.set_template_cadence_config(
        &config,
        &admin_cap,
        test_values::propbook_underlying_id(),
        market_manager::cadence_five_minute!(),
        test_values::tick_size(),
        test_values::admission_tick_size(),
        test_values::max_expiry_allocation(),
        test_values::initial_expiry_cash(),
        test_values::cadence_window_size(),
    );
    registry.set_template_cadence_config(
        &config,
        &admin_cap,
        test_values::propbook_underlying_id(),
        market_manager::cadence_five_minute!(),
        0,
        0,
        0,
        0,
        0,
    );

    let cadence = registry.cadence_config(
        test_values::propbook_underlying_id(),
        market_manager::cadence_five_minute!(),
    );
    assert_eq!(market_manager::cadence_tick_size(&cadence), 0);
    assert_eq!(market_manager::cadence_admission_tick_size(&cadence), 0);
    assert_eq!(market_manager::cadence_max_expiry_allocation(&cadence), 0);
    assert_eq!(market_manager::cadence_initial_expiry_cash(&cadence), 0);
    assert_eq!(market_manager::cadence_window_size(&cadence), 0);
    assert!(!market_manager::cadence_enabled(&cadence));

    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
}

fun assert_all_zero_disabled(cadence: &market_manager::CadenceConfig) {
    assert!(!market_manager::cadence_enabled(cadence));
    assert_eq!(market_manager::cadence_tick_size(cadence), DISABLED_VALUE);
    assert_eq!(market_manager::cadence_admission_tick_size(cadence), DISABLED_VALUE);
    assert_eq!(market_manager::cadence_max_expiry_allocation(cadence), DISABLED_VALUE);
    assert_eq!(market_manager::cadence_initial_expiry_cash(cadence), DISABLED_VALUE);
    assert_eq!(market_manager::cadence_window_size(cadence), DISABLED_VALUE);
}

#[test]
fun fresh_underlying_enumerates_all_cadences_disabled() {
    let (world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let config = test_world::take_config(&world);
    registry.register_underlying(&config, &admin_cap, test_values::propbook_underlying_id());

    let configs = registry.cadence_configs(test_values::propbook_underlying_id());
    assert_eq!(configs.length(), SUPPORTED_CADENCE_COUNT);
    configs.do_ref!(|cadence| assert_all_zero_disabled(cadence));

    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
}

#[test]
fun non_sequential_updates_enumerate_by_cadence_id() {
    let (world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let config = test_world::take_config(&world);
    registry.register_underlying(&config, &admin_cap, test_values::propbook_underlying_id());
    // Update one-week before five-minute: entries must land by cadence ID,
    // not by update order.
    registry.set_template_cadence_config(
        &config,
        &admin_cap,
        test_values::propbook_underlying_id(),
        market_manager::cadence_one_week!(),
        test_values::tick_size(),
        test_values::admission_tick_size(),
        test_values::max_expiry_allocation(),
        test_values::initial_expiry_cash(),
        SECOND_WINDOW,
    );
    registry.set_template_cadence_config(
        &config,
        &admin_cap,
        test_values::propbook_underlying_id(),
        market_manager::cadence_five_minute!(),
        DISTINCT_TICK_SIZE,
        DISTINCT_ADMISSION_TICK_SIZE,
        DISTINCT_MAX_ALLOCATION,
        DISTINCT_INITIAL_CASH,
        DISTINCT_WINDOW,
    );

    let configs = registry.cadence_configs(test_values::propbook_underlying_id());
    assert_eq!(configs.length(), SUPPORTED_CADENCE_COUNT);

    let five_minute = &configs[market_manager::cadence_five_minute!() as u64];
    assert!(market_manager::cadence_enabled(five_minute));
    assert_eq!(market_manager::cadence_tick_size(five_minute), DISTINCT_TICK_SIZE);
    assert_eq!(
        market_manager::cadence_admission_tick_size(five_minute),
        DISTINCT_ADMISSION_TICK_SIZE,
    );
    assert_eq!(market_manager::cadence_max_expiry_allocation(five_minute), DISTINCT_MAX_ALLOCATION);
    assert_eq!(market_manager::cadence_initial_expiry_cash(five_minute), DISTINCT_INITIAL_CASH);
    assert_eq!(market_manager::cadence_window_size(five_minute), DISTINCT_WINDOW);

    let one_week = &configs[market_manager::cadence_one_week!() as u64];
    assert!(market_manager::cadence_enabled(one_week));
    assert_eq!(market_manager::cadence_tick_size(one_week), test_values::tick_size());
    assert_eq!(
        market_manager::cadence_admission_tick_size(one_week),
        test_values::admission_tick_size(),
    );
    assert_eq!(
        market_manager::cadence_max_expiry_allocation(one_week),
        test_values::max_expiry_allocation(),
    );
    assert_eq!(
        market_manager::cadence_initial_expiry_cash(one_week),
        test_values::initial_expiry_cash(),
    );
    assert_eq!(market_manager::cadence_window_size(one_week), SECOND_WINDOW);

    assert_all_zero_disabled(&configs[market_manager::cadence_one_minute!() as u64]);
    assert_all_zero_disabled(&configs[market_manager::cadence_one_hour!() as u64]);
    assert_all_zero_disabled(&configs[market_manager::cadence_one_day!() as u64]);
    assert_all_zero_disabled(&configs[market_manager::cadence_one_month!() as u64]);

    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
}

#[test]
fun disabled_cadence_enumerates_all_zero() {
    let (world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let config = test_world::take_config(&world);
    registry.register_underlying(&config, &admin_cap, test_values::propbook_underlying_id());
    registry.set_template_cadence_config(
        &config,
        &admin_cap,
        test_values::propbook_underlying_id(),
        market_manager::cadence_five_minute!(),
        test_values::tick_size(),
        test_values::admission_tick_size(),
        test_values::max_expiry_allocation(),
        test_values::initial_expiry_cash(),
        test_values::cadence_window_size(),
    );
    let enabled_configs = registry.cadence_configs(test_values::propbook_underlying_id());
    assert!(
        market_manager::cadence_enabled(
            &enabled_configs[market_manager::cadence_five_minute!() as u64],
        ),
    );
    registry.set_template_cadence_config(
        &config,
        &admin_cap,
        test_values::propbook_underlying_id(),
        market_manager::cadence_five_minute!(),
        DISABLED_VALUE,
        DISABLED_VALUE,
        DISABLED_VALUE,
        DISABLED_VALUE,
        DISABLED_VALUE,
    );

    let configs = registry.cadence_configs(test_values::propbook_underlying_id());
    assert_eq!(configs.length(), SUPPORTED_CADENCE_COUNT);
    assert_all_zero_disabled(&configs[market_manager::cadence_five_minute!() as u64]);

    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
}

#[test]
fun two_underlyings_enumerate_isolated_cadences() {
    let (world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );

    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let config = test_world::take_config(&world);
    registry.register_underlying(&config, &admin_cap, test_values::propbook_underlying_id());
    registry.register_underlying(&config, &admin_cap, SECOND_UNDERLYING);
    // Same cadence ID, different values per underlying: a cross-underlying
    // mixup would surface as the wrong value set.
    registry.set_template_cadence_config(
        &config,
        &admin_cap,
        test_values::propbook_underlying_id(),
        market_manager::cadence_five_minute!(),
        DISTINCT_TICK_SIZE,
        DISTINCT_ADMISSION_TICK_SIZE,
        DISTINCT_MAX_ALLOCATION,
        DISTINCT_INITIAL_CASH,
        DISTINCT_WINDOW,
    );
    registry.set_template_cadence_config(
        &config,
        &admin_cap,
        SECOND_UNDERLYING,
        market_manager::cadence_five_minute!(),
        test_values::tick_size(),
        test_values::admission_tick_size(),
        test_values::max_expiry_allocation(),
        test_values::initial_expiry_cash(),
        SECOND_WINDOW,
    );

    let first_configs = registry.cadence_configs(test_values::propbook_underlying_id());
    let first_five_minute = &first_configs[market_manager::cadence_five_minute!() as u64];
    assert_eq!(market_manager::cadence_tick_size(first_five_minute), DISTINCT_TICK_SIZE);
    assert_eq!(market_manager::cadence_window_size(first_five_minute), DISTINCT_WINDOW);

    let second_configs = registry.cadence_configs(SECOND_UNDERLYING);
    let second_five_minute = &second_configs[market_manager::cadence_five_minute!() as u64];
    assert_eq!(market_manager::cadence_tick_size(second_five_minute), test_values::tick_size());
    assert_eq!(market_manager::cadence_window_size(second_five_minute), SECOND_WINDOW);

    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
}
