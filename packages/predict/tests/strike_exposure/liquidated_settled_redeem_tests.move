// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Regression coverage for the exposure invariant behind post-settlement
/// liquidated-order redemption: a liquidated leveraged order has already been
/// removed from active exposure, so settled-market cleanup must clear its tombstone
/// instead of trying to close it as a settled active order.
#[test_only]
module deepbook_predict::liquidated_settled_redeem_tests;

use deepbook_predict::{
    constants,
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    order::{Self, Order},
    strike_exposure::{Self, StrikeExposure},
    strike_exposure_config,
    test_constants
};
use std::unit_test::assert_eq;
use sui::{object::{Self, UID}, test_scenario::return_shared};

public struct ExposureHarness has key {
    id: UID,
    exposure: StrikeExposure,
}

const LEVERAGE_TWO_X: u64 = 2_000_000_000;
/// 1% spot drop from the default 100e9 live spot knocks the 2x ATM UP range below
/// its liquidation threshold with the default near-zero SVI surface.
const DROPPED_SPOT: u64 = 99_000_000_000;
const DROPPED_SOURCE_TIMESTAMP_MS: u64 = 119_500;
/// Inside `(default_strike_tick, +inf]`, proving a liquidated order would have
/// been a settled winner if it were incorrectly treated as active.
const SETTLED_WINNING_SPOT: u64 = 101_000_000_000;

#[test]
fun liquidated_order_uses_tombstone_cleanup_not_settled_close() {
    let (fx, oracle, mut harness, order) = liquidated_order_fixture();

    assert!(harness.exposure.is_liquidated_order(&order));
    assert_eq!(harness.exposure.payout_liability(), 0);
    harness.exposure.record_settlement(SETTLED_WINNING_SPOT);
    assert_eq!(harness.exposure.payout_liability(), 0);

    // Even in the settled phase, the classifier resolves a liquidated order to
    // its tombstone before the settled outcome, so the close can only be the
    // zero-payout clear — the incorrect settled-active close is unrepresentable.
    let terms = harness.exposure.quote_close(option::none(), &order, order.quantity());
    assert!(terms.is_tombstone());
    harness.exposure.process_redeem(terms);

    assert!(!harness.exposure.is_liquidated_order(&order));
    assert_eq!(harness.exposure.payout_liability(), 0);

    cleanup(fx, oracle, harness);
}

#[test]
fun repeated_settlement_after_close_preserves_first_price_and_remaining_liability() {
    let (fx, oracle, mut harness, order) = active_order_fixture();
    let payout = order.quantity() - order.floor_shares();

    harness.exposure.record_settlement(SETTLED_WINNING_SPOT);
    assert_eq!(harness.exposure.payout_liability(), payout);
    let terms = harness.exposure.quote_close(option::none(), &order, order.quantity());
    assert_eq!(terms.settled_payout(), payout);
    harness.exposure.process_redeem(terms);
    assert_eq!(harness.exposure.payout_liability(), 0);

    // The package-level phase transition is itself idempotent: even after a
    // settled close mutates the cached liability, another call cannot recompute
    // it from the retained live payout tree or replace the first terminal price.
    harness.exposure.record_settlement(test_constants::default_live_price());
    assert_eq!(harness.exposure.settlement_price(), SETTLED_WINNING_SPOT);
    assert_eq!(harness.exposure.payout_liability(), 0);

    cleanup(fx, oracle, harness);
}

fun active_order_fixture(): (OracleFixture, OracleBundle, ExposureHarness, Order) {
    let mut fx = oracle_fixture::setup_oracle(
        test_constants::default_live_price(),
        test_constants::default_tick_size(),
        test_constants::short_expiry_ms(),
    );
    fx.scenario_mut().next_tx(test_constants::admin());
    let harness_id = create_and_share_exposure_harness(&mut fx);
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
            LEVERAGE_TWO_X,
            fx.clock(),
        );
    let order = harness.exposure.allocate_mint_order(terms);

    (fx, oracle, harness, order)
}

fun liquidated_order_fixture(): (OracleFixture, OracleBundle, ExposureHarness, Order) {
    let (fx, mut oracle, mut harness, order) = active_order_fixture();

    fx.set_pyth_bundle(&mut oracle, DROPPED_SPOT, DROPPED_SOURCE_TIMESTAMP_MS);
    let liquidation_pricer = fx.load_pricer_bundle(&oracle);
    let terms = harness
        .exposure
        .quote_close(option::some(liquidation_pricer), &order, order.quantity());
    assert!(terms.is_knocked_out());
    harness.exposure.process_liquidation(&liquidation_pricer, terms, fx.clock());

    (fx, oracle, harness, order)
}

fun create_and_share_exposure_harness(fx: &mut OracleFixture): ID {
    let expiry_market_id = fx.expiry_id();
    let expiry_ms = fx.expiry();
    let id = object::new(fx.scenario_mut().ctx());
    let harness_id = id.to_inner();
    // This fixture mints a leveraged order on a short-lived market to reach the
    // liquidation path, and that expiry sits inside the default no-leverage window.
    // Disable the block here (a valid `window == 0` config) so the fixture exercises
    // liquidation mechanics rather than mint admission, which the config unit tests
    // cover.
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

fun cleanup(fx: OracleFixture, oracle: OracleBundle, harness: ExposureHarness) {
    return_shared(harness);
    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}
