// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Economic invariants for the inventory-skew statistic.
///
/// Skew is the standard deviation of the payout profile over a window centred on
/// the reference tick. The properties that make it safe to charge and rebate are
/// all consequences of it being a function of book state: closed sequences cancel,
/// and adding the same payout everywhere in the window changes nothing, so a
/// guaranteed-payout position cannot be farmed for a rebate.
#[test_only]
module deepbook_predict::inventory_skew_tests;

use deepbook_predict::{
    constants,
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    pricing::Pricer,
    strike_exposure::{Self, StrikeExposure},
    strike_exposure_config::{Self, StrikeExposureConfig},
    test_constants
};
use std::unit_test::assert_eq;
use sui::{object::{Self, UID}, test_scenario::return_shared, tx_context};

/// The two complementary halves of the strike domain. Clipped to the window they
/// are its lower and upper halves, so one leans the book and the other flattens it.
fun lower_half(): (u64, u64) { (0, test_constants::default_strike_tick()) }

fun upper_half(): (u64, u64) { (test_constants::default_strike_tick(), constants::pos_inf_tick!()) }

/// Mint through the production path so the accumulators are folded in the same
/// order a real trade folds them.
fun mint(exposure: &mut StrikeExposure, pricer: &Pricer, lower: u64, higher: u64, quantity: u64) {
    let terms = exposure.quote_mint_terms(pricer, lower, higher, 0, quantity, true);
    let order = exposure.allocate_mint_order(terms);
    let _ = order;
}

public struct ExposureHarness has key {
    id: UID,
    exposure: StrikeExposure,
}

const IMPACT_SCALE: u64 = 4_000_000_000;
const SKEW_RATE: u64 = 200_000_000; // 20%
const WINDOW_FRACTION: u64 = 100_000_000; // 10% of the reference tick
const ONE_ORDER: u64 = 1_000_000_000;

#[test]
fun default_zero_rate_is_a_kill_switch() {
    let (fx, oracle, harness) = disabled_harness();
    let (lower, higher) = upper_half();

    let adjustment = harness.exposure.inventory_skew(lower, higher, ONE_ORDER, true);
    assert_eq!(adjustment.skew_amount(), 0);

    cleanup(fx, oracle, harness);
}

/// Without a reference tick there is no window to average over, so the statistic
/// reads zero rather than guessing a domain.
#[test]
fun no_reference_tick_reads_zero() {
    let (fx, oracle, harness) = enabled_harness_without_reference();
    let (lower, higher) = upper_half();

    let adjustment = harness.exposure.inventory_skew(lower, higher, ONE_ORDER, true);
    assert_eq!(adjustment.skew_amount(), 0);

    cleanup(fx, oracle, harness);
}

/// The core economic claim. Against a book leaning one way, filling the empty side
/// is rebated while piling onto the same side is charged.
#[test]
fun balancing_is_rebated_and_concentrating_is_charged() {
    let (mut fx, oracle, mut harness) = enabled_harness();
    let pricer = fx.load_pricer_bundle(&oracle);
    let (upper_lower, upper_higher) = upper_half();
    mint(&mut harness.exposure, &pricer, upper_lower, upper_higher, ONE_ORDER);

    let (balance_lower, balance_higher) = lower_half();
    let balancing = harness.exposure.inventory_skew(balance_lower, balance_higher, ONE_ORDER, true);
    let (pile_lower, pile_higher) = upper_half();
    let concentrating = harness.exposure.inventory_skew(pile_lower, pile_higher, ONE_ORDER, true);

    assert!(!balancing.skew_is_charge());
    assert!(concentrating.skew_is_charge());
    assert!(balancing.skew_amount() > 0);
    assert!(concentrating.skew_amount() > 0);

    cleanup(fx, oracle, harness);
}

/// Adding the same payout at every price in the window is exactly the flat
/// direction the measure is invariant to. This is the guaranteed-payout trade, and
/// it must earn nothing.
#[test]
fun covering_the_whole_window_changes_nothing() {
    let (mut fx, oracle, mut harness) = enabled_harness();
    let pricer = fx.load_pricer_bundle(&oracle);
    let (upper_lower, upper_higher) = upper_half();
    mint(&mut harness.exposure, &pricer, upper_lower, upper_higher, ONE_ORDER);

    let adjustment = harness
        .exposure
        .inventory_skew(0, constants::pos_inf_tick!(), ONE_ORDER, true);
    assert_eq!(adjustment.skew_amount(), 0);

    cleanup(fx, oracle, harness);
}

/// Opening and closing the same range returns the statistic to where it started,
/// so the charge and the rebate are equal and opposite.
#[test]
fun round_trip_nets_to_zero() {
    let (mut fx, oracle, mut harness) = enabled_harness();
    let pricer = fx.load_pricer_bundle(&oracle);
    let (upper_lower, upper_higher) = upper_half();
    mint(&mut harness.exposure, &pricer, upper_lower, upper_higher, ONE_ORDER);

    let (lower, higher) = lower_half();
    let opening = harness.exposure.inventory_skew(lower, higher, ONE_ORDER, true);
    mint(&mut harness.exposure, &pricer, lower, higher, ONE_ORDER);
    let closing = harness.exposure.inventory_skew(lower, higher, ONE_ORDER, false);

    assert_eq!(opening.skew_amount(), closing.skew_amount());
    assert!(opening.skew_is_charge() != closing.skew_is_charge());

    cleanup(fx, oracle, harness);
}

fun enabled_harness(): (OracleFixture, OracleBundle, ExposureHarness) {
    let (fx, oracle, mut harness) = new_harness(skew_config(SKEW_RATE));
    harness.exposure.set_reference_tick(test_constants::default_strike_tick());
    (fx, oracle, harness)
}

fun enabled_harness_without_reference(): (OracleFixture, OracleBundle, ExposureHarness) {
    new_harness(skew_config(SKEW_RATE))
}

fun disabled_harness(): (OracleFixture, OracleBundle, ExposureHarness) {
    let (fx, oracle, mut harness) = new_harness(strike_exposure_config::new());
    harness.exposure.set_reference_tick(test_constants::default_strike_tick());
    (fx, oracle, harness)
}

fun skew_config(rate: u64): StrikeExposureConfig {
    let mut config = strike_exposure_config::new();
    config.set_inventory_skew_rate(rate);
    config.set_skew_window_fraction(WINDOW_FRACTION);
    config
}

fun new_harness(config: StrikeExposureConfig): (OracleFixture, OracleBundle, ExposureHarness) {
    let mut fx = oracle_fixture::setup_oracle(
        test_constants::default_live_price(),
        test_constants::default_tick_size(),
        test_constants::short_expiry_ms(),
    );
    let expiry_id = fx.expiry_id();
    let expiry_ms = fx.expiry();
    fx.scenario_mut().next_tx(test_constants::admin());
    let id = object::new(fx.scenario_mut().ctx());
    let harness_id = id.to_inner();
    let exposure = strike_exposure::new(
        expiry_id,
        config,
        test_constants::default_tick_size(),
        test_constants::default_admission_tick_size(),
        expiry_ms - test_constants::default_cadence_period_ms(),
        IMPACT_SCALE,
        fx.scenario_mut().ctx(),
    );
    transfer::share_object(ExposureHarness { id, exposure });
    fx.scenario_mut().next_tx(test_constants::admin());
    let harness = fx.scenario_mut().take_shared_by_id<ExposureHarness>(harness_id);
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    (fx, oracle, harness)
}

fun cleanup(fx: OracleFixture, oracle: OracleBundle, harness: ExposureHarness) {
    return_shared(harness);
    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}
