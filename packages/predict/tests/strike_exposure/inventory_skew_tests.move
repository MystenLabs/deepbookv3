// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for the branches of `marginal_reserve_consumption` that a mint
/// flow cannot reach. `inventory_skew_flow_tests` drives the two ends of the
/// formula through real mints — a cold range (`g = 0`, `delta = λN`) and a
/// pile-on (`g = N`, `delta = N`) — but both are quoted for a candidate that must
/// itself be an admissible order, so the interesting middle case never appears:
/// a candidate that overtakes the book's max point only PARTWAY, paying the full
/// dollar on the overshoot and `λ` on the rest. The removal branches and the
/// zero-net-payout / gamma-zero short-circuits are likewise only reachable from
/// a direct call.
///
/// Expectations are hand-derived from the book's step profile and the documented
/// `delta = λN + (1 − λ)g` / `rate = gamma · (delta / N) · p(1 − p)`, never
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
use fixed_math::math;
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

/// Skew intensity 1.0, so the rate reduces to `crowding × p(1 − p)`.
const GAMMA_ONE: u64 = 1_000_000_000;
/// 100%: above every rate the formula can produce (it peaks at `gamma / 4`).
const CAP_NON_BINDING: u64 = 1_000_000_000;
/// A coin flip, where `p(1 − p) = 0.25` peaks.
const HALF_PROBABILITY: u64 = 500_000_000;

/// The middle branch: the candidate lifts the max point, but by less than its own
/// net payout, so the reserve it consumes is neither `λN` nor `N`.
#[test]
fun partial_overlap_splits_between_the_peak_and_the_buffer() {
    let (fx, oracle, harness, _pricer) = skew_book(GAMMA_ONE, CAP_NON_BINDING);
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
    let (fx, oracle, harness, _pricer) = skew_book(GAMMA_ONE, CAP_NON_BINDING);

    // crowding = 1e9 / 2.5e9 = 0.4, coin-flip variance = 0.25:
    // rate = 1.0 × 0.4 × 0.25 = 0.1. At 1x the candidate's quantity is its net
    // payout, so the charge is 0.1 × 2.5e9 = 250e6.
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
        250_000_000,
    );

    cleanup(fx, oracle, harness);
}

/// Closing the peak while a colder side still stands: the max point can only
/// fall to `C`, not by a blind full `N`. Here `M = 3e9`, `C = 1e9`, `N = 3e9`,
/// so `g = 3e9 − max(0, 1e9) = 2e9` and `delta = 0.25 × 1e9 + 2e9`.
#[test]
fun removing_the_peak_range_stops_at_the_complement() {
    let (fx, oracle, harness, _pricer) = skew_book(GAMMA_ONE, CAP_NON_BINDING);

    assert_eq!(
        harness
            .exposure
            .marginal_reserve_consumption(
                test_constants::default_strike_tick(),
                constants::pos_inf_tick!(),
                UP_QUANTITY,
                false,
            ),
        2_250_000_000,
    );

    cleanup(fx, oracle, harness);
}

/// Two near-equal peaks: the bug the `R == M ⇒ g = N` shortcut shipped with.
/// ATM complements at 200e6 / 190e6; close `N = 100e6` of the higher peak →
/// true `g = 10e6`, not 100e6. `delta = 0.25 × 90e6 + 10e6 = 32_500_000`.
#[test]
fun two_near_peaks_close_releases_min_n_and_m_minus_c() {
    let (fx, oracle, mut harness, pricer) = empty_skew_book(GAMMA_ONE, CAP_NON_BINDING);
    let high_q = 200_000_000;
    let near_q = 190_000_000;
    let close_n = 100_000_000;
    let lower = test_constants::default_strike_tick();
    let higher = constants::pos_inf_tick!();

    harness.mint(&pricer, lower, higher, high_q, fx.clock());
    harness.mint(
        &pricer,
        constants::neg_inf!(),
        test_constants::default_strike_tick(),
        near_q,
        fx.clock(),
    );
    // M = 200e6 on UP, C = 190e6 on DOWN. g = 200e6 − max(100e6, 190e6) = 10e6.
    assert_eq!(
        harness.exposure.marginal_reserve_consumption(lower, higher, close_n, false),
        32_500_000,
    );

    cleanup(fx, oracle, harness);
}

/// Removing a range that never carried the max point leaves the max point where
/// it is, so only the λ share of the total is released — the mirror of the cold
/// add, and the branch that keeps a cold close from over-claiming.
#[test]
fun removing_a_cold_range_releases_only_its_lambda_share() {
    let (fx, oracle, harness, _pricer) = skew_book(GAMMA_ONE, CAP_NON_BINDING);

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

/// Sole exposure in the book: `C = 0`, so closing it drops the peak by the full
/// `N` and releases the whole dollar.
#[test]
fun closing_the_only_exposure_releases_the_whole_dollar() {
    let (fx, oracle, mut harness, pricer) = empty_skew_book(GAMMA_ONE, CAP_NON_BINDING);
    let lower = test_constants::default_strike_tick();
    let higher = constants::pos_inf_tick!();
    harness.mint(&pricer, lower, higher, UP_QUANTITY, fx.clock());

    assert_eq!(
        harness.exposure.marginal_reserve_consumption(lower, higher, UP_QUANTITY, false),
        UP_QUANTITY,
    );

    cleanup(fx, oracle, harness);
}

/// Immediate open-then-close of the same range and size: `g_add == g_removal`
/// (hence equal deltas), which is what makes charge == rebate at a shared `p`.
#[test]
fun open_then_close_same_range_has_equal_max_point_gains() {
    let (fx, oracle, mut harness, pricer) = skew_book(GAMMA_ONE, CAP_NON_BINDING);
    let lower = constants::neg_inf!();
    let higher = test_constants::default_strike_tick();
    // Candidate that partially overtakes the peak — the interesting middle branch.
    let g_add_delta = harness
        .exposure
        .marginal_reserve_consumption(lower, higher, OVERSHOOTING_NET_PAYOUT, true);
    harness.mint(&pricer, lower, higher, OVERSHOOTING_NET_PAYOUT, fx.clock());
    let g_removal_delta = harness
        .exposure
        .marginal_reserve_consumption(lower, higher, OVERSHOOTING_NET_PAYOUT, false);
    assert_eq!(g_add_delta, g_removal_delta);
    // Hand-pinned earlier: partial-overlap add delta is 1e9.
    assert_eq!(g_add_delta, 1_000_000_000);

    cleanup(fx, oracle, harness);
}

/// With load removed from the rate, equal crowding at a shared probability makes
/// the skew charge equal the skew rebate. The round trip's loss is then exactly
/// the two trade-fee floors — pin `min_fee > 0` so a future zeroing of that floor
/// cannot silently make the round trip free on the fee+skew axes.
#[test]
fun same_range_round_trip_nets_zero_on_skew_and_loses_exactly_the_two_fees() {
    let (fx, oracle, mut harness, pricer) = empty_skew_book(GAMMA_ONE, CAP_NON_BINDING);
    let lower = test_constants::default_strike_tick();
    let higher = constants::pos_inf_tick!();
    let quantity = UP_QUANTITY;

    let charge = harness
        .exposure
        .inventory_skew_charge(lower, higher, quantity, quantity, HALF_PROBABILITY, true);
    assert!(charge > 0);
    harness.mint(&pricer, lower, higher, quantity, fx.clock());
    let rebate = harness
        .exposure
        .inventory_skew_charge(lower, higher, quantity, quantity, HALF_PROBABILITY, false);
    assert_eq!(charge, rebate);

    // Fixture ships with `base_fee` floored so the per-leg fee binds at `min_fee`.
    // Quantity × min_fee is the independent fee each leg pays.
    let min_fee = config_constants::default_min_fee!();
    assert!(min_fee > 0);
    let fee_per_leg = math::mul_down(min_fee, quantity);
    assert!(fee_per_leg > 0);
    // Skew cancels; remaining debit on the fee+skew axes is exactly two fees.
    assert_eq!(fee_per_leg + fee_per_leg + charge - rebate, fee_per_leg + fee_per_leg);

    cleanup(fx, oracle, harness);
}

/// `gamma == 0` is the sole kill switch and must return before any payout-tree
/// walk. A piled book would otherwise force two range-max descents; with gamma
/// disarmed the charge is still exactly zero.
#[test]
fun gamma_zero_kill_switch_returns_zero_on_a_piled_book() {
    let (fx, oracle, harness, _pricer) = skew_book(0, CAP_NON_BINDING);

    assert_eq!(
        harness
            .exposure
            .inventory_skew_charge(
                test_constants::default_strike_tick(),
                constants::pos_inf_tick!(),
                UP_QUANTITY,
                UP_QUANTITY,
                HALF_PROBABILITY,
                true,
            ),
        0,
    );

    cleanup(fx, oracle, harness);
}

/// A fully-floored order has no net payout, so it consumes no reserve — and the
/// short-circuit is what keeps the crowding term from dividing by zero.
#[test]
fun zero_net_payout_consumes_nothing_and_is_never_charged() {
    let (fx, oracle, harness, _pricer) = skew_book(GAMMA_ONE, CAP_NON_BINDING);

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

/// Empty armed exposure — callers mint the profile they need.
fun empty_skew_book(
    gamma: u64,
    cap: u64,
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
    );

    fx.scenario_mut().next_tx(test_constants::admin());
    let harness = fx.scenario_mut().take_shared_by_id<ExposureHarness>(harness_id);
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_live_oracle_bundle(&mut oracle, test_constants::default_live_price());
    let pricer = fx.load_pricer_bundle(&oracle);
    (fx, oracle, harness, pricer)
}

/// Build the two-sided book through the real quote/allocate mint path, with the
/// skew knobs armed as requested.
fun skew_book(
    gamma: u64,
    cap: u64,
): (OracleFixture, OracleBundle, ExposureHarness, Pricer) {
    let (fx, oracle, mut harness, pricer) = empty_skew_book(gamma, cap);

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
): ID {
    let id = object::new(fx.scenario_mut().ctx());
    let harness_id = id.to_inner();
    let mut config = strike_exposure_config::new();
    config.set_inventory_skew_gamma(gamma);
    config.set_inventory_skew_cap(cap);
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
