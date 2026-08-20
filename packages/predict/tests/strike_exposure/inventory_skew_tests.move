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
    order::Order,
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
const SKEW_RATE: u64 = 5_000_000; // 0.5%, the configured ceiling
const WINDOW_FRACTION: u64 = 100_000_000; // 10% of the reference tick at a daily tenor
/// The statistic needs a window several ticks wide to mean anything, and the
/// fraction scales with the square root of the tenor. A daily cadence against the
/// fixture's reference tick of 100 gives a 20-tick window; the fixture's own
/// one-minute cadence would scale it to well under one tick.
const DAILY_CADENCE_MS: u64 = 86_400_000;
/// Hand-derived expectations for the 20-tick window (reference 100, +/-10 ticks).
/// One order of Q over the upper half leaves W = Q on 10 of 20 ticks, so
/// mean = Q/2, variance = Q^2/4 and the deviation is Q/2 = 5e8. At the 0.5% ceiling
/// the charge is 0.005 * 5e8 = 2.5e6. Filling the lower half makes W flat, so the
/// deviation returns to zero and the rebate is the same 2.5e6.
const HALF_WINDOW_DEVIATION_CHARGE: u64 = 2_500_000;
/// Small enough that each leg's `rate * deviation` truncates: at 5e8 deviation
/// the product is 1.5, and at 1e9 it is 3.
const TRUNCATING_RATE: u64 = 3;
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
    // Filling the empty half flattens the profile exactly, so the rebate returns
    // the whole deviation the leaning book had built up.
    assert_eq!(balancing.skew_amount(), HALF_WINDOW_DEVIATION_CHARGE);
    // Stacking on the same side doubles the deviation, so the charge is the same
    // increment again: 0.5% of (1e9 - 5e8).
    assert_eq!(concentrating.skew_amount(), HALF_WINDOW_DEVIATION_CHARGE);

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

/// A tenor short enough that the scaled fraction rounds below one tick leaves no
/// window to average over, so the statistic reads zero rather than measuring a
/// degenerate one-tick domain. Skew is undefined when the plausible settlement
/// range spans too few ticks, and reading zero is the safe response.
#[test]
fun sub_tick_window_reads_zero() {
    let (mut fx, oracle, mut harness) = new_harness_with_cadence(
        skew_config(SKEW_RATE),
        test_constants::default_cadence_period_ms(),
    );
    harness.exposure.set_reference_tick(test_constants::default_strike_tick());
    let pricer = fx.load_pricer_bundle(&oracle);
    let (upper_lower, upper_higher) = upper_half();
    mint(&mut harness.exposure, &pricer, upper_lower, upper_higher, ONE_ORDER);

    let (lower, higher) = lower_half();
    let adjustment = harness.exposure.inventory_skew(lower, higher, ONE_ORDER, true);
    assert_eq!(adjustment.skew_amount(), 0);

    cleanup(fx, oracle, harness);
}

/// The first order into an empty book builds the whole deviation, so its charge is
/// the exact hand-derived value rather than a direction.
#[test]
fun first_half_window_mint_charges_the_exact_deviation() {
    let (mut fx, oracle, mut harness) = enabled_harness();
    let pricer = fx.load_pricer_bundle(&oracle);
    let (lower, higher) = upper_half();

    let adjustment = harness.exposure.inventory_skew(lower, higher, ONE_ORDER, true);
    assert!(adjustment.skew_is_charge());
    assert_eq!(adjustment.skew_amount(), HALF_WINDOW_DEVIATION_CHARGE);

    mint(&mut harness.exposure, &pricer, lower, higher, ONE_ORDER);
    assert_eq!(harness.exposure.skew_potential(), HALF_WINDOW_DEVIATION_CHARGE);

    cleanup(fx, oracle, harness);
}

/// The regression that killed a range-local formula. Two ranges opened and then
/// closed in the same order they were opened, never in reverse, must still net to
/// zero across the whole sequence even though no individual leg does.
#[test]
fun cross_range_cycle_nets_to_zero() {
    let (mut fx, oracle, mut harness) = enabled_harness();
    let pricer = fx.load_pricer_bundle(&oracle);
    let (lower_a, higher_a) = lower_half();
    let (lower_b, higher_b) = upper_half();

    let mut charged = 0;
    let mut rebated = 0;

    let open_a = harness.exposure.inventory_skew(lower_a, higher_a, ONE_ORDER, true);
    let order_a = mint_order(&mut harness.exposure, &pricer, lower_a, higher_a, ONE_ORDER);
    let open_b = harness.exposure.inventory_skew(lower_b, higher_b, ONE_ORDER, true);
    let order_b = mint_order(&mut harness.exposure, &pricer, lower_b, higher_b, ONE_ORDER);

    // Close in the order opened, not in reverse.
    let close_a = harness.exposure.quote_live_close(&pricer, &order_a, order_a.quantity());
    let close_a_adjustment = close_a.close_skew_adjustment();
    harness.exposure.process_live_close(close_a).destroy_none();
    let close_b = harness.exposure.quote_live_close(&pricer, &order_b, order_b.quantity());
    let close_b_adjustment = close_b.close_skew_adjustment();
    harness.exposure.process_live_close(close_b).destroy_none();

    vector[open_a, open_b, close_a_adjustment, close_b_adjustment].do_ref!(|adjustment| {
        if (adjustment.skew_is_charge()) {
            charged = charged + adjustment.skew_amount();
        } else {
            rebated = rebated + adjustment.skew_amount();
        };
    });

    assert_eq!(charged, rebated);
    assert_eq!(harness.exposure.skew_potential(), 0);

    cleanup(fx, oracle, harness);
}

fun mint_order(
    exposure: &mut StrikeExposure,
    pricer: &Pricer,
    lower: u64,
    higher: u64,
    quantity: u64,
): Order {
    let terms = exposure.quote_mint_terms(pricer, lower, higher, 0, quantity, true);
    exposure.allocate_mint_order(terms)
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
    new_harness_with_cadence(config, DAILY_CADENCE_MS)
}

fun new_harness_with_cadence(
    config: StrikeExposureConfig,
    cadence_period_ms: u64,
): (OracleFixture, OracleBundle, ExposureHarness) {
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
        cadence_period_ms,
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

/// Minting before the reference tick is recorded would fold into an empty window,
/// leaving the accumulators at zero while the book carries the order — and the
/// close would then subtract from zero and strand the position. The mint is gated
/// instead, and only while skew is on.
#[test, expected_failure(abort_code = strike_exposure::ESkewWindowUnavailable)]
fun mint_without_a_reference_tick_aborts_while_skew_is_on() {
    let (mut fx, oracle, mut harness) = enabled_harness_without_reference();
    let pricer = fx.load_pricer_bundle(&oracle);
    let (lower, higher) = upper_half();
    mint(&mut harness.exposure, &pricer, lower, higher, ONE_ORDER);
    abort 0
}

/// The same mint is fine with skew off, so the gate costs nothing at the shipped
/// rate.
#[test]
fun mint_without_a_reference_tick_is_allowed_while_skew_is_off() {
    let (mut fx, oracle, mut harness) = new_harness(strike_exposure_config::new());
    let pricer = fx.load_pricer_bundle(&oracle);
    let (lower, higher) = upper_half();
    mint(&mut harness.exposure, &pricer, lower, higher, ONE_ORDER);

    assert_eq!(harness.exposure.skew_potential(), 0);

    cleanup(fx, oracle, harness);
}

/// Collected charges must telescope to the current potential exactly. Flooring
/// each leg independently would leave the escrow below it, and the backing assert
/// would then abort a legitimate trade. Rate and quantities here are chosen so the
/// per-leg products truncate.
#[test]
fun collected_charges_track_the_potential_under_truncation() {
    let (mut fx, oracle, mut harness) = new_harness(skew_config(TRUNCATING_RATE));
    harness.exposure.set_reference_tick(test_constants::default_strike_tick());
    let pricer = fx.load_pricer_bundle(&oracle);
    let (lower, higher) = upper_half();

    // Flooring each leg independently gives 1 then 1, against a potential of 3.
    let mut collected = 0;
    let mut step = 0;
    while (step < 3) {
        let adjustment = harness.exposure.inventory_skew(lower, higher, ONE_ORDER, true);
        collected = collected + adjustment.skew_amount();
        mint(&mut harness.exposure, &pricer, lower, higher, ONE_ORDER);
        assert_eq!(collected, harness.exposure.skew_potential());
        step = step + 1;
    };
    assert!(collected > 0);

    cleanup(fx, oracle, harness);
}

/// The window scales with the square root of the tenor, so a longer cadence gives
/// a proportionally wider window. Linear scaling would put the hourly window at
/// 1/24th of the daily one rather than roughly a fifth.
#[test]
fun window_scales_with_the_square_root_of_the_tenor() {
    let (fx, oracle, mut harness) = new_harness_with_cadence(
        skew_config(SKEW_RATE),
        constants::one_hour_ms!(),
    );
    harness.exposure.set_reference_tick(test_constants::default_strike_tick());

    // sqrt(1/24) = 0.2041, so 10% * 0.2041 * reference tick 100 = 2 ticks either
    // side. Scaling linearly instead would give 1/24 of the daily fraction, whose
    // half-width truncates to 0. The daily case is pinned at 10 ticks by the
    // exact-deviation test, which depends on the window being 20 ticks wide.
    assert_eq!(harness.exposure.skew_window_half_width_for_testing(), 2);

    cleanup(fx, oracle, harness);
}
