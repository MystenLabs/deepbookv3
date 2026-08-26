// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Regression coverage for cross-cutting `ProtocolConfig` gates.
#[test_only]
module deepbook_predict::protocol_config_tests;

use deepbook_predict::{
    config_constants,
    constants,
    flow_test_helpers as helpers,
    protocol_config,
    test_constants,
    test_helpers
};
use std::unit_test::{assert_eq, destroy};
use sui::{clock::{Self, Clock}, test_scenario::{Scenario, return_shared}};

fun new_clock(scenario: &mut Scenario): Clock {
    let mut clock = clock::create_for_testing(scenario.ctx());
    clock.set_for_testing(test_constants::now_ms());
    clock
}

const DEFAULT_PROTOCOL_RESERVE_PROFIT_SHARE: u64 = 100_000_000;

#[test]
fun new_config_seeds_protocol_reserve_profit_share() {
    let (scenario, reg, config, admin_cap) = test_helpers::begin_registry_test();

    assert_eq!(config.protocol_reserve_profit_share(), DEFAULT_PROTOCOL_RESERVE_PROFIT_SHARE);

    destroy(admin_cap);
    return_shared(reg);
    return_shared(config);
    scenario.end();
}

#[test]
fun set_ewma_params_and_enabled_update_config() {
    let (mut scenario, reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    let clock = new_clock(&mut scenario);

    config.set_ewma_params(
        &admin_cap,
        config_constants::min_ewma_alpha!(),
        config_constants::min_ewma_z_score_threshold!(),
        config_constants::min_ewma_penalty_rate!(),
        &clock,
    );
    assert_eq!(config.ewma_config().alpha(), config_constants::min_ewma_alpha!());
    assert_eq!(
        config.ewma_config().z_score_threshold(),
        config_constants::min_ewma_z_score_threshold!(),
    );
    assert_eq!(config.ewma_config().penalty_rate(), config_constants::min_ewma_penalty_rate!());

    config.set_ewma_enabled(&admin_cap, true, &clock);
    assert!(config.ewma_config().enabled());
    config.set_ewma_enabled(&admin_cap, false, &clock);
    assert!(!config.ewma_config().enabled());

    destroy(admin_cap);
    clock.destroy_for_testing();
    return_shared(reg);
    return_shared(config);
    scenario.end();
}

/// A freshly created config ships fill-or-kill. Asserted against the stored state the
/// flush actually reads, not against the default macro, so a constructor that stopped
/// seeding this field would be caught here.
#[test]
fun new_config_ships_with_no_retry() {
    let (scenario, reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    assert_eq!(config.lp_request_limit_flush_attempts(), 1);

    // And the admin path moves it, so the getter is not reading a frozen constant.
    config.set_lp_request_limit_flush_attempts(&admin_cap, 3);
    assert_eq!(config.lp_request_limit_flush_attempts(), 3);

    destroy(admin_cap);
    return_shared(reg);
    return_shared(config);
    scenario.end();
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun set_lp_request_limit_flush_attempts_during_valuation_aborts() {
    // `finish_flush` reads the attempt count mid-PTB and hands it to both queue drains;
    // moving it under a valuation in flight would change the drain policy between the
    // mark being frozen and the queues being drained against it.
    let (_scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    config.begin_valuation();
    config.set_lp_request_limit_flush_attempts(
        &admin_cap,
        config_constants::max_lp_request_limit_flush_attempts!(),
    );
    abort 999
}

/// A fresh config admits any pool size, so merging the cap changes no behaviour until
/// an operator sets a figure. Asserted against the stored state the flush reads.
#[test]
fun new_config_ships_uncapped() {
    let (scenario, reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    assert_eq!(config.max_lp_pool_value(), config_constants::max_max_lp_pool_value!());

    config.set_max_lp_pool_value(&admin_cap, 5_000_000_000_000);
    assert_eq!(config.max_lp_pool_value(), 5_000_000_000_000);

    destroy(admin_cap);
    return_shared(reg);
    return_shared(config);
    scenario.end();
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun set_max_lp_pool_value_during_valuation_aborts() {
    // The flush reads the cap mid-PTB and applies it to the supply pass; moving it
    // under a valuation in flight would change capacity after the mark was frozen.
    let (_scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    config.begin_valuation();
    config.set_max_lp_pool_value(&admin_cap, config_constants::min_max_lp_pool_value!());
    abort 999
}

#[test]
fun expiry_market_mint_pause_defaults_false_and_toggles() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let mut market = fx.take_market_bundle(expiry_id);

    assert!(!helpers::market(&market).mint_paused());
    fx.set_expiry_mint_paused_bundle(&mut market, true);
    assert!(helpers::market(&market).mint_paused());
    fx.set_expiry_mint_paused_bundle(&mut market, false);
    assert!(!helpers::market(&market).mint_paused());

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun frozen_defaults_false_and_admin_toggles() {
    let (scenario, reg, mut config, admin_cap) = test_helpers::begin_registry_test();

    assert!(!config.frozen());
    config.set_frozen(&admin_cap, true);
    assert!(config.frozen());
    // Admin lifts the freeze while frozen: `set_frozen` is intentionally ungated,
    // so an engaged freeze never bricks its own recovery.
    config.set_frozen(&admin_cap, false);
    assert!(!config.frozen());

    destroy(admin_cap);
    return_shared(reg);
    return_shared(config);
    scenario.end();
}

#[test, expected_failure(abort_code = protocol_config::EProtocolFrozen)]
fun frozen_blocks_version_gated_flow() {
    // The freeze folds into `assert_version`, so every version-gated flow aborts
    // while frozen. `set_ewma_enabled` is a representative gated entrypoint.
    let (mut scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    let clock = new_clock(&mut scenario);
    config.set_frozen(&admin_cap, true);
    config.set_ewma_enabled(&admin_cap, true, &clock);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EVersionWatermarkNotAdvanced)]
fun bump_version_watermark_at_current_version_aborts() {
    // At genesis the watermark already equals the running `current_version!()`, so
    // `bump_version_watermark` cannot advance the floor and aborts.
    let (_scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    config.bump_version_watermark(&admin_cap);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun set_use_pyth_spot_for_forward_during_valuation_aborts() {
    // The flush marks every active market against one live-forward formula; letting
    // the source change mid-valuation would mix two marks into one NAV.
    let (mut scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    let clock = new_clock(&mut scenario);
    config.begin_valuation();
    config.set_use_pyth_spot_for_forward(&admin_cap, false, &clock);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun set_pyth_spot_freshness_during_valuation_aborts() {
    let (mut scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    let clock = new_clock(&mut scenario);
    config.begin_valuation();
    config.set_pyth_spot_freshness_ms(
        &admin_cap,
        config_constants::min_pyth_spot_freshness_ms!(),
        &clock,
    );
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun set_block_scholes_price_freshness_during_valuation_aborts() {
    let (mut scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    let clock = new_clock(&mut scenario);
    config.begin_valuation();
    config.set_block_scholes_price_freshness_ms(
        &admin_cap,
        config_constants::min_block_scholes_price_freshness_ms!(),
        &clock,
    );
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun set_block_scholes_svi_freshness_during_valuation_aborts() {
    let (mut scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    let clock = new_clock(&mut scenario);
    config.begin_valuation();
    config.set_block_scholes_svi_freshness_ms(
        &admin_cap,
        config_constants::min_block_scholes_svi_freshness_ms!(),
        &clock,
    );
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun set_protocol_reserve_profit_share_during_valuation_aborts() {
    let (_scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    config.begin_valuation();
    config.set_protocol_reserve_profit_share(
        &admin_cap,
        config_constants::min_protocol_reserve_profit_share!(),
    );
    abort 999
}

/// The window that bounds a stalled flush's LP-fill delay — and therefore the staleness of the mark those fills execute at — ships at ten minutes and is admin-tunable, so keeper cadence and stall tolerance can be retuned without an upgrade.
#[test]
fun max_valuation_window_ships_at_ten_minutes_and_is_tunable() {
    let (scenario, reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    assert_eq!(config.max_valuation_window_ms(), 10 * constants::one_minute_ms!());

    config.set_max_valuation_window_ms(
        &admin_cap,
        config_constants::min_max_valuation_window_ms!(),
    );
    assert_eq!(config.max_valuation_window_ms(), config_constants::min_max_valuation_window_ms!());

    destroy(admin_cap);
    return_shared(reg);
    return_shared(config);
    scenario.end();
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxValuationWindowMs)]
fun max_valuation_window_below_the_floor_aborts() {
    // A window under the floor lets anyone discard a flush the keeper is still working through, converting a liveness knob into a griefing lever.
    let (_scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    config.set_max_valuation_window_ms(
        &admin_cap,
        config_constants::min_max_valuation_window_ms!() - 1,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxValuationWindowMs)]
fun max_valuation_window_above_the_ceiling_aborts() {
    // The ceiling bounds how long an abandoned flush can stall queued LP fills even if an operator sets this carelessly.
    let (_scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    config.set_max_valuation_window_ms(
        &admin_cap,
        config_constants::max_max_valuation_window_ms!() + 1,
    );
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun set_max_valuation_window_during_valuation_aborts() {
    // `abort_valuation` measures the deadline against a flush already in flight; moving the window under one would shift its escape hatch after the fact.
    let (_scenario, _reg, mut config, admin_cap) = test_helpers::begin_registry_test();
    config.begin_valuation();
    config.set_max_valuation_window_ms(
        &admin_cap,
        config_constants::min_max_valuation_window_ms!(),
    );
    abort 999
}
