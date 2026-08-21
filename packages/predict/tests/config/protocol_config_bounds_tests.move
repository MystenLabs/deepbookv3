// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Validation-envelope tests for the admin-tunable values on `ProtocolConfig`
/// whose `config_constants` bounds were previously untested: the
/// strike-exposure templates (base fee, min fee, entry-probability bounds,
/// expiry-fee ramp, backing buffer lambda, inventory-impact max rate).
/// Every abort test drives the real
/// admin setter on a shared
/// `ProtocolConfig` with a value one unit outside the envelope; pass tests assert
/// that boundary values round-trip through setter + getter. Codes whose envelope
/// floor is 0
/// (`EInvalidMinFee`, `EInvalidMinEntryProbability`, `EInvalidMaxEntryProbability`)
/// have no reachable below-min case for a
/// `u64`, so only the above-max side is exercised.
#[test_only]
module deepbook_predict::protocol_config_bounds_tests;

use deepbook_predict::{
    admin::{Self, AdminCap},
    config_constants,
    constants,
    flow_test_helpers as helpers,
    protocol_config::{Self, ProtocolConfig},
    strike_exposure_config,
    test_constants
};
use fixed_math::math;
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::{Self as test, Scenario, return_shared};

const EUnexpectedSuccess: u64 = 999;

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

// === Strike-exposure templates: entry-probability bounds ===

// The `config_constants` envelope check fires before the setter's relational
// `EInvalidEntryProbabilityBound` check, so the just-outside envelope value
// aborts with the envelope code even though it also violates the relational
// bound.
// The 1% envelope floor is load-bearing for budget-bias mint sizing: one
// premium unit of probe conservatism stays sub-lot only while entry
// probability cannot be configured below it (RP-13).
#[test, expected_failure(abort_code = config_constants::EInvalidMinEntryProbability)]
fun template_min_entry_probability_below_envelope_floor_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_min_entry_probability(
        &admin_cap,
        config_constants::min_min_entry_probability!() - 1,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMinEntryProbability)]
fun template_min_entry_probability_above_max_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_min_entry_probability(
        &admin_cap,
        config_constants::max_min_entry_probability!() + 1,
    );
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidMaxEntryProbability)]
fun template_max_entry_probability_above_max_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_max_entry_probability(
        &admin_cap,
        config_constants::max_max_entry_probability!() + 1,
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
        constants::one_minute_ms!() - 1,
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

// === Strike-exposure templates: inventory-impact maximum marginal rate ===

#[test, expected_failure(abort_code = config_constants::EInvalidInventoryImpactMaxRate)]
fun template_inventory_impact_max_rate_above_one_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_inventory_impact_max_rate(
        &admin_cap,
        config_constants::max_inventory_impact_max_rate!() + 1,
    );
    abort 999
}

// === Strike-exposure templates: inventory-skew rate ===

#[test, expected_failure(abort_code = config_constants::EInvalidInventorySkewRate)]
fun template_inventory_skew_rate_above_max_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_inventory_skew_rate(
        &admin_cap,
        config_constants::max_inventory_skew_rate!() + 1,
    );
    abort 999
}

/// The relational half of the skew-rate ceiling's rationale: the largest possible
/// per-unit rebate, `max_rate / 2`, must sit under the smallest premium any
/// admissible config can charge, `min_min_entry_probability`. Both sides are
/// upgrade-required constants, so this pin is the guard.
#[test]
fun max_skew_rebate_stays_below_the_minimum_premium() {
    let max_rebate_per_unit = config_constants::max_inventory_skew_rate!() / 2;
    assert!(max_rebate_per_unit < config_constants::min_min_entry_probability!());
}

/// A skew rebate is bounded by `rate * quantity / 2` while the ordinary fee is
/// bounded below by `min_fee * quantity`. `min_fee` is admin-tunable down to zero,
/// so an admin can drive the fee under the rebate ceiling and make flattening the
/// book pay more than it costs. Market creation refuses the pairing.
#[test, expected_failure(abort_code = strike_exposure_config::ESkewRateExceedsFeeFloor)]
fun a_skew_rate_above_twice_the_fee_floor_cannot_be_snapshotted() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);

    // Each value is individually admissible; only the pairing is not.
    config.set_template_min_fee(&admin_cap, config_constants::min_min_fee!());
    config.set_template_inventory_skew_rate(&admin_cap, 1);
    destroy(config.strike_exposure_template_config().snapshot());

    abort EUnexpectedSuccess
}

// === Strike-exposure templates: boundary values round-trip ===

#[test]
fun backing_buffer_lambda_market_snapshot_freezes_at_creation() {
    let mut fx = helpers::setup_market_default();
    fx.set_template_backing_buffer_lambda(config_constants::max_backing_buffer_lambda!());
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());

    let market = fx.take_market_bundle(expiry_id);
    assert_eq!(
        helpers::market(&market).backing_buffer_lambda(),
        config_constants::max_backing_buffer_lambda!(),
    );
    helpers::return_market_bundle(market);

    fx.set_template_backing_buffer_lambda(config_constants::min_backing_buffer_lambda!());
    let market = fx.take_market_bundle(expiry_id);
    let snapshot = helpers::config(&market).strike_exposure_config_snapshot();
    assert_eq!(snapshot.backing_buffer_lambda(), config_constants::min_backing_buffer_lambda!());
    assert_eq!(
        helpers::market(&market).backing_buffer_lambda(),
        config_constants::max_backing_buffer_lambda!(),
    );
    destroy(snapshot);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test]
fun inventory_impact_rate_and_scale_snapshot_at_creation() {
    let mut fx = helpers::setup_market_default();
    let rate = config_constants::max_inventory_impact_max_rate!();
    fx.set_template_inventory_impact_max_rate(rate);
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());

    let market = fx.take_market_bundle(expiry_id);
    assert_eq!(helpers::market(&market).inventory_impact_max_rate(), rate);
    assert_eq!(
        helpers::market(&market).inventory_impact_scale(),
        test_constants::default_max_expiry_allocation(),
    );
    helpers::return_market_bundle(market);

    // Later template changes do not retroactively reprice the existing book.
    fx.set_template_inventory_impact_max_rate(0);
    let market = fx.take_market_bundle(expiry_id);
    assert_eq!(helpers::market(&market).inventory_impact_max_rate(), rate);
    helpers::return_market_bundle(market);
    fx.finish();
}

// === PLP supply/withdraw fee ===
//
// Two independent rates sharing one envelope. The floor is 0, so there is no
// reachable below-min case for a `u64`; only the above-max side aborts.

#[test, expected_failure(abort_code = config_constants::EInvalidPlpSupplyFeeRate)]
fun plp_supply_fee_rate_above_max_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_plp_supply_fee_rate(&admin_cap, config_constants::max_plp_fee_rate!() + 1);
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidPlpWithdrawFeeRate)]
fun plp_withdraw_fee_rate_above_max_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_plp_withdraw_fee_rate(&admin_cap, config_constants::max_plp_fee_rate!() + 1);
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun set_plp_supply_fee_rate_during_valuation_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.begin_valuation();
    config.set_plp_supply_fee_rate(&admin_cap, config_constants::min_plp_fee_rate!());
    abort 999
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun set_plp_withdraw_fee_rate_during_valuation_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.begin_valuation();
    config.set_plp_withdraw_fee_rate(&admin_cap, config_constants::min_plp_fee_rate!());
    abort 999
}

/// `lp_book::fee_on` subtracts the fee from the amount it was computed on, and
/// relies on the envelope keeping the rate strictly below 1.0 for that never to
/// underflow — inside the mandatory pool-wide flush. That guarantee lives in a
/// comment; this drives the real validators at full scale, so widening the envelope
/// to admit it fails here rather than aborting a live flush.
#[test, expected_failure(abort_code = config_constants::EInvalidPlpSupplyFeeRate)]
fun plp_supply_fee_rate_at_full_scale_is_rejected() {
    config_constants::assert_plp_supply_fee_rate(math::float_scaling!());
    abort 999
}

#[test, expected_failure(abort_code = config_constants::EInvalidPlpWithdrawFeeRate)]
fun plp_withdraw_fee_rate_at_full_scale_is_rejected() {
    config_constants::assert_plp_withdraw_fee_rate(math::float_scaling!());
    abort 999
}

/// The shipped defaults are asymmetric on purpose: entry is free, exit is charged.
/// Asserted as literals so changing either has to be deliberate, and asserted
/// together so a change that accidentally symmetrises them fails here.
#[test]
fun plp_fee_rates_ship_asymmetric_and_accept_boundaries() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);

    assert_eq!(config.plp_supply_fee_rate(), 0); // entry is not taxed
    assert_eq!(config.plp_withdraw_fee_rate(), 2_000_000); // 20 bps on exit

    // Each leg moves independently over the shared envelope.
    config.set_plp_supply_fee_rate(&admin_cap, config_constants::max_plp_fee_rate!());
    assert_eq!(config.plp_supply_fee_rate(), 50_000_000);
    assert_eq!(config.plp_withdraw_fee_rate(), 2_000_000); // untouched

    config.set_plp_withdraw_fee_rate(&admin_cap, config_constants::min_plp_fee_rate!());
    assert_eq!(config.plp_withdraw_fee_rate(), 0);
    assert_eq!(config.plp_supply_fee_rate(), 50_000_000); // untouched

    return_shared(config);
    destroy(admin_cap);
    scenario.end();
}
