// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for expiry reference fine-grid ticks.
///
/// These tests cover the source-contract behavior only: deriving a market's
/// reference tick from exact Propbook Pyth history, storing it idempotently, and
/// admitting that tick as a mint boundary even when it is off the coarser
/// `admission_tick_size` grid.
#[test_only]
module deepbook_predict::reference_tick_tests;

use deepbook_predict::{
    constants,
    expiry_market,
    oracle_fixture::{Self, OracleFixture},
    order::Order,
    pricing::{Self, Pricer},
    pricing_reference_data as ref_data,
    signed_data,
    strike_exposure::{Self, StrikeExposure},
    strike_exposure_config,
    test_constants,
    test_helpers
};
use deepbook_predict_math::lazer_price;
use std::unit_test::assert_eq;
use sui::{object, test_scenario::return_shared};

const REFERENCE_TICK: u64 = 101;
const ADMISSIBLE_OFF_GRID_REFERENCE_TICK: u64 = 75_788;
const OTHER_OFF_GRID_TICK: u64 = 102;
const REFERENCE_SPOT_WITH_DUST: u64 = 101_123_456_789;
/// Floors to tick 105 — a different reference tick than REFERENCE_SPOT_WITH_DUST's 101.
const CONFLICTING_REFERENCE_SPOT: u64 = 105_500_000_000;
const TINY_SPOT: u64 = 999_999_999;
const ROGUE_PYTH_SOURCE_ID: u32 = 999;
const REBOUND_PYTH_SOURCE_ID: u32 = 777;
const LARGE_VARIANCE_SCENARIO: u64 = 0;
const EUnexpectedSuccess: u64 = 999;
const US_PER_MS: u64 = 1_000;
const CHANNEL_50MS: u8 = 2;
const TICK_200_MS: u64 = 200;
/// `constants::max_settlement_carry_ms!()`, the longest carry a settlement-grade print may have.
const MAX_CARRY_MS: u64 = 2_000;
const SVI_DECIMALS: u8 = 9;

public struct ExposureHarness has key {
    id: UID,
    exposure: StrikeExposure,
}

#[test, expected_failure(abort_code = expiry_market::EUseV2)]
fun set_reference_tick_is_retired() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    let mut market = fx.take_expiry_market();
    let source_timestamp_ms = market.reference_tick_source_timestamp_ms();

    fx.insert_exact_pyth_bundle(&mut oracle, REFERENCE_SPOT_WITH_DUST, source_timestamp_ms);
    market.set_reference_tick(
        oracle_fixture::config(&oracle),
        oracle_fixture::oracle_registry(&oracle),
        oracle_fixture::pyth(&oracle),
        fx.clock(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = expiry_market::EReferenceTickObservationMissing)]
fun set_reference_tick_without_a_price_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let oracle = fx.take_oracle_bundle();
    let mut market = fx.take_expiry_market();

    market.set_reference_tick_v2(oracle_fixture::config(&oracle), option::none(), fx.clock());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = expiry_market::EReferenceTickObservationMissing)]
fun set_reference_tick_another_feed_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let oracle = fx.take_oracle_bundle();
    let mut market = fx.take_expiry_market();
    let source_us = market.reference_tick_source_timestamp_ms() * US_PER_MS;

    let rogue = lazer_price::new_for_testing(
        ROGUE_PYTH_SOURCE_ID,
        test_helpers::binding_channel(),
        source_us,
        source_us,
        REFERENCE_SPOT_WITH_DUST,
    );
    market.set_reference_tick_v2(oracle_fixture::config(&oracle), option::some(rogue), fx.clock());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = expiry_market::EReferenceTickObservationMissing)]
fun set_reference_tick_another_channel_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let oracle = fx.take_oracle_bundle();
    let mut market = fx.take_expiry_market();
    let source_us = market.reference_tick_source_timestamp_ms() * US_PER_MS;

    // The 50 ms channel also ticks at the period start, but the binding pins 200 ms.
    let fast = lazer_price::new_for_testing(
        test_constants::pyth_feed_id(),
        CHANNEL_50MS,
        source_us,
        source_us,
        REFERENCE_SPOT_WITH_DUST,
    );
    market.set_reference_tick_v2(oracle_fixture::config(&oracle), option::some(fast), fx.clock());
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = expiry_market::EReferenceTickObservationMissing)]
fun set_reference_tick_one_tick_late_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let oracle = fx.take_oracle_bundle();
    let mut market = fx.take_expiry_market();
    let source_ms = market.reference_tick_source_timestamp_ms();

    // The next 200 ms tick after the period start is not the period start's price.
    let late = signed_data::lazer_at(source_ms + TICK_200_MS, REFERENCE_SPOT_WITH_DUST);
    market.set_reference_tick_v2(oracle_fixture::config(&oracle), option::some(late), fx.clock());
    abort EUnexpectedSuccess
}

/// A price generated more than `max_settlement_carry_ms` (2 s) before its envelope cannot set
/// the tick, as Propbook's exact rows refused one. Exactly 2 s is accepted.
#[test]
fun set_reference_tick_accepts_a_carry_of_exactly_two_seconds_only() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let oracle = fx.take_oracle_bundle();
    let mut market = fx.take_expiry_market();
    let source_us = market.reference_tick_source_timestamp_ms() * US_PER_MS;
    let carried = lazer_price::new_for_testing(
        test_constants::pyth_feed_id(),
        test_helpers::binding_channel(),
        source_us,
        source_us - MAX_CARRY_MS * US_PER_MS,
        REFERENCE_SPOT_WITH_DUST,
    );
    let tick = market.set_reference_tick_v2(
        oracle_fixture::config(&oracle),
        option::some(carried),
        fx.clock(),
    );
    assert_eq!(tick, REFERENCE_TICK);

    oracle_fixture::return_expiry_market(market);
    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

#[test, expected_failure(abort_code = expiry_market::EReferenceTickObservationMissing)]
fun set_reference_tick_with_a_carry_past_two_seconds_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let oracle = fx.take_oracle_bundle();
    let mut market = fx.take_expiry_market();
    let source_us = market.reference_tick_source_timestamp_ms() * US_PER_MS;

    let stale = lazer_price::new_for_testing(
        test_constants::pyth_feed_id(),
        test_helpers::binding_channel(),
        source_us,
        source_us - (MAX_CARRY_MS + 1) * US_PER_MS,
        REFERENCE_SPOT_WITH_DUST,
    );
    market.set_reference_tick_v2(oracle_fixture::config(&oracle), option::some(stale), fx.clock());
    abort EUnexpectedSuccess
}

#[test]
fun set_reference_tick_floors_spot_and_is_idempotent() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let oracle = fx.take_oracle_bundle();
    let mut market = fx.take_expiry_market();
    let source_timestamp_ms = market.reference_tick_source_timestamp_ms();
    assert_eq!(
        source_timestamp_ms,
        test_constants::default_expiry_ms() - test_constants::default_cadence_period_ms(),
    );

    let price = signed_data::lazer_at(source_timestamp_ms, REFERENCE_SPOT_WITH_DUST);
    let first_tick = market.set_reference_tick_v2(
        oracle_fixture::config(&oracle),
        option::some(price),
        fx.clock(),
    );
    let second_tick = market.set_reference_tick_v2(
        oracle_fixture::config(&oracle),
        option::some(price),
        fx.clock(),
    );

    assert_eq!(first_tick, REFERENCE_TICK);
    assert_eq!(second_tick, REFERENCE_TICK);
    assert_eq!(market.reference_tick().destroy_some(), REFERENCE_TICK);

    oracle_fixture::return_expiry_market(market);
    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// A second reference-tick set can only derive a CONFLICTING value if the oracle
/// binding moved to another feed in between: the signed print at one timestamp is
/// unique per feed and channel. The second set aborts instead of silently moving the
/// tick.
#[test, expected_failure(abort_code = strike_exposure::EReferenceTickAlreadySet)]
fun set_reference_tick_conflicting_value_after_rebind_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    let mut market = fx.take_expiry_market();
    let source_timestamp_ms = market.reference_tick_source_timestamp_ms();

    market.set_reference_tick_v2(
        oracle_fixture::config(&oracle),
        option::some(signed_data::lazer_at(source_timestamp_ms, REFERENCE_SPOT_WITH_DUST)),
        fx.clock(),
    );

    oracle_fixture::config_mut(&mut oracle).set_oracle_binding(
        fx.admin_cap(),
        test_constants::propbook_underlying_id(),
        REBOUND_PYTH_SOURCE_ID,
        test_helpers::binding_channel(),
        test_constants::block_scholes_base_asset(),
        test_helpers::binding_svi_model(),
        SVI_DECIMALS,
        fx.clock(),
    );
    let source_us = source_timestamp_ms * US_PER_MS;
    let rebound = lazer_price::new_for_testing(
        REBOUND_PYTH_SOURCE_ID,
        test_helpers::binding_channel(),
        source_us,
        source_us,
        CONFLICTING_REFERENCE_SPOT,
    );
    market.set_reference_tick_v2(
        oracle_fixture::config(&oracle),
        option::some(rebound),
        fx.clock(),
    );

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = strike_exposure::EInvalidReferenceTick)]
fun set_reference_tick_floor_to_zero_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let oracle = fx.take_oracle_bundle();
    let mut market = fx.take_expiry_market();
    let source_timestamp_ms = market.reference_tick_source_timestamp_ms();

    market.set_reference_tick_v2(
        oracle_fixture::config(&oracle),
        option::some(signed_data::lazer_at(source_timestamp_ms, TINY_SPOT)),
        fx.clock(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = strike_exposure::EInvalidAdmissionTick)]
fun off_grid_tick_before_reference_tick_is_set_aborts() {
    let (_fx, pricer, mut harness) = setup_priced_harness();

    let terms = harness
        .exposure
        .quote_mint_terms(
            &pricer,
            REFERENCE_TICK,
            constants::pos_inf_tick!(),
            0,
            test_constants::mint_quantity(),
            true,
        );
    harness.exposure.allocate_mint_order(terms);
    abort EUnexpectedSuccess
}

#[test]
fun reference_tick_admits_up_and_down_ranges() {
    let (fx, pricer, mut harness) = setup_priced_harness();

    assert_reference_tick_is_off_admission_grid(ADMISSIBLE_OFF_GRID_REFERENCE_TICK);
    harness.exposure.set_reference_tick(ADMISSIBLE_OFF_GRID_REFERENCE_TICK);
    let up_terms = harness
        .exposure
        .quote_mint_terms(
            &pricer,
            ADMISSIBLE_OFF_GRID_REFERENCE_TICK,
            constants::pos_inf_tick!(),
            0,
            test_constants::mint_quantity(),
            true,
        );
    let up_order = harness.exposure.allocate_mint_order(up_terms);
    let down_terms = harness
        .exposure
        .quote_mint_terms(
            &pricer,
            0,
            ADMISSIBLE_OFF_GRID_REFERENCE_TICK,
            0,
            test_constants::mint_quantity(),
            true,
        );
    let down_order = harness.exposure.allocate_mint_order(down_terms);

    assert_range(&up_order, ADMISSIBLE_OFF_GRID_REFERENCE_TICK, constants::pos_inf_tick!());
    assert_range(&down_order, 0, ADMISSIBLE_OFF_GRID_REFERENCE_TICK);

    cleanup_priced_harness(fx, harness);
}

#[test, expected_failure(abort_code = strike_exposure::EInvalidAdmissionTick)]
fun different_off_grid_tick_after_reference_tick_is_set_aborts() {
    let (_fx, pricer, mut harness) = setup_priced_harness();

    harness.exposure.set_reference_tick(REFERENCE_TICK);
    let terms = harness
        .exposure
        .quote_mint_terms(
            &pricer,
            OTHER_OFF_GRID_TICK,
            constants::pos_inf_tick!(),
            0,
            test_constants::mint_quantity(),
            true,
        );
    harness.exposure.allocate_mint_order(terms);
    abort EUnexpectedSuccess
}

fun setup_priced_harness(): (OracleFixture, Pricer, ExposureHarness) {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        ref_data::spot(LARGE_VARIANCE_SCENARIO),
        ref_data::forward(LARGE_VARIANCE_SCENARIO),
        ref_data::svi_a(LARGE_VARIANCE_SCENARIO),
        false,
        ref_data::svi_b(LARGE_VARIANCE_SCENARIO),
        ref_data::svi_sigma(LARGE_VARIANCE_SCENARIO),
        ref_data::svi_rho_magnitude(LARGE_VARIANCE_SCENARIO),
        ref_data::svi_rho_is_negative(LARGE_VARIANCE_SCENARIO),
        ref_data::svi_m_magnitude(LARGE_VARIANCE_SCENARIO),
        ref_data::svi_m_is_negative(LARGE_VARIANCE_SCENARIO),
    );
    let pricer = fx.load_pricer_bundle(&oracle);
    oracle_fixture::return_oracle_bundle(oracle);
    let harness_id = create_and_share_exposure_harness(&mut fx);
    fx.scenario_mut().next_tx(test_constants::admin());
    let harness = fx.scenario_mut().take_shared_by_id<ExposureHarness>(harness_id);

    (fx, pricer, harness)
}

fun create_and_share_exposure_harness(fx: &mut OracleFixture): ID {
    let id = object::new(fx.scenario_mut().ctx());
    let harness_id = id.to_inner();
    let exposure = strike_exposure::new(
        fx.expiry_id(),
        strike_exposure_config::new(),
        test_constants::default_tick_size(),
        test_constants::default_admission_tick_size(),
        fx.expiry() - test_constants::default_cadence_period_ms(),
        1_000_000_000,
        fx.scenario_mut().ctx(),
    );
    transfer::share_object(ExposureHarness { id, exposure });
    harness_id
}

fun cleanup_priced_harness(fx: OracleFixture, harness: ExposureHarness) {
    return_shared(harness);
    fx.finish();
}

fun assert_range(order: &Order, lower_tick: u64, higher_tick: u64) {
    assert_eq!(order.lower_tick(), lower_tick);
    assert_eq!(order.higher_tick(), higher_tick);
}

fun assert_reference_tick_is_off_admission_grid(reference_tick: u64) {
    assert!(
        (reference_tick * test_constants::default_tick_size())
            % test_constants::default_admission_tick_size()
            != 0,
    );
}
