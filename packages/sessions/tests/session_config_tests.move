// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_sessions::session_config_tests;

use deepbook_sessions::session_config::{
    Self,
    SessionPoolAllowed,
    SessionPoolDisallowed,
    SessionsAdminCap,
    SessionsConfig,
};
use std::unit_test::{assert_eq, destroy};
use sui::{event, test_scenario::{Self as test, Scenario, return_shared}, vec_set};

const ADMIN: address = @0xAD;
const OLDER_VERSION: u64 = 3; // The Mainnet v3 floor this upgrade retires.
const CURRENT_VERSION: u64 = 4;
const FUTURE_VERSION: u64 = 5;
const POOL_A: address = @0xB00A;
const POOL_B: address = @0xB00B;
const POOL_C: address = @0xB00C;
const EUnexpectedSuccess: u64 = 999;

#[test]
fun config_initializes_at_the_current_version() {
    let mut scenario = test::begin(ADMIN);
    let (config_id, admin_cap) = session_config::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    let config = scenario.take_shared_by_id<SessionsConfig>(config_id);

    assert_eq!(config.id(), config_id);
    assert_eq!(config.version_watermark(), CURRENT_VERSION);

    return_shared(config);
    destroy(admin_cap);
    scenario.end();
}

#[test]
fun bump_advances_an_older_watermark_to_the_current_version() {
    let mut scenario = test::begin(ADMIN);
    let (config_id, admin_cap) = session_config::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    let mut config = scenario.take_shared_by_id<SessionsConfig>(config_id);
    session_config::set_version_watermark_for_testing(&mut config, OLDER_VERSION);
    assert_eq!(config.version_watermark(), OLDER_VERSION);

    config.bump_version_watermark(&admin_cap);
    assert_eq!(config.version_watermark(), CURRENT_VERSION);

    return_shared(config);
    destroy(admin_cap);
    scenario.end();
}

#[test, expected_failure(abort_code = session_config::EVersionWatermarkNotAdvanced)]
fun bump_at_the_current_version_aborts() {
    let mut scenario = test::begin(ADMIN);
    let (config_id, admin_cap) = session_config::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    let mut config = scenario.take_shared_by_id<SessionsConfig>(config_id);

    config.bump_version_watermark(&admin_cap);
    abort EUnexpectedSuccess
}

#[test]
fun new_config_allows_no_pools() {
    let (scenario, config, admin_cap) = setup();
    assert_eq!(config.allowed_pools(), vector[]);
    finish(scenario, config, admin_cap);
}

#[test]
fun admin_allow_pool_lists_pools_in_the_order_allowed() {
    let (scenario, mut config, admin_cap) = setup();

    config.admin_allow_pool(&admin_cap, pool_a());
    config.admin_allow_pool(&admin_cap, pool_b());

    assert_eq!(config.allowed_pools(), vector[pool_a(), pool_b()]);
    assert_eq!(event::events_by_type<SessionPoolAllowed>().length(), 2);
    finish(scenario, config, admin_cap);
}

#[test]
fun admin_disallow_pool_removes_only_that_pool() {
    let (scenario, mut config, admin_cap) = setup();
    config.admin_allow_pool(&admin_cap, pool_a());
    config.admin_allow_pool(&admin_cap, pool_b());
    config.admin_allow_pool(&admin_cap, pool_c());

    config.admin_disallow_pool(&admin_cap, pool_b());

    assert_eq!(config.allowed_pools(), vector[pool_a(), pool_c()]);
    assert_eq!(event::events_by_type<SessionPoolDisallowed>().length(), 1);
    finish(scenario, config, admin_cap);
}

#[test]
fun a_removed_pool_can_be_allowed_again() {
    let (scenario, mut config, admin_cap) = setup();
    config.admin_allow_pool(&admin_cap, pool_a());
    config.admin_disallow_pool(&admin_cap, pool_a());
    assert_eq!(config.allowed_pools(), vector[]);

    config.admin_allow_pool(&admin_cap, pool_a());

    assert_eq!(config.allowed_pools(), vector[pool_a()]);
    finish(scenario, config, admin_cap);
}

#[test, expected_failure(abort_code = vec_set::EKeyAlreadyExists)]
fun allowing_an_allowed_pool_aborts() {
    let (_scenario, mut config, admin_cap) = setup();
    config.admin_allow_pool(&admin_cap, pool_a());

    config.admin_allow_pool(&admin_cap, pool_a());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = session_config::EPoolNotAllowed)]
fun disallowing_an_unlisted_pool_aborts() {
    let (_scenario, mut config, admin_cap) = setup();
    config.admin_allow_pool(&admin_cap, pool_a());

    config.admin_disallow_pool(&admin_cap, pool_b());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = session_config::EPoolNotAllowed)]
fun disallowing_before_any_pool_is_allowed_aborts() {
    let (_scenario, mut config, admin_cap) = setup();

    config.admin_disallow_pool(&admin_cap, pool_a());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = session_config::EPackageVersionDisabled)]
fun retired_package_version_cannot_allow_a_pool() {
    let (_scenario, mut config, admin_cap) = setup();
    session_config::set_version_watermark_for_testing(&mut config, FUTURE_VERSION);

    config.admin_allow_pool(&admin_cap, pool_a());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = session_config::EPackageVersionDisabled)]
fun retired_package_version_cannot_disallow_a_pool() {
    let (_scenario, mut config, admin_cap) = setup();
    config.admin_allow_pool(&admin_cap, pool_a());
    session_config::set_version_watermark_for_testing(&mut config, FUTURE_VERSION);

    config.admin_disallow_pool(&admin_cap, pool_a());
    abort EUnexpectedSuccess
}

fun setup(): (Scenario, SessionsConfig, SessionsAdminCap) {
    let mut scenario = test::begin(ADMIN);
    let (config_id, admin_cap) = session_config::init_for_testing(scenario.ctx());
    scenario.next_tx(ADMIN);
    let config = scenario.take_shared_by_id<SessionsConfig>(config_id);
    (scenario, config, admin_cap)
}

fun finish(scenario: Scenario, config: SessionsConfig, admin_cap: SessionsAdminCap) {
    return_shared(config);
    destroy(admin_cap);
    scenario.end();
}

fun pool_a(): ID { object::id_from_address(POOL_A) }

fun pool_b(): ID { object::id_from_address(POOL_B) }

fun pool_c(): ID { object::id_from_address(POOL_C) }
