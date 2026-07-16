// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pins the MintTerms↔exposure binding: terms priced on one exposure book
/// cannot allocate on another (`ETermsExposureMismatch`), so the pure quote
/// checkpoint can never cross markets.
#[test_only]
module deepbook_predict::mint_terms_binding_tests;

use deepbook_predict::{
    constants,
    oracle_fixture,
    strike_exposure::{Self, StrikeExposure},
    strike_exposure_config,
    test_constants
};
use sui::object::{Self, UID};

public struct ExposureHarness has key {
    id: UID,
    exposure: StrikeExposure,
}

#[test, expected_failure(abort_code = strike_exposure::ETermsExposureMismatch)]
fun allocating_terms_priced_on_another_exposure_aborts() {
    let mut fx = oracle_fixture::setup_oracle(
        test_constants::default_live_price(),
        test_constants::default_tick_size(),
        test_constants::short_expiry_ms(),
    );
    let expiry_id = fx.expiry_id();
    let expiry_ms = fx.expiry();
    fx.scenario_mut().next_tx(test_constants::admin());
    let harness_a_id = create_and_share_exposure_harness(&mut fx, expiry_id, expiry_ms);
    let other_market_id = fresh_object_id(&mut fx);
    let harness_b_id = create_and_share_exposure_harness(&mut fx, other_market_id, expiry_ms);

    fx.scenario_mut().next_tx(test_constants::admin());
    let harness_a = fx.scenario_mut().take_shared_by_id<ExposureHarness>(harness_a_id);
    let mut harness_b = fx.scenario_mut().take_shared_by_id<ExposureHarness>(harness_b_id);
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let pricer = fx.load_pricer_bundle(&oracle);

    let terms = harness_a
        .exposure
        .quote_mint_terms(
            &pricer,
            test_constants::default_strike_tick(),
            constants::pos_inf_tick!(),
            0,
            test_constants::mint_quantity(),
            true,
            test_constants::leverage_one_x(),
        );
    harness_b.exposure.allocate_mint_order(terms);

    abort 999
}

fun create_and_share_exposure_harness(
    fx: &mut oracle_fixture::OracleFixture,
    expiry_market_id: ID,
    expiry_ms: u64,
): ID {
    let id = object::new(fx.scenario_mut().ctx());
    let harness_id = id.to_inner();
    let exposure = strike_exposure::new(
        expiry_market_id,
        expiry_ms,
        test_constants::default_tick_size(),
        test_constants::default_tick_size(),
        expiry_ms - test_constants::default_cadence_period_ms(),
        strike_exposure_config::new(),
        fx.scenario_mut().ctx(),
    );
    transfer::share_object(ExposureHarness { id, exposure });
    harness_id
}

fun fresh_object_id(fx: &mut oracle_fixture::OracleFixture): ID {
    let id = object::new(fx.scenario_mut().ctx());
    let inner = id.to_inner();
    id.delete();
    inner
}
