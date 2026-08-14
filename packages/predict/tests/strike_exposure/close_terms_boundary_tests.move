// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Boundary coverage for the `CloseTerms` token that `quote_close` produces and
/// `process_close` consumes: the three abort codes on the close path
/// (`EPricerRequired`, `ETermsExposureMismatch`, `EWrongCloseOutcome`), and the
/// derived-liquidated-state guard that keeps a never-indexed 1x order — absent
/// from the active index by construction — off the liquidated arm.
#[test_only]
module deepbook_predict::close_terms_boundary_tests;

use deepbook_predict::{
    constants,
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    order::Order,
    strike_exposure::{Self, StrikeExposure},
    strike_exposure_config,
    test_constants
};
use sui::object::{Self, UID};

public struct ExposureHarness has key {
    id: UID,
    exposure: StrikeExposure,
}

/// The close terms carry the exposure book they were quoted on; consuming A's
/// terms on exposure B aborts `ETermsExposureMismatch` before any book mutation,
/// so a close can never cross markets.
#[test, expected_failure(abort_code = strike_exposure::ETermsExposureMismatch)]
fun process_close_of_terms_quoted_on_another_exposure_aborts() {
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
    let mut harness_a = fx.scenario_mut().take_shared_by_id<ExposureHarness>(harness_a_id);
    let mut harness_b = fx.scenario_mut().take_shared_by_id<ExposureHarness>(harness_b_id);
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let pricer = fx.load_pricer_bundle(&oracle);

    // Mint a 1x order on A and quote its live close: the terms carry A's market id.
    let terms_a = harness_a
        .exposure
        .quote_mint_terms(
            &pricer,
            test_constants::default_strike_tick(),
            constants::pos_inf_tick!(),
            0,
            test_constants::mint_quantity(),
            true,
        );
    let order = harness_a.exposure.allocate_mint_order(terms_a);
    let close_terms = harness_a
        .exposure
        .quote_close(option::some(pricer), &order, order.quantity());

    // Consuming A's close terms on exposure B must abort.
    harness_b.exposure.process_close(close_terms);

    abort 999
}

fun fresh_object_id(fx: &mut OracleFixture): ID {
    let id = object::new(fx.scenario_mut().ctx());
    let inner = id.to_inner();
    id.delete();
    inner
}

fun create_and_share_exposure_harness(
    fx: &mut OracleFixture,
    expiry_market_id: ID,
    expiry_ms: u64,
): ID {
    let id = object::new(fx.scenario_mut().ctx());
    let harness_id = id.to_inner();
    let config = strike_exposure_config::new();
    let exposure = strike_exposure::new(
        expiry_market_id,
        expiry_ms,
        test_constants::default_tick_size(),
        test_constants::default_tick_size(),
        expiry_ms - test_constants::default_cadence_period_ms(),
        1_000_000_000,
        config,
        fx.scenario_mut().ctx(),
    );
    transfer::share_object(ExposureHarness { id, exposure });
    harness_id
}
