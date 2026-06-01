// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::protocol_config_tests;

use deepbook_predict::{admin, protocol_config};
use std::unit_test::destroy;

// === trading_paused / pause_trading ===

#[test]
fun new_for_testing_is_not_paused() {
    let ctx = &mut tx_context::dummy();
    let config = protocol_config::new_for_testing(ctx);

    assert!(!config.trading_paused());

    destroy(config);
}

#[test]
fun pause_trading_is_one_way_from_package() {
    // The package-internal pause_trading is the PauseCap path; it cannot
    // unpause. Verifies it sets the flag.
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);

    config.pause_trading();
    assert!(config.trading_paused());
    // Calling it again is idempotent.
    config.pause_trading();
    assert!(config.trading_paused());

    destroy(config);
}

#[test]
fun set_trading_paused_round_trips_both_directions() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let mut config = protocol_config::new_for_testing(ctx);

    config.set_trading_paused(&admin_cap, true);
    assert!(config.trading_paused());
    config.set_trading_paused(&admin_cap, false);
    assert!(!config.trading_paused());

    destroy(config);
    destroy(admin_cap);
}

// === assert_trading_allowed ===

#[test]
fun assert_trading_allowed_passes_when_not_paused_and_no_valuation() {
    let ctx = &mut tx_context::dummy();
    let config = protocol_config::new_for_testing(ctx);

    config.assert_trading_allowed();

    destroy(config);
}

#[test, expected_failure(abort_code = protocol_config::ETradingPaused)]
fun assert_trading_allowed_aborts_when_paused() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let mut config = protocol_config::new_for_testing(ctx);
    config.set_trading_paused(&admin_cap, true);

    config.assert_trading_allowed();
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun assert_trading_allowed_aborts_during_valuation() {
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);
    config.begin_valuation();

    config.assert_trading_allowed();
    abort 999
}

// === Valuation lock lifecycle ===

#[test]
fun begin_then_end_valuation_succeeds() {
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);

    config.begin_valuation();
    config.assert_valuation_in_progress();
    config.end_valuation();
    config.assert_not_valuation_in_progress();

    destroy(config);
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun begin_valuation_twice_aborts() {
    // The lock is transaction-local; nesting is not allowed.
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);
    config.begin_valuation();

    config.begin_valuation();
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationNotInProgress)]
fun end_valuation_without_begin_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);

    config.end_valuation();
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationNotInProgress)]
fun assert_valuation_in_progress_aborts_when_not_held() {
    let ctx = &mut tx_context::dummy();
    let config = protocol_config::new_for_testing(ctx);

    config.assert_valuation_in_progress();
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun assert_not_valuation_in_progress_aborts_when_held() {
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);
    config.begin_valuation();

    config.assert_not_valuation_in_progress();
    abort 999
}

// === Sub-config getters return stable references ===

#[test]
fun pricing_config_getter_returns_stable_reference() {
    // The getters return &PricingConfig / &FeeConfig / etc. — just verify
    // they're callable and reading them does not abort. The sub-config
    // contents are tested in their own modules' test files.
    let ctx = &mut tx_context::dummy();
    let config = protocol_config::new_for_testing(ctx);

    let _ = config.pricing_config();
    let _ = config.fee_config();
    let _ = config.risk_config();
    let _ = config.market_oracle_config();
    let _ = config.leverage_config();

    destroy(config);
}

// === pause_trading interaction with valuation lock ===

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun pause_trading_during_valuation_aborts() {
    // Even the PauseCap-driven pause must wait for the valuation lock to
    // clear; otherwise a kill-switch mid-valuation could leave invariants
    // inconsistent.
    let ctx = &mut tx_context::dummy();
    let mut config = protocol_config::new_for_testing(ctx);
    config.begin_valuation();

    config.pause_trading();
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun set_trading_paused_during_valuation_aborts() {
    let ctx = &mut tx_context::dummy();
    let admin_cap = admin::create_admin_cap_for_testing(ctx);
    let mut config = protocol_config::new_for_testing(ctx);
    config.begin_valuation();

    config.set_trading_paused(&admin_cap, true);
    abort 999
}
