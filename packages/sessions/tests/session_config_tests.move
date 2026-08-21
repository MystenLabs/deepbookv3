// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_sessions::session_config_tests;

use deepbook_sessions::session_config::{Self, SessionsConfig};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::{Self as test, return_shared};

const ADMIN: address = @0xAD;
const OLDER_VERSION: u64 = 0;
const CURRENT_VERSION: u64 = 1;
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
