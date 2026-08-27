// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit and production-flow coverage for expiry reference fine-grid ticks.
///
/// These tests cover immutable multi-cadence schedules, independent retryable
/// fills from exact Propbook Pyth history, and admission of any filled reference
/// even when it is off the coarser `admission_tick_size` grid.
#[test_only]
module deepbook_predict::reference_tick_tests;

use deepbook_predict::{
    constants,
    flow_test_helpers as helpers,
    market_manager,
    oracle_fixture::{Self, OracleFixture},
    order::Order,
    pricing::{Self, Pricer},
    pricing_reference_data as ref_data,
    protocol_config,
    strike_exposure::{Self, StrikeExposure},
    strike_exposure_config,
    test_constants
};
use propbook::{pyth_feed::PythFeed, registry::{Self as propbook_registry, OracleRegistry}};
use std::unit_test::assert_eq;
use sui::{object, test_scenario::return_shared};

const REFERENCE_TICK: u64 = 101;
const SHORTER_REFERENCE_TICK: u64 = 105;
const ADMISSIBLE_OFF_GRID_REFERENCE_TICK: u64 = 75_788;
const OTHER_OFF_GRID_TICK: u64 = 102;
const REFERENCE_SPOT_WITH_DUST: u64 = 101_123_456_789;
/// Floors to tick 105 — independently distinct from REFERENCE_SPOT_WITH_DUST's 101.
const SHORTER_REFERENCE_SPOT_WITH_DUST: u64 = 105_500_000_000;
const TINY_SPOT: u64 = 999_999_999;
const ROGUE_PYTH_SOURCE_ID: u32 = 999;
const REBOUND_PYTH_SOURCE_ID: u32 = 777;
const LARGE_VARIANCE_SCENARIO: u64 = 0;
const NATIVE_REFERENCE_INDEX: u64 = 0;
const SHORTER_REFERENCE_INDEX: u64 = 1;
const NATIVE_REFERENCE_SCHEDULE_LENGTH: u64 = 1;
const ALIGNED_REFERENCE_SCHEDULE_LENGTH: u64 = 2;
const NO_NEW_REFERENCE_TICKS: u64 = 0;
const ONE_NEW_REFERENCE_TICK: u64 = 1;
const EUnexpectedSuccess: u64 = 999;

public struct ExposureHarness has key {
    id: UID,
    exposure: StrikeExposure,
}

#[test]
fun set_reference_ticks_missing_exact_history_is_retryable() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let oracle = fx.take_oracle_bundle();
    let mut market = fx.take_expiry_market();
    fx.set_clock_for_testing(market.reference_tick_source_timestamp_ms());

    let added = market.set_reference_ticks(
        oracle_fixture::config(&oracle),
        oracle_fixture::oracle_registry(&oracle),
        oracle_fixture::pyth(&oracle),
        fx.clock(),
    );
    let references = market.reference_ticks();
    assert_eq!(added, NO_NEW_REFERENCE_TICKS);
    assert_eq!(references.length(), NATIVE_REFERENCE_SCHEDULE_LENGTH);
    assert!(strike_exposure::reference_tick_value(&references[NATIVE_REFERENCE_INDEX]).is_none());

    oracle_fixture::return_expiry_market(market);
    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

#[test, expected_failure(abort_code = pricing::EWrongPythFeed)]
fun set_reference_ticks_wrong_pyth_feed_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();

    let mut oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let rogue_pyth_id = propbook_registry::create_and_share_pyth_feed(
        &mut oracle_registry,
        ROGUE_PYTH_SOURCE_ID,
        fx.scenario_mut().ctx(),
    );
    return_shared(oracle_registry);

    fx.scenario_mut().next_tx(test_constants::admin());
    let rogue_pyth = fx.scenario_mut().take_shared_by_id<PythFeed>(rogue_pyth_id);
    let oracle_registry = fx.scenario_mut().take_shared<OracleRegistry>();
    let config = fx.scenario_mut().take_shared<deepbook_predict::protocol_config::ProtocolConfig>();
    let mut market = fx.take_expiry_market();
    fx.set_clock_for_testing(market.reference_tick_source_timestamp_ms());

    market.set_reference_ticks(&config, &oracle_registry, &rogue_pyth, fx.clock());
    abort EUnexpectedSuccess
}

#[test]
fun set_reference_ticks_floor_spot_and_report_idempotent_fills() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    let mut market = fx.take_expiry_market();
    let source_timestamp_ms = market.reference_tick_source_timestamp_ms();
    fx.set_clock_for_testing(source_timestamp_ms);
    assert_eq!(
        source_timestamp_ms,
        test_constants::default_expiry_ms() - test_constants::default_cadence_period_ms(),
    );

    fx.insert_exact_pyth_bundle(&mut oracle, REFERENCE_SPOT_WITH_DUST, source_timestamp_ms);
    let first_added = market.set_reference_ticks(
        oracle_fixture::config(&oracle),
        oracle_fixture::oracle_registry(&oracle),
        oracle_fixture::pyth(&oracle),
        fx.clock(),
    );
    let second_added = market.set_reference_ticks(
        oracle_fixture::config(&oracle),
        oracle_fixture::oracle_registry(&oracle),
        oracle_fixture::pyth(&oracle),
        fx.clock(),
    );

    let references = market.reference_ticks();
    assert_eq!(first_added, ONE_NEW_REFERENCE_TICK);
    assert_eq!(second_added, NO_NEW_REFERENCE_TICKS);
    assert_eq!(references.length(), NATIVE_REFERENCE_SCHEDULE_LENGTH);
    assert_eq!(
        strike_exposure::reference_tick_value(&references[NATIVE_REFERENCE_INDEX]).destroy_some(),
        REFERENCE_TICK,
    );
    assert_eq!(market.reference_tick().destroy_some(), REFERENCE_TICK);

    oracle_fixture::return_expiry_market(market);
    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

#[test]
fun set_reference_ticks_skip_filled_slot_after_feed_rebind() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    let mut market = fx.take_expiry_market();
    let source_timestamp_ms = market.reference_tick_source_timestamp_ms();
    fx.set_clock_for_testing(source_timestamp_ms);

    fx.insert_exact_pyth_bundle(&mut oracle, REFERENCE_SPOT_WITH_DUST, source_timestamp_ms);
    let first_added = market.set_reference_ticks(
        oracle_fixture::config(&oracle),
        oracle_fixture::oracle_registry(&oracle),
        oracle_fixture::pyth(&oracle),
        fx.clock(),
    );
    oracle_fixture::return_oracle_bundle(oracle);

    let rebound_ids = fx.create_and_rebind_oracle(REBOUND_PYTH_SOURCE_ID);
    let mut rebound = fx.take_oracle_bundle_by_ids(rebound_ids);
    fx.insert_exact_pyth_bundle(
        &mut rebound,
        SHORTER_REFERENCE_SPOT_WITH_DUST,
        source_timestamp_ms,
    );
    let second_added = market.set_reference_ticks(
        oracle_fixture::config(&rebound),
        oracle_fixture::oracle_registry(&rebound),
        oracle_fixture::pyth(&rebound),
        fx.clock(),
    );
    assert_eq!(first_added, ONE_NEW_REFERENCE_TICK);
    assert_eq!(second_added, NO_NEW_REFERENCE_TICKS);
    assert_eq!(market.reference_tick().destroy_some(), REFERENCE_TICK);

    oracle_fixture::return_expiry_market(market);
    oracle_fixture::return_oracle_bundle(rebound);
    fx.finish();
}

#[test]
fun set_reference_ticks_fill_unfilled_slot_from_rebound_feed() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut market = fx.take_expiry_market();
    let source_timestamp_ms = market.reference_tick_source_timestamp_ms();
    fx.set_clock_for_testing(source_timestamp_ms);

    let rebound_ids = fx.create_and_rebind_oracle(REBOUND_PYTH_SOURCE_ID);
    let mut rebound = fx.take_oracle_bundle_by_ids(rebound_ids);
    fx.insert_exact_pyth_bundle(
        &mut rebound,
        SHORTER_REFERENCE_SPOT_WITH_DUST,
        source_timestamp_ms,
    );
    let added = market.set_reference_ticks(
        oracle_fixture::config(&rebound),
        oracle_fixture::oracle_registry(&rebound),
        oracle_fixture::pyth(&rebound),
        fx.clock(),
    );
    assert_eq!(added, ONE_NEW_REFERENCE_TICK);
    assert_eq!(market.reference_tick().destroy_some(), SHORTER_REFERENCE_TICK);

    oracle_fixture::return_expiry_market(market);
    oracle_fixture::return_oracle_bundle(rebound);
    fx.finish();
}

#[test, expected_failure(abort_code = strike_exposure::EInvalidReferenceTick)]
fun set_reference_ticks_floor_to_zero_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    let mut market = fx.take_expiry_market();
    let source_timestamp_ms = market.reference_tick_source_timestamp_ms();
    fx.set_clock_for_testing(source_timestamp_ms);

    fx.insert_exact_pyth_bundle(&mut oracle, TINY_SPOT, source_timestamp_ms);
    market.set_reference_ticks(
        oracle_fixture::config(&oracle),
        oracle_fixture::oracle_registry(&oracle),
        oracle_fixture::pyth(&oracle),
        fx.clock(),
    );
    abort EUnexpectedSuccess
}

#[test]
fun cadence_reference_ticks_fill_due_slots_independently() {
    let mut fx = helpers::setup_market_default();
    fx.set_default_terms_for_cadence(market_manager::cadence_five_minute!());
    fx.set_clock_for_testing(constants::five_minutes_ms!());
    let expiry_id = fx.create_next_expiry_for_cadence(market_manager::cadence_five_minute!());
    let mut market = fx.take_market_bundle(expiry_id);
    let expiry = helpers::market(&market).expiry();
    let native_source_timestamp_ms = expiry - constants::five_minutes_ms!();
    let shorter_source_timestamp_ms = expiry - constants::one_minute_ms!();

    let initial_references = helpers::market(&market).reference_ticks();
    assert_eq!(initial_references.length(), ALIGNED_REFERENCE_SCHEDULE_LENGTH);
    assert_eq!(
        strike_exposure::source_timestamp_ms(&initial_references[NATIVE_REFERENCE_INDEX]),
        native_source_timestamp_ms,
    );
    assert_eq!(
        strike_exposure::source_timestamp_ms(&initial_references[SHORTER_REFERENCE_INDEX]),
        shorter_source_timestamp_ms,
    );
    assert!(
        strike_exposure::reference_tick_value(
            &initial_references[NATIVE_REFERENCE_INDEX],
        ).is_none(),
    );
    assert!(
        strike_exposure::reference_tick_value(
            &initial_references[SHORTER_REFERENCE_INDEX],
        ).is_none(),
    );

    assert_eq!(fx.set_reference_ticks_bundle(&mut market), NO_NEW_REFERENCE_TICKS);

    fx.set_clock_for_testing(shorter_source_timestamp_ms);
    fx.insert_exact_pyth_spot_bundle(
        &mut market,
        SHORTER_REFERENCE_SPOT_WITH_DUST,
        shorter_source_timestamp_ms,
    );
    assert_eq!(fx.set_reference_ticks_bundle(&mut market), ONE_NEW_REFERENCE_TICK);
    assert_eq!(fx.set_reference_ticks_bundle(&mut market), NO_NEW_REFERENCE_TICKS);
    let shorter_filled = helpers::market(&market).reference_ticks();
    assert!(
        strike_exposure::reference_tick_value(
            &shorter_filled[NATIVE_REFERENCE_INDEX],
        ).is_none(),
    );
    assert_eq!(
        strike_exposure::reference_tick_value(
            &shorter_filled[SHORTER_REFERENCE_INDEX],
        ).destroy_some(),
        SHORTER_REFERENCE_TICK,
    );
    assert!(helpers::market(&market).reference_tick().is_none());

    fx.insert_exact_pyth_spot_bundle(
        &mut market,
        REFERENCE_SPOT_WITH_DUST,
        native_source_timestamp_ms,
    );
    assert_eq!(fx.set_reference_ticks_bundle(&mut market), ONE_NEW_REFERENCE_TICK);
    assert_eq!(fx.set_reference_ticks_bundle(&mut market), NO_NEW_REFERENCE_TICKS);
    let all_filled = helpers::market(&market).reference_ticks();
    assert_eq!(
        strike_exposure::reference_tick_value(&all_filled[NATIVE_REFERENCE_INDEX]).destroy_some(),
        REFERENCE_TICK,
    );
    assert_eq!(
        strike_exposure::reference_tick_value(&all_filled[SHORTER_REFERENCE_INDEX]).destroy_some(),
        SHORTER_REFERENCE_TICK,
    );
    assert_eq!(helpers::market(&market).reference_tick().destroy_some(), REFERENCE_TICK);

    helpers::return_market_bundle(market);
    fx.finish();
}

#[test, expected_failure(abort_code = protocol_config::EValuationInProgress)]
fun set_reference_ticks_during_valuation_aborts() {
    let mut fx = helpers::setup_market_default();
    let expiry_id = fx.create_expiry(test_constants::default_expiry_ms());
    let mut market = fx.take_market_bundle(expiry_id);
    helpers::begin_valuation(&mut market);

    fx.set_reference_ticks_bundle(&mut market);
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
    assert!(
        harness
            .exposure
            .set_reference_tick(SHORTER_REFERENCE_INDEX, ADMISSIBLE_OFF_GRID_REFERENCE_TICK),
    );
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

    assert!(harness.exposure.set_reference_tick(NATIVE_REFERENCE_INDEX, REFERENCE_TICK));
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
        vector[fx.expiry() - test_constants::default_cadence_period_ms(), fx.expiry()],
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
