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
use sui::{object::{Self, UID}, test_scenario::return_shared};

public struct ExposureHarness has key {
    id: UID,
    exposure: StrikeExposure,
}

const LEVERAGE_TWO_X: u64 = 2_000_000_000;

/// A live, unsettled, non-liquidated close is the only outcome that needs the
/// pricer: the liquidated and settled arms return before the assert, so quoting
/// this fresh live 2x order with no pricer aborts `EPricerRequired`.
#[test, expected_failure(abort_code = strike_exposure::EPricerRequired)]
fun quote_live_close_without_pricer_aborts() {
    let (fx, oracle, harness, order) = live_exposure(LEVERAGE_TWO_X);
    harness.exposure.quote_close(option::none(), &order, order.quantity());
    abort 999
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
            test_constants::leverage_one_x(),
            fx.clock(),
        );
    let order = harness_a.exposure.allocate_mint_order(terms_a);
    let close_terms = harness_a
        .exposure
        .quote_close(option::some(pricer), &order, order.quantity());

    // Consuming A's close terms on exposure B must abort.
    harness_b.exposure.process_close(option::some(pricer), close_terms, fx.clock());

    abort 999
}

/// The outcome accessors reject the wrong arm: reading the settled payout of a
/// live close aborts `EWrongCloseOutcome`, so a caller cannot misread a live
/// close as a settled one.
#[test, expected_failure(abort_code = strike_exposure::EWrongCloseOutcome)]
fun settled_payout_of_live_close_terms_aborts() {
    let (fx, oracle, harness, order) = live_exposure(LEVERAGE_TWO_X);
    let pricer = fx.load_pricer_bundle(&oracle);
    let terms = harness.exposure.quote_close(option::some(pricer), &order, order.quantity());
    assert!(terms.is_live());
    terms.settled_payout();
    abort 999
}

/// The derived liquidated state applies only to a *leveraged* order missing from
/// the active index. A 1x order carries no financed floor, so it is never indexed
/// (`insert_order`/`contains_active_order` are no-ops for it) — index-absence is
/// its normal live state, not liquidation. The classifier's leveraged-only guard
/// keeps it on the live arm.
#[test]
fun one_x_order_absent_from_index_stays_live_not_liquidated() {
    let (fx, oracle, harness, order) = live_exposure(test_constants::leverage_one_x());

    assert!(!order.is_leveraged());
    assert!(!harness.exposure.is_active_order(&order));

    let pricer = fx.load_pricer_bundle(&oracle);
    let terms = harness.exposure.quote_close(option::some(pricer), &order, order.quantity());
    assert!(terms.is_live());
    assert!(!terms.is_liquidated());

    cleanup(fx, oracle, harness);
}

/// Build a single exposure book and mint one live order at `leverage` through the
/// real quote/allocate path, returning the fixture, oracle bundle, shared harness,
/// and the minted order.
fun live_exposure(leverage: u64): (OracleFixture, OracleBundle, ExposureHarness, Order) {
    let mut fx = oracle_fixture::setup_oracle(
        test_constants::default_live_price(),
        test_constants::default_tick_size(),
        test_constants::short_expiry_ms(),
    );
    let expiry_id = fx.expiry_id();
    let expiry_ms = fx.expiry();
    fx.scenario_mut().next_tx(test_constants::admin());
    let harness_id = create_and_share_exposure_harness(&mut fx, expiry_id, expiry_ms);
    fx.scenario_mut().next_tx(test_constants::admin());
    let mut harness = fx.scenario_mut().take_shared_by_id<ExposureHarness>(harness_id);
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());

    let pricer = fx.load_pricer_bundle(&oracle);
    let terms = harness
        .exposure
        .quote_mint_terms(
            &pricer,
            test_constants::default_strike_tick(),
            constants::pos_inf_tick!(),
            0,
            test_constants::mint_quantity(),
            true,
            leverage,
            fx.clock(),
        );
    let order = harness.exposure.allocate_mint_order(terms);

    (fx, oracle, harness, order)
}

fun create_and_share_exposure_harness(
    fx: &mut OracleFixture,
    expiry_market_id: ID,
    expiry_ms: u64,
): ID {
    let id = object::new(fx.scenario_mut().ctx());
    let harness_id = id.to_inner();
    // The leveraged fixtures mint on a short-lived market that sits inside the
    // default no-leverage window; disable the block (a valid `window == 0`
    // config) so these exercise the close classifier rather than mint admission.
    let mut config = strike_exposure_config::new();
    config.set_no_leverage_window_ms(0);
    let exposure = strike_exposure::new(
        expiry_market_id,
        expiry_ms,
        test_constants::default_tick_size(),
        test_constants::default_tick_size(),
        expiry_ms - test_constants::default_cadence_period_ms(),
        config,
        fx.scenario_mut().ctx(),
    );
    transfer::share_object(ExposureHarness { id, exposure });
    harness_id
}

fun fresh_object_id(fx: &mut OracleFixture): ID {
    let id = object::new(fx.scenario_mut().ctx());
    let inner = id.to_inner();
    id.delete();
    inner
}

fun cleanup(fx: OracleFixture, oracle: OracleBundle, harness: ExposureHarness) {
    return_shared(harness);
    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}
