// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// The authority and flow gates around publishing a quote calibration
/// correction: who may publish, for which underlying, and when.
///
/// The correction's own content and behaviour are covered in
/// `quote_calibration_tests`; this file is about the entrypoint that admits it.
#[test_only]
module deepbook_predict::registry_calibration_tests;

use deepbook_predict::{
    admin,
    market_manager,
    protocol_config::ProtocolConfig,
    quote_calibration_cap::QuoteCalibrationCap,
    registry::{Self, Registry},
    test_constants,
    test_helpers
};
use fixed_math::math;
use sui::{clock, test_utils::destroy};

const KNOT_STEP: u64 = 50_000_000;
const KNOT_COUNT: u64 = 19;
const ROW_COUNT: u64 = 11;

/// A correction that changes nothing: each knot maps its own grid probability to
/// itself. Publishable by construction — non-decreasing and all in range.
fun identity_table(): vector<u64> {
    let mut knots = vector[];
    let mut r = 0;
    while (r < ROW_COUNT) {
        let mut j = 0;
        while (j < KNOT_COUNT) {
            knots.push_back((j + 1) * KNOT_STEP);
            j = j + 1;
        };
        r = r + 1;
    };
    knots
}

#[test]
fun an_allowlisted_capability_publishes_for_a_registered_underlying() {
    let (mut scenario, mut reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    reg.register_underlying(&config, &admin_cap, test_constants::propbook_underlying_id());
    let cap = reg.mint_quote_calibration_cap(&config, &admin_cap, scenario.ctx());
    let c = clock::create_for_testing(scenario.ctx());

    registry::publish_quote_calibration(
        &mut config,
        &reg,
        &cap,
        test_constants::propbook_underlying_id(),
        identity_table(),
        &c,
        scenario.ctx(),
    );

    // Publishing does not switch the mechanism on: it ships off and stays off
    // until an admin says otherwise, so nothing published resolves to a
    // correction yet.
    scenario.next_tx(test_constants::admin());
    let resolved = config
        .quote_calibration()
        .resolve_row(
            test_constants::propbook_underlying_id(),
            c.timestamp_ms() + 1_000,
            &c,
            scenario.ctx(),
        );
    assert!(resolved.is_none());

    destroy(cap);
    destroy(admin_cap);
    destroy(c);
    destroy(reg);
    destroy(config);
    scenario.end();
}

#[test, expected_failure(abort_code = registry::EQuoteCalibrationCapNotValid)]
fun a_revoked_capability_cannot_publish() {
    let (mut scenario, mut reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    reg.register_underlying(&config, &admin_cap, test_constants::propbook_underlying_id());
    let cap = reg.mint_quote_calibration_cap(&config, &admin_cap, scenario.ctx());
    reg.revoke_quote_calibration_cap(&admin_cap, cap.id());
    let c = clock::create_for_testing(scenario.ctx());

    registry::publish_quote_calibration(
        &mut config,
        &reg,
        &cap,
        test_constants::propbook_underlying_id(),
        identity_table(),
        &c,
        scenario.ctx(),
    );
    abort 999
}

#[test, expected_failure(abort_code = registry::EQuoteCalibrationCapNotFound)]
fun revoking_a_capability_twice_aborts() {
    let (mut scenario, mut reg, config, admin_cap) = test_helpers::begin_registry_test();
    let cap = reg.mint_quote_calibration_cap(&config, &admin_cap, scenario.ctx());
    reg.revoke_quote_calibration_cap(&admin_cap, cap.id());
    reg.revoke_quote_calibration_cap(&admin_cap, cap.id());
    abort 999
}

#[test, expected_failure(abort_code = market_manager::EUnderlyingNotRegistered)]
fun publishing_for_an_unregistered_underlying_aborts() {
    // Without this gate a mistyped identifier would store a correction under a
    // key nothing reads and look like a successful publication.
    let (mut scenario, mut reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    let cap = reg.mint_quote_calibration_cap(&config, &admin_cap, scenario.ctx());
    let c = clock::create_for_testing(scenario.ctx());

    registry::publish_quote_calibration(
        &mut config,
        &reg,
        &cap,
        test_constants::propbook_underlying_id(),
        identity_table(),
        &c,
        scenario.ctx(),
    );
    abort 999
}

#[test, expected_failure(abort_code = deepbook_predict::protocol_config::EValuationInProgress)]
fun publishing_during_a_valuation_aborts() {
    // The flush reads the correction while marking every market, so it must not
    // change underneath one.
    let (mut scenario, mut reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    reg.register_underlying(&config, &admin_cap, test_constants::propbook_underlying_id());
    let cap = reg.mint_quote_calibration_cap(&config, &admin_cap, scenario.ctx());
    let c = clock::create_for_testing(scenario.ctx());
    config.begin_valuation();

    registry::publish_quote_calibration(
        &mut config,
        &reg,
        &cap,
        test_constants::propbook_underlying_id(),
        identity_table(),
        &c,
        scenario.ctx(),
    );
    abort 999
}
