// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Economic invariants for the book-level inventory-impact potential.
///
/// The important regression is the cross-range cycle: charges and rebates are
/// differences of one state function, so a trader cannot profit by opening one
/// probability range, changing the book with another, and closing both.
#[test_only]
module deepbook_predict::inventory_impact_tests;

use deepbook_predict::{
    constants,
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    order::Order,
    strike_exposure::{Self, StrikeExposure},
    strike_exposure_config,
    test_constants
};
use std::unit_test::assert_eq;
use sui::{clock::Clock, object::{Self, UID}, test_scenario::return_shared};

public struct ExposureHarness has key {
    id: UID,
    exposure: StrikeExposure,
}

const IMPACT_SCALE: u64 = 4_000_000_000;
const IMPACT_MAX_RATE: u64 = 200_000_000; // 20%
const BACKING_BUFFER_LAMBDA: u64 = 500_000_000; // 50%
const ONE_ORDER: u64 = 1_000_000_000;

#[test]
fun default_zero_rate_is_a_kill_switch() {
    let (mut fx, oracle, mut harness) = new_harness(false);
    let pricer = fx.load_pricer_bundle(&oracle);
    let terms = harness
        .exposure
        .quote_mint_terms(
            &pricer,
            test_constants::default_strike_tick(),
            constants::pos_inf_tick!(),
            0,
            ONE_ORDER,
            true,
            test_constants::leverage_one_x(),
            fx.clock(),
        );

    assert_eq!(terms.inventory_impact_charge(), 0);
    let order = harness.exposure.allocate_mint_order(terms);
    assert_eq!(harness.exposure.inventory_impact_potential(), 0);
    let close = harness.exposure.quote_close(option::some(pricer), &order, order.quantity());
    assert_eq!(close.inventory_impact_rebate(), 0);

    cleanup(fx, oracle, harness);
}

#[test]
fun quadratic_below_scale_and_linear_above_scale() {
    let (mut fx, oracle, mut harness) = new_harness(true);
    let pricer = fx.load_pricer_bundle(&oracle);

    // Same range means liability equals total net payout. At L=3B/4:
    // marginal rate = 20% * 3/4 = 15%; phi = 15% * 3B / 2 = 225M.
    let first = quote_mint(&harness.exposure, &pricer, 3_000_000_000, fx.clock());
    assert_eq!(first.inventory_impact_charge(), 225_000_000);
    let first_order = harness.exposure.allocate_mint_order(first);
    assert_eq!(harness.exposure.inventory_impact_potential(), 225_000_000);

    // At L=5B/4, phi(B)=20%*B/2=400M and the 1B excess costs
    // the capped 20%, for 600M total. The second trade therefore costs 375M.
    let second = quote_mint(&harness.exposure, &pricer, 2_000_000_000, fx.clock());
    assert_eq!(second.inventory_impact_charge(), 375_000_000);
    let second_order = harness.exposure.allocate_mint_order(second);
    assert_eq!(harness.exposure.inventory_impact_potential(), 600_000_000);

    // Reverse the mutations: each close returns the exact potential decrement.
    let second_close = harness
        .exposure
        .quote_close(option::some(pricer), &second_order, second_order.quantity());
    assert_eq!(second_close.inventory_impact_rebate(), 375_000_000);
    harness.exposure.process_close(option::some(pricer), second_close, fx.clock());

    let first_close = harness
        .exposure
        .quote_close(option::some(pricer), &first_order, first_order.quantity());
    assert_eq!(first_close.inventory_impact_rebate(), 225_000_000);
    harness.exposure.process_close(option::some(pricer), first_close, fx.clock());
    assert_eq!(harness.exposure.inventory_impact_potential(), 0);

    cleanup(fx, oracle, harness);
}

#[test]
fun cross_range_cycle_cannot_extract_inventory_escrow() {
    let (mut fx, oracle, mut harness) = new_harness(true);
    let pricer = fx.load_pricer_bundle(&oracle);
    let strike = test_constants::default_strike_tick();

    // A and B are complementary ranges with different quoted probabilities.
    // Charge A: L=1B -> phi=25M.
    let terms_a = quote_range_mint(&harness.exposure, &pricer, 0, strike, ONE_ORDER, fx.clock());
    let charge_a = terms_a.inventory_impact_charge();
    assert_eq!(charge_a, 25_000_000);
    let order_a = harness.exposure.allocate_mint_order(terms_a);

    // With both disjoint positions, M=1B and T=2B. lambda=1/2 gives
    // L=1.5B and phi=56.25M, so B adds 31.25M.
    let terms_b = quote_range_mint(
        &harness.exposure,
        &pricer,
        strike,
        constants::pos_inf_tick!(),
        ONE_ORDER,
        fx.clock(),
    );
    let charge_b = terms_b.inventory_impact_charge();
    assert_eq!(charge_b, 31_250_000);
    let order_b = harness.exposure.allocate_mint_order(terms_b);

    // Close in the non-reverse order that defeated a range-local skew formula.
    let close_a = harness.exposure.quote_close(option::some(pricer), &order_a, order_a.quantity());
    let rebate_a = close_a.inventory_impact_rebate();
    assert_eq!(rebate_a, 31_250_000);
    harness.exposure.process_close(option::some(pricer), close_a, fx.clock());

    let close_b = harness.exposure.quote_close(option::some(pricer), &order_b, order_b.quantity());
    let rebate_b = close_b.inventory_impact_rebate();
    assert_eq!(rebate_b, 25_000_000);
    harness.exposure.process_close(option::some(pricer), close_b, fx.clock());

    assert_eq!(charge_a + charge_b, rebate_a + rebate_b);
    assert_eq!(harness.exposure.inventory_impact_potential(), 0);
    cleanup(fx, oracle, harness);
}

#[test]
fun partial_close_schedule_telescopes_without_rounding_dust() {
    let (mut fx, oracle, mut harness) = new_harness(true);
    let pricer = fx.load_pricer_bundle(&oracle);
    let mint = quote_mint(&harness.exposure, &pricer, ONE_ORDER, fx.clock());
    let charge = mint.inventory_impact_charge();
    let order = harness.exposure.allocate_mint_order(mint);

    let first_close = harness.exposure.quote_close(option::some(pricer), &order, 400_000_000);
    let first_rebate = first_close.inventory_impact_rebate();
    let survivor = harness
        .exposure
        .process_close(option::some(pricer), first_close, fx.clock())
        .destroy_some();

    let final_close = harness
        .exposure
        .quote_close(option::some(pricer), &survivor, survivor.quantity());
    let final_rebate = final_close.inventory_impact_rebate();
    harness.exposure.process_close(option::some(pricer), final_close, fx.clock());

    assert_eq!(charge, first_rebate + final_rebate);
    assert_eq!(harness.exposure.inventory_impact_potential(), 0);
    cleanup(fx, oracle, harness);
}

fun quote_mint(
    exposure: &StrikeExposure,
    pricer: &deepbook_predict::pricing::Pricer,
    quantity: u64,
    clock: &Clock,
): deepbook_predict::strike_exposure::MintTerms {
    quote_range_mint(
        exposure,
        pricer,
        test_constants::default_strike_tick(),
        constants::pos_inf_tick!(),
        quantity,
        clock,
    )
}

fun quote_range_mint(
    exposure: &StrikeExposure,
    pricer: &deepbook_predict::pricing::Pricer,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    clock: &Clock,
): deepbook_predict::strike_exposure::MintTerms {
    exposure.quote_mint_terms(
        pricer,
        lower_tick,
        higher_tick,
        0,
        quantity,
        true,
        test_constants::leverage_one_x(),
        clock,
    )
}

fun new_harness(enabled: bool): (OracleFixture, OracleBundle, ExposureHarness) {
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
    let mut config = strike_exposure_config::new();
    config.set_no_leverage_window_ms(0);
    config.set_backing_buffer_lambda(BACKING_BUFFER_LAMBDA);
    if (enabled) config.set_inventory_impact_max_rate(IMPACT_MAX_RATE);
    let exposure = strike_exposure::new(
        expiry_id,
        expiry_ms,
        test_constants::default_tick_size(),
        test_constants::default_admission_tick_size(),
        expiry_ms - test_constants::default_cadence_period_ms(),
        IMPACT_SCALE,
        config,
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
