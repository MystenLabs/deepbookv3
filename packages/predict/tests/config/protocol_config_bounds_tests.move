// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Validation-envelope tests for the admin-tunable values on `ProtocolConfig`
/// whose `config_constants` bounds were previously untested: the
/// strike-exposure templates (base fee, min fee, ask prices, terminal floor
/// index, expiry-fee ramp, liquidation LTV, backing buffer lambda), the
/// expiry-cash trading-loss rebate template. Every abort test drives the real
/// admin setter on a shared `ProtocolConfig` with a value one unit outside the
/// envelope; pass tests assert that boundary values round-trip through setter +
/// getter. Codes whose envelope floor is 0
/// (`EInvalidMinFee`, `EInvalidMinAskPrice`, `EInvalidMaxAskPrice`,
/// `EInvalidTradingLossRebateRate`) have no reachable below-min case for a
/// `u64`, so only the above-max side is exercised.
#[test_only]
module deepbook_predict::protocol_config_bounds_tests;

use deepbook_predict::{
    admin::{Self, AdminCap},
    config_constants,
    flow_test_helpers as helpers,
    protocol_config::{Self, ProtocolConfig},
    test_constants
};
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::{Self as test, Scenario, return_shared};

/// Create a real shared `ProtocolConfig` (all template values at defaults) and
/// an `AdminCap`, ready for admin setter calls in the next transaction.
fun new_shared_config(): (Scenario, AdminCap, ID) {
    let mut scenario = test::begin(test_constants::admin());
    let config_id = protocol_config::create_and_share(scenario.ctx());
    let admin_cap = admin::new(scenario.ctx());
    scenario.next_tx(test_constants::admin());
    (scenario, admin_cap, config_id)
}

// === Strike-exposure templates: base fee ===

#[test, expected_failure(abort_code = config_constants::EInvalidBaseFee)]
fun template_base_fee_below_min_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_base_fee(&admin_cap, config_constants::min_base_fee!() - 1);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidBaseFee)]
fun template_base_fee_above_max_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_base_fee(&admin_cap, config_constants::max_base_fee!() + 1);
    abort 999
}

// === Strike-exposure templates: min fee ===

#[test, expected_failure(abort_code = config_constants::EInvalidMinFee)]
fun template_min_fee_above_max_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_min_fee(&admin_cap, config_constants::max_min_fee!() + 1);
    abort 999
}

// === Strike-exposure templates: ask prices ===

// The `config_constants` envelope check fires before the setter's relational
// `EInvalidAskBound` check, so the just-outside envelope value aborts with the
// envelope code even though it also violates the relational bound.
#[test, expected_failure(abort_code = config_constants::EInvalidMinAskPrice)]
fun template_min_ask_price_above_max_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_min_ask_price(&admin_cap, config_constants::max_min_ask_price!() + 1);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxAskPrice)]
fun template_max_ask_price_above_max_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_max_ask_price(&admin_cap, config_constants::max_max_ask_price!() + 1);
    abort 999
}

// === Strike-exposure templates: terminal floor index ===

#[test, expected_failure(abort_code = config_constants::EInvalidTerminalFloorIndex)]
fun template_terminal_floor_index_below_min_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_terminal_floor_index(
        &admin_cap,
        config_constants::min_terminal_floor_index!() - 1,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidTerminalFloorIndex)]
fun template_terminal_floor_index_above_max_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_terminal_floor_index(
        &admin_cap,
        config_constants::max_terminal_floor_index!() + 1,
    );
    abort 999
}

// === Strike-exposure templates: expiry fee ramp ===

#[test, expected_failure(abort_code = config_constants::EInvalidExpiryFeeWindowMs)]
fun template_expiry_fee_window_below_min_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_expiry_fee_window_ms(
        &admin_cap,
        config_constants::min_expiry_fee_window_ms!() - 1,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidExpiryFeeWindowMs)]
fun template_expiry_fee_window_above_max_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_expiry_fee_window_ms(
        &admin_cap,
        config_constants::max_expiry_fee_window_ms!() + 1,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidExpiryFeeMaxMultiplier)]
fun template_expiry_fee_max_multiplier_below_min_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_expiry_fee_max_multiplier(
        &admin_cap,
        config_constants::min_expiry_fee_max_multiplier!() - 1,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidExpiryFeeMaxMultiplier)]
fun template_expiry_fee_max_multiplier_above_max_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_expiry_fee_max_multiplier(
        &admin_cap,
        config_constants::max_expiry_fee_max_multiplier!() + 1,
    );
    abort 999
}

// === Strike-exposure templates: liquidation LTV ===

#[test, expected_failure(abort_code = config_constants::EInvalidLiquidationLtv)]
fun template_liquidation_ltv_below_min_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_liquidation_ltv(&admin_cap, config_constants::min_liquidation_ltv!() - 1);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidLiquidationLtv)]
fun template_liquidation_ltv_above_max_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_liquidation_ltv(&admin_cap, config_constants::max_liquidation_ltv!() + 1);
    abort 999
}

// === Strike-exposure templates: backing buffer lambda ===

#[test, expected_failure(abort_code = config_constants::EInvalidBackingBufferLambda)]
fun backing_buffer_lambda_below_min_assert_aborts() {
    config_constants::assert_backing_buffer_lambda(
        config_constants::min_backing_buffer_lambda!() - 1,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidBackingBufferLambda)]
fun backing_buffer_lambda_above_max_assert_aborts() {
    config_constants::assert_backing_buffer_lambda(
        config_constants::max_backing_buffer_lambda!() + 1,
    );
    abort 999
}

// === Strike-exposure templates: boundary values round-trip ===

#[test]
fun strike_exposure_template_setters_accept_envelope_boundaries() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);

    // Envelope floors. `max_ask_price`'s envelope floor (0) is relationally
    // unreachable: the setter requires max > min and min's floor is 0, so the
    // smallest settable max ask is 1. min_ask must drop to 0 first.
    config.set_template_base_fee(&admin_cap, config_constants::min_base_fee!());
    config.set_template_min_fee(&admin_cap, config_constants::min_min_fee!());
    config.set_template_min_ask_price(&admin_cap, config_constants::min_min_ask_price!());
    config.set_template_max_ask_price(&admin_cap, config_constants::min_max_ask_price!() + 1);
    config.set_template_terminal_floor_index(
        &admin_cap,
        config_constants::min_terminal_floor_index!(),
    );
    config.set_template_expiry_fee_window_ms(
        &admin_cap,
        config_constants::min_expiry_fee_window_ms!(),
    );
    config.set_template_expiry_fee_max_multiplier(
        &admin_cap,
        config_constants::min_expiry_fee_max_multiplier!(),
    );
    config.set_template_liquidation_ltv(&admin_cap, config_constants::min_liquidation_ltv!());
    config.set_template_backing_buffer_lambda(
        &admin_cap,
        config_constants::min_backing_buffer_lambda!(),
    );

    let snapshot = config.strike_exposure_config_snapshot();
    assert_eq!(snapshot.base_fee(), config_constants::min_base_fee!());
    assert_eq!(snapshot.min_fee(), config_constants::min_min_fee!());
    assert_eq!(snapshot.min_ask_price(), config_constants::min_min_ask_price!());
    assert_eq!(snapshot.max_ask_price(), config_constants::min_max_ask_price!() + 1);
    assert_eq!(snapshot.terminal_floor_index(), config_constants::min_terminal_floor_index!());
    assert_eq!(snapshot.expiry_fee_window_ms(), config_constants::min_expiry_fee_window_ms!());
    assert_eq!(
        snapshot.expiry_fee_max_multiplier(),
        config_constants::min_expiry_fee_max_multiplier!(),
    );
    assert_eq!(snapshot.liquidation_ltv(), config_constants::min_liquidation_ltv!());
    assert_eq!(snapshot.backing_buffer_lambda(), config_constants::min_backing_buffer_lambda!());
    destroy(snapshot);

    // Envelope ceilings. max_ask goes up first so min_ask can follow; min_ask's
    // envelope ceiling equals max_ask's, so the highest settable min ask is one
    // unit below it (the setter requires min < max).
    config.set_template_max_ask_price(&admin_cap, config_constants::max_max_ask_price!());
    config.set_template_min_ask_price(&admin_cap, config_constants::max_min_ask_price!() - 1);
    config.set_template_base_fee(&admin_cap, config_constants::max_base_fee!());
    config.set_template_min_fee(&admin_cap, config_constants::max_min_fee!());
    config.set_template_terminal_floor_index(
        &admin_cap,
        config_constants::max_terminal_floor_index!(),
    );
    config.set_template_expiry_fee_window_ms(
        &admin_cap,
        config_constants::max_expiry_fee_window_ms!(),
    );
    config.set_template_expiry_fee_max_multiplier(
        &admin_cap,
        config_constants::max_expiry_fee_max_multiplier!(),
    );
    config.set_template_liquidation_ltv(&admin_cap, config_constants::max_liquidation_ltv!());
    config.set_template_backing_buffer_lambda(
        &admin_cap,
        config_constants::max_backing_buffer_lambda!(),
    );

    let snapshot = config.strike_exposure_config_snapshot();
    assert_eq!(snapshot.base_fee(), config_constants::max_base_fee!());
    assert_eq!(snapshot.min_fee(), config_constants::max_min_fee!());
    assert_eq!(snapshot.min_ask_price(), config_constants::max_min_ask_price!() - 1);
    assert_eq!(snapshot.max_ask_price(), config_constants::max_max_ask_price!());
    assert_eq!(snapshot.terminal_floor_index(), config_constants::max_terminal_floor_index!());
    assert_eq!(snapshot.expiry_fee_window_ms(), config_constants::max_expiry_fee_window_ms!());
    assert_eq!(
        snapshot.expiry_fee_max_multiplier(),
        config_constants::max_expiry_fee_max_multiplier!(),
    );
    assert_eq!(snapshot.liquidation_ltv(), config_constants::max_liquidation_ltv!());
    assert_eq!(snapshot.backing_buffer_lambda(), config_constants::max_backing_buffer_lambda!());
    destroy(snapshot);

    return_shared(config);
    destroy(admin_cap);
    scenario.end();
}

#[test]
fun backing_buffer_lambda_market_snapshot_freezes_at_creation() {
    let mut fx = helpers::setup_market_default();
    fx.set_template_backing_buffer_lambda(config_constants::max_backing_buffer_lambda!());
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());

    let (pyth, bs, oracle_registry, vault, market, config) = fx.take_market(expiry_id);
    assert_eq!(market.backing_buffer_lambda(), config_constants::max_backing_buffer_lambda!());
    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);

    fx.set_template_backing_buffer_lambda(config_constants::min_backing_buffer_lambda!());
    let (pyth, bs, oracle_registry, vault, market, config) = fx.take_market(expiry_id);
    let snapshot = config.strike_exposure_config_snapshot();
    assert_eq!(snapshot.backing_buffer_lambda(), config_constants::min_backing_buffer_lambda!());
    assert_eq!(market.backing_buffer_lambda(), config_constants::max_backing_buffer_lambda!());
    destroy(snapshot);

    helpers::return_market(pyth, bs, oracle_registry, vault, market, config);
    fx.finish();
}

// === Expiry-cash template: trading-loss rebate rate ===

#[test, expected_failure(abort_code = config_constants::EInvalidTradingLossRebateRate)]
fun template_trading_loss_rebate_rate_above_max_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_trading_loss_rebate_rate(
        &admin_cap,
        config_constants::max_trading_loss_rebate_rate!() + 1,
    );
    abort 999
}

#[test]
fun template_trading_loss_rebate_rate_accepts_boundaries() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);

    config.set_template_trading_loss_rebate_rate(
        &admin_cap,
        config_constants::min_trading_loss_rebate_rate!(),
    );
    let snapshot = config.expiry_cash_config_snapshot();
    assert_eq!(
        snapshot.trading_loss_rebate_rate(),
        config_constants::min_trading_loss_rebate_rate!(),
    );
    destroy(snapshot);

    config.set_template_trading_loss_rebate_rate(
        &admin_cap,
        config_constants::max_trading_loss_rebate_rate!(),
    );
    let snapshot = config.expiry_cash_config_snapshot();
    assert_eq!(
        snapshot.trading_loss_rebate_rate(),
        config_constants::max_trading_loss_rebate_rate!(),
    );
    destroy(snapshot);

    return_shared(config);
    destroy(admin_cap);
    scenario.end();
}
