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
    pricing::Pricer,
    pricing_reference_data as ref_data,
    strike_exposure::{Self, StrikeExposure},
    strike_exposure_config,
    test_constants
};
use propbook::{pyth_feed::PythFeed, registry::{Self as propbook_registry, OracleRegistry}};
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

public struct ExposureHarness has key {
    id: UID,
    exposure: StrikeExposure,
}

#[test, expected_failure(abort_code = expiry_market::EReferenceTickObservationMissing)]
fun set_reference_tick_missing_exact_history_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let oracle = fx.take_oracle_bundle();
    let mut market = fx.take_expiry_market();

    market.set_reference_tick(
        oracle_fixture::config(&oracle),
        oracle_fixture::oracle_registry(&oracle),
        oracle_fixture::pyth(&oracle),
        fx.clock(),
    );
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = expiry_market::EWrongPythFeed)]
fun set_reference_tick_wrong_pyth_feed_aborts() {
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

    market.set_reference_tick(&config, &oracle_registry, &rogue_pyth, fx.clock());
    abort EUnexpectedSuccess
}

#[test]
fun set_reference_tick_floors_spot_and_is_idempotent() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    let mut market = fx.take_expiry_market();
    let source_timestamp_ms = market.reference_tick_source_timestamp_ms();
    assert_eq!(
        source_timestamp_ms,
        test_constants::default_expiry_ms() - test_constants::default_cadence_period_ms(),
    );

    fx.insert_exact_pyth_bundle(&mut oracle, REFERENCE_SPOT_WITH_DUST, source_timestamp_ms);
    let first_tick = market.set_reference_tick(
        oracle_fixture::config(&oracle),
        oracle_fixture::oracle_registry(&oracle),
        oracle_fixture::pyth(&oracle),
        fx.clock(),
    );
    let second_tick = market.set_reference_tick(
        oracle_fixture::config(&oracle),
        oracle_fixture::oracle_registry(&oracle),
        oracle_fixture::pyth(&oracle),
        fx.clock(),
    );

    assert_eq!(first_tick, REFERENCE_TICK);
    assert_eq!(second_tick, REFERENCE_TICK);
    assert_eq!(market.reference_tick().destroy_some(), REFERENCE_TICK);

    oracle_fixture::return_expiry_market(market);
    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// A second reference-tick set can only derive a CONFLICTING value if the canonical
/// Pyth binding was replaced in between (the exact-history print itself is
/// first-write-wins). The replacement feed carries a different exact print at the
/// reference timestamp, so the second set aborts instead of silently moving the tick.
#[test, expected_failure(abort_code = strike_exposure::EReferenceTickAlreadySet)]
fun set_reference_tick_conflicting_value_after_rebind_aborts() {
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
    oracle_fixture::return_oracle_bundle(oracle);

    let rebound_ids = fx.create_and_rebind_oracle(REBOUND_PYTH_SOURCE_ID);
    let mut rebound = fx.take_oracle_bundle_by_ids(rebound_ids);
    fx.insert_exact_pyth_bundle(&mut rebound, CONFLICTING_REFERENCE_SPOT, source_timestamp_ms);
    market.set_reference_tick(
        oracle_fixture::config(&rebound),
        oracle_fixture::oracle_registry(&rebound),
        oracle_fixture::pyth(&rebound),
        fx.clock(),
    );

    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = strike_exposure::EInvalidReferenceTick)]
fun set_reference_tick_floor_to_zero_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    let mut market = fx.take_expiry_market();
    let source_timestamp_ms = market.reference_tick_source_timestamp_ms();

    fx.insert_exact_pyth_bundle(&mut oracle, TINY_SPOT, source_timestamp_ms);
    market.set_reference_tick(
        oracle_fixture::config(&oracle),
        oracle_fixture::oracle_registry(&oracle),
        oracle_fixture::pyth(&oracle),
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
            test_constants::mint_quantity(),
            test_constants::leverage_one_x(),
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
            test_constants::mint_quantity(),
            test_constants::leverage_one_x(),
        );
    let up_order = harness.exposure.allocate_mint_order(up_terms);
    let down_terms = harness
        .exposure
        .quote_mint_terms(
            &pricer,
            0,
            ADMISSIBLE_OFF_GRID_REFERENCE_TICK,
            test_constants::mint_quantity(),
            test_constants::leverage_one_x(),
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
            test_constants::mint_quantity(),
            test_constants::leverage_one_x(),
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
        fx.expiry(),
        test_constants::default_tick_size(),
        test_constants::default_admission_tick_size(),
        fx.expiry() - test_constants::default_cadence_period_ms(),
        strike_exposure_config::new(),
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
