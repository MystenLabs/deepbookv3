// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Window enforcement for the snapshotted 900-wide finite-tick band.
#[test_only]
module deepbook_predict::strike_band_window_tests;

use deepbook_predict::{
    constants,
    oracle_fixture::{Self, OracleFixture},
    strike_exposure::{Self, StrikeExposure},
    strike_exposure_config,
    test_constants
};
use sui::{object, test_scenario::return_shared};

const BANDED_MIN_TICK: u64 = 100;
const BELOW_BAND_TICK: u64 = 99;
const ABOVE_BAND_TICK: u64 = 1_000;
const ON_GRID_OUT_OF_BAND_TICK: u64 = 910;
const EUnexpectedSuccess: u64 = 999;

public struct ExposureHarness has key {
    id: UID,
    exposure: StrikeExposure,
}

#[test, expected_failure(abort_code = strike_exposure::EStrikeTickOutOfBand)]
fun set_reference_tick_below_min_tick_aborts() {
    let (_fx, mut harness) = setup_banded_harness();
    harness.exposure.set_reference_tick(BELOW_BAND_TICK);
    abort EUnexpectedSuccess
}

#[test, expected_failure(abort_code = strike_exposure::EStrikeTickOutOfBand)]
fun set_reference_tick_above_window_aborts() {
    let (_fx, mut harness) = setup_banded_harness();
    harness.exposure.set_reference_tick(ABOVE_BAND_TICK);
    abort EUnexpectedSuccess
}

#[test]
fun set_reference_tick_at_min_tick_records() {
    let (fx, mut harness) = setup_banded_harness();
    let min_tick = BANDED_MIN_TICK;
    assert!(harness.exposure.set_reference_tick(min_tick));
    assert!(harness.exposure.reference_tick().contains(&min_tick));
    cleanup(fx, harness);
}

#[test, expected_failure(abort_code = strike_exposure::EStrikeTickOutOfBand)]
fun mint_on_grid_tick_outside_default_window_aborts() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let pricer = fx.load_pricer_bundle(&oracle);
    let harness_id = create_default_harness(&mut fx);
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut harness = fx.scenario_mut().take_shared_by_id<ExposureHarness>(harness_id);
    let terms = harness
        .exposure
        .quote_mint_terms(
            &pricer,
            ON_GRID_OUT_OF_BAND_TICK,
            constants::pos_inf_tick!(),
            0,
            test_constants::mint_quantity(),
            true,
            test_constants::leverage_one_x(),
            fx.clock(),
        );
    harness.exposure.allocate_mint_order(terms);
    abort EUnexpectedSuccess
}

fun setup_banded_harness(): (OracleFixture, ExposureHarness) {
    let mut fx = oracle_fixture::setup_oracle_default();
    let harness_id = create_harness(&mut fx, BANDED_MIN_TICK);
    fx.scenario_mut().next_tx(test_constants::admin());
    let harness = fx.scenario_mut().take_shared_by_id<ExposureHarness>(harness_id);
    (fx, harness)
}

fun create_default_harness(fx: &mut OracleFixture): ID {
    create_harness(fx, 1)
}

fun create_harness(fx: &mut OracleFixture, min_tick: u64): ID {
    let id = object::new(fx.scenario_mut().ctx());
    let harness_id = id.to_inner();
    let exposure = strike_exposure::new(
        fx.expiry_id(),
        fx.expiry(),
        test_constants::default_tick_size(),
        test_constants::default_admission_tick_size(),
        min_tick,
        fx.expiry() - test_constants::default_cadence_period_ms(),
        strike_exposure_config::new(),
        fx.scenario_mut().ctx(),
    );
    transfer::share_object(ExposureHarness { id, exposure });
    harness_id
}

fun cleanup(fx: OracleFixture, harness: ExposureHarness) {
    return_shared(harness);
    fx.finish();
}
