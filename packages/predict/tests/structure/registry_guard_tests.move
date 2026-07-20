// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Structural guards for underlying and cadence configuration.
#[test_only]
module deepbook_predict::scope_structure__intent_guard__registry_tests;

use deepbook_predict::{config_constants, market_manager, test_values, test_world};
use sui::test_scenario::return_shared;

#[test, expected_failure(abort_code = market_manager::EUnderlyingAlreadyRegistered)]
fun duplicate_underlying_registration_aborts() {
    let (world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let config = test_world::take_config(&world);
    registry.register_underlying(&config, &admin_cap, test_values::propbook_underlying_id());
    registry.register_underlying(&config, &admin_cap, test_values::propbook_underlying_id());
    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
    abort 999
}

#[test, expected_failure(abort_code = market_manager::EUnderlyingNotRegistered)]
fun cadence_configuration_requires_registered_underlying() {
    let (world, resources) = test_world::new(
        test_values::system(),
        test_values::admin(),
        test_values::now_ms(),
    );
    let admin_cap = test_world::take_predict_admin_cap(&world);
    let mut registry = test_world::take_registry(&world);
    let config = test_world::take_config(&world);
    registry.set_template_cadence_config(
        &config,
        &admin_cap,
        test_values::propbook_underlying_id(),
        test_values::cadence_id(),
        test_values::tick_size(),
        test_values::admission_tick_size(),
        test_values::max_expiry_allocation(),
        test_values::initial_expiry_cash(),
        test_values::cadence_window_size(),
    );
    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
    abort 999
}

#[test, expected_failure(abort_code = market_manager::EInvalidCadenceConfig)]
fun partially_zero_cadence_configuration_aborts() {
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
        test_values::tick_size(),
        test_values::admission_tick_size(),
        test_values::max_expiry_allocation(),
        test_values::initial_expiry_cash(),
        0,
    );
    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
    abort 999
}

#[test, expected_failure(abort_code = market_manager::EInvalidCadence)]
fun cadence_id_above_the_fixed_domain_aborts() {
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
        6,
        0,
        0,
        0,
        0,
        0,
    );
    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidCadenceWindowSize)]
fun cadence_window_above_the_policy_maximum_aborts() {
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
        test_values::tick_size(),
        test_values::admission_tick_size(),
        test_values::max_expiry_allocation(),
        test_values::initial_expiry_cash(),
        11,
    );
    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EMarketTickSizeTooLarge)]
fun cadence_admission_tick_above_the_finite_strike_headroom_aborts() {
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
        test_values::tick_size(),
        20_000_000_000,
        test_values::max_expiry_allocation(),
        test_values::initial_expiry_cash(),
        1,
    );
    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
    abort 999
}

#[test, expected_failure(abort_code = market_manager::EInvalidCadenceConfig)]
fun initial_cash_above_maximum_allocation_aborts() {
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
        test_values::tick_size(),
        test_values::admission_tick_size(),
        test_values::initial_expiry_cash() - 1,
        test_values::initial_expiry_cash(),
        1,
    );
    return_shared(config);
    return_shared(registry);
    test_world::return_predict_admin_cap(&world, admin_cap);
    test_world::finish(world, resources);
    abort 999
}
