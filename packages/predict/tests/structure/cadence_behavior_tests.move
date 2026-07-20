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
