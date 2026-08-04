// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for the branches of `marginal_reserve_consumption` that a mint
/// flow cannot reach. `inventory_skew_flow_tests` drives the two ends of the
/// formula through real mints — a cold range (`g = 0`, `delta = λN`) and a
/// pile-on (`g = N`, `delta = N`) — but both are quoted for a candidate that must
/// itself be an admissible order, so the interesting middle case never appears:
/// a candidate that overtakes the book's max point only PARTWAY, paying the full
/// dollar on the overshoot and `λ` on the rest. The removal branches and the
/// zero-net-payout short-circuit are likewise only reachable from a direct call.
///
/// Expectations are hand-derived from the book's step profile and the documented
/// `delta = λN + (1 − λ)g` / `rate = gamma · u · (delta / N) · p(1 − p)`, never
/// read back from a contract call. The book itself is built through the real
/// quote/allocate mint path so the profile is one a production market can reach.
#[test_only]
module deepbook_predict::inventory_skew_tests;

use deepbook_predict::{
    config_constants,
    constants,
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    pricing::Pricer,
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

/// The book the tests price against: the two at-the-money complements at
/// different sizes, both unfloored (1x) so every net payout equals its quantity.
/// `UP` over `(strike, +inf]` at 3e9 owns the max point; `DOWN` over
/// `(-inf, strike]` at 1e9 is the cold side. The step profile is therefore
/// `P = 1e9` below the strike and `3e9` above it.
const UP_QUANTITY: u64 = 3_000_000_000;
const DOWN_QUANTITY: u64 = 1_000_000_000;

/// `M = 3e9`, `T = 4e9`, so at the default λ = 0.25 the enforced reserve is
/// `3e9 + 0.25 × 1e9`.
const BOOK_PAYOUT_LIABILITY: u64 = 3_250_000_000;

/// A candidate sized to clear the max point by less than its own dollar: from the
/// cold side's peak of 1e9 it reaches 3.5e9, overshooting `M = 3e9` by 0.5e9.
const OVERSHOOTING_NET_PAYOUT: u64 = 2_500_000_000;

/// Skew intensity 1.0, so the rate reduces to `u × crowding × p(1 − p)`.
const GAMMA_ONE: u64 = 1_000_000_000;
/// 100%: above every rate the formula can produce (it peaks at `gamma / 4`).
const CAP_NON_BINDING: u64 = 1_000_000_000;
/// 8.5e9 DUSDC base units — twice the overshooting candidate's post-trade
/// liability, so utilization lands on exactly one half.
const CAPITAL_BASIS: u64 = 8_500_000_000;
/// A coin flip, where `p(1 − p) = 0.25` peaks.
const HALF_PROBABILITY: u64 = 500_000_000;

/// The middle branch: the candidate lifts the max point, but by less than its own
/// net payout, so the reserve it consumes is neither `λN` nor `N`.
#[test]
fun partial_overlap_splits_between_the_peak_and_the_buffer() {
    let (fx, oracle, harness, _pricer) = skew_book(GAMMA_ONE, CAP_NON_BINDING, CAPITAL_BASIS);
    // The hand arithmetic below assumes the shipped λ; pin it rather than let a
    // default change silently rewrite every expectation into a passing one.
    assert_eq!(
        harness.exposure.backing_buffer_lambda(),
        config_constants::default_backing_buffer_lambda!(),
    );
    assert_eq!(harness.exposure.payout_liability(), BOOK_PAYOUT_LIABILITY);

    // R = 1e9 on the cold side, so R + N = 3.5e9 clears M = 3e9 by g = 0.5e9.
    // delta = 0.25 × (2.5e9 − 0.5e9) + 0.5e9 = 1_000_000_000.
    assert_eq!(
        harness
            .exposure
            .marginal_reserve_consumption(
                constants::neg_inf!(),
                test_constants::default_strike_tick(),
                OVERSHOOTING_NET_PAYOUT,
                true,
            ),
        1_000_000_000,
    );

    cleanup(fx, oracle, harness);
}

/// The same middle branch priced: crowding is a genuine fraction here
/// (`delta / N = 0.4`), not the `λ` or `1.0` the two flow-reachable cases pin.
#[test]
fun partial_overlap_charge_prices_a_fractional_crowding_term() {
    let (fx, oracle, harness, _pricer) = skew_book(GAMMA_ONE, CAP_NON_BINDING, CAPITAL_BASIS);

    // u = (3.25e9 + 1e9) / 8.5e9 = 0.5, crowding = 1e9 / 2.5e9 = 0.4, and the
    // coin-flip variance is 0.25: rate = 1.0 × 0.5 × 0.4 × 0.25 = 0.05. At 1x the
    // candidate's quantity is its net payout, so the charge is 0.05 × 2.5e9.
    assert_eq!(
        harness
            .exposure
            .inventory_skew_charge(
                constants::neg_inf!(),
                test_constants::default_strike_tick(),
                OVERSHOOTING_NET_PAYOUT,
                OVERSHOOTING_NET_PAYOUT,
                HALF_PROBABILITY,
                true,
            ),
        125_000_000,
    );

    cleanup(fx, oracle, harness);
}

/// Removal reads the add formula at the post-removal book. Taking out the range
/// that IS the max point drops `M` and `R` together, so the whole dollar comes
/// back.
#[test]
fun removing_the_peak_range_releases_the_whole_dollar() {
    let (fx, oracle, harness, _pricer) = skew_book(GAMMA_ONE, CAP_NON_BINDING, CAPITAL_BASIS);

    assert_eq!(
        harness
            .exposure
            .marginal_reserve_consumption(
                test_constants::default_strike_tick(),
                constants::pos_inf_tick!(),
                UP_QUANTITY,
                false,
            ),
        UP_QUANTITY,
    );

    cleanup(fx, oracle, harness);
}

/// Removing a range that never carried the max point leaves the max point where
/// it is, so only the λ share of the total is released — the mirror of the cold
/// add, and the branch that keeps a cold close from over-claiming.
#[test]
fun removing_a_cold_range_releases_only_its_lambda_share() {
    let (fx, oracle, harness, _pricer) = skew_book(GAMMA_ONE, CAP_NON_BINDING, CAPITAL_BASIS);

    // R = 1e9 < M = 3e9, so g = 0 and delta = 0.25 × 1e9.
    assert_eq!(
        harness
            .exposure
            .marginal_reserve_consumption(
                constants::neg_inf!(),
                test_constants::default_strike_tick(),
                DOWN_QUANTITY,
                false,
            ),
        250_000_000,
    );

    cleanup(fx, oracle, harness);
}

/// A fully-floored order has no net payout, so it consumes no reserve — and the
/// short-circuit is what keeps the crowding term from dividing by zero.
#[test]
fun zero_net_payout_consumes_nothing_and_is_never_charged() {
    let (fx, oracle, harness, _pricer) = skew_book(GAMMA_ONE, CAP_NON_BINDING, CAPITAL_BASIS);

    assert_eq!(
        harness
            .exposure
            .marginal_reserve_consumption(
                test_constants::default_strike_tick(),
                constants::pos_inf_tick!(),
                0,
                true,
            ),
        0,
    );
    assert_eq!(
        harness
            .exposure
            .inventory_skew_charge(
                test_constants::default_strike_tick(),
                constants::pos_inf_tick!(),
                0,
                UP_QUANTITY,
                HALF_PROBABILITY,
                true,
            ),
        0,
    );

    cleanup(fx, oracle, harness);
}

// === Fixtures ===

/// Build the two-sided book through the real quote/allocate mint path, with the
/// skew knobs armed as requested.
fun skew_book(
    gamma: u64,
    cap: u64,
    capital_basis: u64,
): (OracleFixture, OracleBundle, ExposureHarness, Pricer) {
    let mut fx = oracle_fixture::setup_oracle(
        test_constants::default_live_price(),
        test_constants::default_tick_size(),
        test_constants::default_expiry_ms(),
    );
    let expiry_id = fx.expiry_id();
    let expiry_ms = fx.expiry();
    fx.scenario_mut().next_tx(test_constants::admin());
    let harness_id = create_and_share_exposure_harness(
        &mut fx,
        expiry_id,
        expiry_ms,
        gamma,
        cap,
        capital_basis,
    );

    fx.scenario_mut().next_tx(test_constants::admin());
    let mut harness = fx.scenario_mut().take_shared_by_id<ExposureHarness>(harness_id);
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let pricer = fx.load_pricer_bundle(&oracle);

    harness.mint(
        &pricer,
        test_constants::default_strike_tick(),
        constants::pos_inf_tick!(),
        UP_QUANTITY,
        fx.clock(),
    );
    harness.mint(
        &pricer,
        constants::neg_inf!(),
        test_constants::default_strike_tick(),
        DOWN_QUANTITY,
        fx.clock(),
    );

    (fx, oracle, harness, pricer)
}

/// Mint one unfloored (1x) order of exactly `quantity` over `(lower, higher]`.
fun mint(
    harness: &mut ExposureHarness,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
    quantity: u64,
    clock: &Clock,
) {
    let terms = harness
        .exposure
        .quote_mint_terms(
            pricer,
            lower_tick,
            higher_tick,
            0,
            quantity,
            true,
            test_constants::leverage_one_x(),
            clock,
        );
    harness.exposure.allocate_mint_order(terms);
}

fun create_and_share_exposure_harness(
    fx: &mut OracleFixture,
    expiry_market_id: ID,
    expiry_ms: u64,
    gamma: u64,
    cap: u64,
    capital_basis: u64,
): ID {
    let id = object::new(fx.scenario_mut().ctx());
    let harness_id = id.to_inner();
    let mut config = strike_exposure_config::new();
    config.set_inventory_skew_gamma(gamma);
    config.set_inventory_skew_cap(cap);
    config.set_skew_capital_basis(capital_basis);
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
