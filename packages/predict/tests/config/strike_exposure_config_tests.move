// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Abort-path coverage for every `strike_exposure_config` error code.
///
/// Setter-side: `EInvalidEntryProbabilityBound` (the relational min < max entry
/// probability guard on the template setters). Leaf math guard:
/// `EInvalidFeeProbability` — unreachable
/// from the public mint surface because `pricing` quotes come from
/// `compute_nd2`'s explicitly clamped digital, so it is exercised by a direct
/// package-internal `trading_fee` call (rule 4). Mint-admission policy is
/// exercised through `assert_mint_admission`, which is the package boundary the
/// real trade flow calls after it has loaded the live price.
#[test_only]
module deepbook_predict::strike_exposure_config_tests;

use deepbook_predict::{
    admin::{Self, AdminCap},
    config_constants,
    constants,
    protocol_config::{Self, ProtocolConfig},
    strike_exposure_config,
    test_constants
};
use fixed_math::math::float_scaling as float;
use std::unit_test::{assert_eq, destroy};
use sui::test_scenario::{Self as test, Scenario, return_shared};

// Leverage and probability values in FLOAT_SCALING (1e9).
const ENTRY_PROBABILITY_BELOW_MIN: u64 = 5_860_417;
const ENTRY_PROBABILITY_LOW: u64 = 100_000_000;
const ENTRY_PROBABILITY_HALF: u64 = 500_000_000;
const LEVERAGE_BELOW_ONE_X: u64 = 999_999_999;
const LEVERAGE_TWO_X: u64 = 2_000_000_000;
const LEVERAGE_TWO_AND_HALF_X: u64 = 2_500_000_000;
const LEVERAGE_THREE_X: u64 = 3_000_000_000;
/// Smallest 3x net-premium budget where `(budget + 1) * leverage` exceeds u64.
const THREE_X_FIRST_OVERFLOW_NET_PREMIUM: u64 = 6_148_914_691;
const HALF_PROBABILITY_TWO_AND_HALF_X_NET_PREMIUM: u64 = 200_000_000;
const HALF_PROBABILITY_TWO_AND_HALF_X_FLOOR_SHARES: u64 = 300_000_000;
const UNLEVERAGED_FLOOR_SHARES: u64 = 0;
const LEVERAGE_ONE_POINT_EIGHT_X: u64 = 1_800_000_000;
/// Time-to-expiry far beyond the default 1h leverage-taper window, so the taper
/// is inactive and admission behaves at the full probability-derived cap (1 week).
const FAR_FROM_EXPIRY_MS: u64 = 604_800_000;
/// Half of the default 1h leverage-taper window (30 minutes). At half the window
/// the taper multiplier is exactly 0.5.
const HALF_TAPER_WINDOW_MS: u64 = 1_800_000;
/// p = 0.5, 1.8x, quantity 1e9: entry value 500_000_000; net premium
/// 500_000_000 / 1.8 = 277_777_777 (floor); floor shares 500_000_000 - 277_777_777.
const HALF_PROBABILITY_ONE_POINT_EIGHT_X_NET_PREMIUM: u64 = 277_777_777;
const HALF_PROBABILITY_ONE_POINT_EIGHT_X_FLOOR_SHARES: u64 = 222_222_223;
/// p = 0.5 at 1x: net premium equals the full entry value 500_000_000, floor 0.
const HALF_PROBABILITY_ONE_X_NET_PREMIUM: u64 = 500_000_000;
const LEVERAGE_ONE_POINT_FIVE_X: u64 = 1_500_000_000;
const LEVERAGE_TWO_POINT_SEVEN_X: u64 = 2_700_000_000;
/// A quarter of the default 1h leverage-taper window (15 minutes); the taper
/// multiplier is exactly 0.25.
const QUARTER_TAPER_WINDOW_MS: u64 = 900_000;
/// p = 0.5, 2.7x, quantity 1e9: net premium 500_000_000 / 2.7 = 185_185_185
/// (floor); floor shares 500_000_000 - 185_185_185.
const HALF_PROBABILITY_TWO_POINT_SEVEN_X_NET_PREMIUM: u64 = 185_185_185;
const HALF_PROBABILITY_TWO_POINT_SEVEN_X_FLOOR_SHARES: u64 = 314_814_815;

/// Create a real shared `ProtocolConfig` (template values at defaults) and an
/// `AdminCap`, ready for admin setter calls in the next transaction.
fun new_shared_config(): (Scenario, AdminCap, ID) {
    let mut scenario = test::begin(test_constants::admin());
    let config_id = protocol_config::create_and_share(scenario.ctx());
    let admin_cap = admin::new(scenario.ctx());
    scenario.next_tx(test_constants::admin());
    (scenario, admin_cap, config_id)
}

// === EInvalidEntryProbabilityBound (template setter relational guard) ===

// A min entry probability equal to the current max entry probability is the
// tightest just-outside value
// (the setter requires min < max strictly); it is inside the
// `config_constants` envelope, so the relational guard is what fires.
#[test, expected_failure(abort_code = strike_exposure_config::EInvalidEntryProbabilityBound)]
fun template_min_entry_probability_at_max_entry_probability_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_min_entry_probability(
        &admin_cap,
        config_constants::default_max_entry_probability!(),
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::EInvalidEntryProbabilityBound)]
fun template_max_entry_probability_at_min_entry_probability_aborts() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);
    config.set_template_max_entry_probability(
        &admin_cap,
        config_constants::default_min_entry_probability!(),
    );
    abort 999
}

#[test]
fun template_entry_probability_bounds_accept_adjacent_values() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);

    // min one unit below the default max, then max one unit above that min:
    // the tightest just-inside pair for the relational guard.
    config.set_template_min_entry_probability(
        &admin_cap,
        config_constants::default_max_entry_probability!() - 1,
    );
    config.set_template_max_entry_probability(
        &admin_cap,
        config_constants::default_max_entry_probability!(),
    );

    let snapshot = config.strike_exposure_config_snapshot();
    assert_eq!(
        snapshot.min_entry_probability(),
        config_constants::default_max_entry_probability!() - 1,
    );
    assert_eq!(
        snapshot.max_entry_probability(),
        config_constants::default_max_entry_probability!(),
    );
    destroy(snapshot);

    return_shared(config);
    destroy(admin_cap);
    scenario.end();
}

// === EInvalidFeeProbability (leaf math guard, direct call) ===

#[test, expected_failure(abort_code = strike_exposure_config::EInvalidFeeProbability)]
fun trading_fee_probability_above_one_aborts() {
    let config = strike_exposure_config::new();
    config.trading_fee(
        test_constants::default_expiry_ms(),
        float!() + 1,
        test_constants::mint_quantity(),
        test_constants::now_ms(),
    );
    abort 999
}

#[test]
fun trading_fee_at_probability_one_floors_at_min_fee() {
    let config = strike_exposure_config::new();
    // Just-inside boundary: p = 1.0 is accepted. Bernoulli variance at p = 1
    // is 0, so the raw fee is 0 and the per-unit rate floors at the default
    // min fee; far from expiry the ramp multiplier is 1x, and quantity 1.0
    // (1e9) makes the total fee equal the per-unit floor exactly.
    assert_eq!(
        config.trading_fee(
            test_constants::default_expiry_ms(),
            float!(),
            float!(),
            test_constants::now_ms(),
        ),
        config_constants::default_min_fee!(),
    );
    destroy(config);
}

// === max_quantity_for_net_premium (fixed-amount inverse) ===

#[test]
fun max_quantity_for_net_premium_exact_lot_boundary() {
    // At p = 1.0 and 1x leverage, net premium equals quantity, so a
    // one-lot premium budget admits exactly one position lot.
    assert_eq!(
        strike_exposure_config::max_quantity_for_net_premium(
            float!(),
            constants::position_lot_size!(),
            test_constants::leverage_one_x(),
        ),
        constants::position_lot_size!(),
    );
}

#[test]
fun max_quantity_for_net_premium_one_x_unit_neighbors() {
    // With p = 3 / 1e9 and 1x leverage:
    //   N=4 admits floor(4.999999998e9 / 3) = 1_666_666_666
    //   N=5 admits floor(5.999999999e9 / 3) = 1_999_999_999
    //   N=6 admits floor(6.999999999e9 / 3) = 2_333_333_333
    assert_eq!(
        strike_exposure_config::max_quantity_for_net_premium(
            3,
            4,
            test_constants::leverage_one_x(),
        ),
        1_666_666_666,
    );
    assert_eq!(
        strike_exposure_config::max_quantity_for_net_premium(
            3,
            5,
            test_constants::leverage_one_x(),
        ),
        1_999_999_999,
    );
    assert_eq!(
        strike_exposure_config::max_quantity_for_net_premium(
            3,
            6,
            test_constants::leverage_one_x(),
        ),
        2_333_333_333,
    );
}

#[test]
fun max_quantity_for_net_premium_two_x_unit_boundary() {
    // Same p = 3 / 1e9 at 2x leverage. Net premium N=5 permits entry value 11
    // but not 12, so quantity is floor(11.999999999e9 / 3).
    assert_eq!(
        strike_exposure_config::max_quantity_for_net_premium(3, 5, LEVERAGE_TWO_X),
        3_999_999_999,
    );
}

#[test]
fun max_quantity_for_net_premium_zero_guards() {
    assert_eq!(
        strike_exposure_config::max_quantity_for_net_premium(
            0,
            5,
            test_constants::leverage_one_x(),
        ),
        0,
    );
    assert_eq!(
        strike_exposure_config::max_quantity_for_net_premium(
            3,
            0,
            test_constants::leverage_one_x(),
        ),
        0,
    );
}

#[test, expected_failure(abort_code = strike_exposure_config::ENetPremiumBudgetTooHigh)]
fun max_quantity_for_net_premium_max_budget_aborts() {
    strike_exposure_config::max_quantity_for_net_premium(
        float!(),
        std::u64::max_value!(),
        test_constants::leverage_one_x(),
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::ENetPremiumBudgetTooHigh)]
fun max_quantity_for_net_premium_budget_leverage_product_overflow_aborts() {
    strike_exposure_config::max_quantity_for_net_premium(
        float!(),
        THREE_X_FIRST_OVERFLOW_NET_PREMIUM,
        LEVERAGE_THREE_X,
    );
    abort 999
}

// === EEntryProbabilityOutOfBounds (mint admission) ===

#[test, expected_failure(abort_code = strike_exposure_config::EEntryProbabilityOutOfBounds)]
fun mint_admission_probability_one_above_max_entry_probability_aborts() {
    let config = strike_exposure_config::new();
    // p = 1.0 is above the default max entry probability 0.99.
    config.assert_mint_admission(
        float!(),
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        FAR_FROM_EXPIRY_MS,
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::EEntryProbabilityOutOfBounds)]
fun mint_admission_probability_below_min_entry_probability_aborts() {
    let config = strike_exposure_config::new();
    // This probability is below 1%, but its old all-in ask price would have
    // cleared 1% after the min fee was added. Admission now gates raw
    // probability directly.
    config.assert_mint_admission(
        ENTRY_PROBABILITY_BELOW_MIN,
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        FAR_FROM_EXPIRY_MS,
    );
    abort 999
}

// === EInvalidLeverage / ELeverageAboveAdmissionCap (mint admission) ===

#[test, expected_failure(abort_code = strike_exposure_config::EInvalidLeverage)]
fun mint_admission_leverage_below_one_x_aborts() {
    let config = strike_exposure_config::new();
    config.assert_mint_admission(
        ENTRY_PROBABILITY_HALF,
        test_constants::mint_quantity(),
        LEVERAGE_BELOW_ONE_X,
        FAR_FROM_EXPIRY_MS,
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::ELeverageAboveAdmissionCap)]
fun mint_admission_low_probability_two_x_above_curve_aborts() {
    let config = strike_exposure_config::new();
    // With default max leverage 3x and k = 0.2, p = 0.1 gives cap 1.8x.
    config.assert_mint_admission(
        ENTRY_PROBABILITY_LOW,
        test_constants::mint_quantity(),
        LEVERAGE_TWO_X,
        FAR_FROM_EXPIRY_MS,
    );
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::ELeverageAboveAdmissionCap)]
fun mint_admission_template_cap_scales_curve_aborts() {
    let mut config = strike_exposure_config::new();
    config.set_max_admission_leverage(LEVERAGE_TWO_X);
    // With max leverage 2x and k = 0.2, p = 0.5 gives cap 1.857142857x.
    config.assert_mint_admission(
        ENTRY_PROBABILITY_HALF,
        test_constants::mint_quantity(),
        LEVERAGE_TWO_X,
        FAR_FROM_EXPIRY_MS,
    );
    abort 999
}

#[test]
fun mint_admission_half_probability_two_and_half_x_succeeds() {
    let config = strike_exposure_config::new();

    // p = 0.5 and quantity = 1e9 gives entry value 500_000_000.
    // At 2.5x, net premium = 500_000_000 / 2.5 = 200_000_000 and
    // floor shares = 500_000_000 - 200_000_000 = 300_000_000.
    let admission = config.assert_mint_admission(
        ENTRY_PROBABILITY_HALF,
        test_constants::mint_quantity(),
        LEVERAGE_TWO_AND_HALF_X,
        FAR_FROM_EXPIRY_MS,
    );
    assert_eq!(admission.net_premium(), HALF_PROBABILITY_TWO_AND_HALF_X_NET_PREMIUM);
    assert_eq!(admission.floor_shares(), HALF_PROBABILITY_TWO_AND_HALF_X_FLOOR_SHARES);
    destroy(config);
}

// === ENetPremiumBelowMinimum (mint admission) ===

#[test, expected_failure(abort_code = strike_exposure_config::ENetPremiumBelowMinimum)]
fun mint_admission_net_premium_one_lot_below_minimum_aborts() {
    let config = strike_exposure_config::new();
    // At p = 0.5 and 1x leverage, quantity 1_990_000 gives net premium
    // 995_000, one position lot below the 1_000_000 minimum.
    config.assert_mint_admission(
        ENTRY_PROBABILITY_HALF,
        2 * constants::min_net_premium!() - constants::position_lot_size!(),
        test_constants::leverage_one_x(),
        FAR_FROM_EXPIRY_MS,
    );
    abort 999
}

#[test]
fun mint_admission_net_premium_at_minimum_succeeds() {
    let config = strike_exposure_config::new();

    let admission = config.assert_mint_admission(
        ENTRY_PROBABILITY_HALF,
        2 * constants::min_net_premium!(),
        test_constants::leverage_one_x(),
        FAR_FROM_EXPIRY_MS,
    );
    assert_eq!(admission.net_premium(), constants::min_net_premium!());
    assert_eq!(admission.floor_shares(), UNLEVERAGED_FLOOR_SHARES);
    destroy(config);
}

// === EOrderBelowLiquidationThreshold (mint admission) ===

#[test, expected_failure(abort_code = strike_exposure_config::EOrderBelowLiquidationThreshold)]
fun mint_admission_liquidation_ltv_still_controls_open_threshold() {
    let mut config = strike_exposure_config::new();
    config.set_liquidation_ltv(config_constants::min_liquidation_ltv!());
    // At p = 0.5 and 2x, floor shares are exactly half the entry value. With
    // liquidation LTV set to 0.5, the open threshold equals entry value, so the
    // strict above-threshold check fails even though 2x passes admission cap.
    config.assert_mint_admission(
        ENTRY_PROBABILITY_HALF,
        test_constants::mint_quantity(),
        LEVERAGE_TWO_X,
        FAR_FROM_EXPIRY_MS,
    );
    abort 999
}

// === Near-expiry leverage taper (ELeverageAboveAdmissionCap via time) ===

// Far from expiry the taper is inactive and 2x at p = 0.5 clears the full cap
// 2.714285714x. Inside the window the cap shrinks: at half the window the taper
// multiplier is 0.5, giving cap 1 + 2 * 0.857142857 * 0.5 = 1.857142857x, so the
// same 2x order is now rejected.
#[test, expected_failure(abort_code = strike_exposure_config::ELeverageAboveAdmissionCap)]
fun taper_rejects_leverage_admitted_far_from_expiry() {
    let config = strike_exposure_config::new();
    config.assert_mint_admission(
        ENTRY_PROBABILITY_HALF,
        test_constants::mint_quantity(),
        LEVERAGE_TWO_X,
        HALF_TAPER_WINDOW_MS,
    );
    abort 999
}

// At half the window (taper 0.5) the reduced cap is 1.857142857x, so 1.8x is
// still admitted; the taper only gates admission and does not reprice the terms.
#[test]
fun taper_admits_reduced_leverage_within_window() {
    let config = strike_exposure_config::new();
    let admission = config.assert_mint_admission(
        ENTRY_PROBABILITY_HALF,
        test_constants::mint_quantity(),
        LEVERAGE_ONE_POINT_EIGHT_X,
        HALF_TAPER_WINDOW_MS,
    );
    assert_eq!(admission.net_premium(), HALF_PROBABILITY_ONE_POINT_EIGHT_X_NET_PREMIUM);
    assert_eq!(admission.floor_shares(), HALF_PROBABILITY_ONE_POINT_EIGHT_X_FLOOR_SHARES);
    destroy(config);
}

// At expiry (time_to_expiry_ms = 0) the taper multiplier is 0, so the cap
// collapses to exactly 1x: an unleveraged order is admitted with a zero floor.
#[test]
fun taper_at_expiry_admits_one_x() {
    let config = strike_exposure_config::new();
    let admission = config.assert_mint_admission(
        ENTRY_PROBABILITY_HALF,
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        0,
    );
    assert_eq!(admission.net_premium(), HALF_PROBABILITY_ONE_X_NET_PREMIUM);
    assert_eq!(admission.floor_shares(), UNLEVERAGED_FLOOR_SHARES);
    destroy(config);
}

// At expiry the cap is exactly 1x, so any leverage above 1x is rejected.
#[test, expected_failure(abort_code = strike_exposure_config::ELeverageAboveAdmissionCap)]
fun taper_at_expiry_rejects_leverage_above_one_x() {
    let config = strike_exposure_config::new();
    config.assert_mint_admission(
        ENTRY_PROBABILITY_HALF,
        test_constants::mint_quantity(),
        LEVERAGE_TWO_X,
        0,
    );
    abort 999
}

// A zero window disables the taper: full leverage is admitted even at expiry.
// 2.5x at p = 0.5 is inside the full cap 2.714285714x.
#[test]
fun taper_disabled_admits_full_leverage_at_expiry() {
    let mut config = strike_exposure_config::new();
    config.set_leverage_taper_window_ms(0);
    let admission = config.assert_mint_admission(
        ENTRY_PROBABILITY_HALF,
        test_constants::mint_quantity(),
        LEVERAGE_TWO_AND_HALF_X,
        0,
    );
    assert_eq!(admission.net_premium(), HALF_PROBABILITY_TWO_AND_HALF_X_NET_PREMIUM);
    assert_eq!(admission.floor_shares(), HALF_PROBABILITY_TWO_AND_HALF_X_FLOOR_SHARES);
    destroy(config);
}

// At exactly the window boundary (time_to_expiry == window) the taper is full, so
// the cap is the untapered 2.714285714x and 2.7x is admitted. Pins the `>=` edge
// (the far-from-expiry tests only exercise time >> window).
#[test]
fun taper_at_window_boundary_admits_full_leverage() {
    let config = strike_exposure_config::new();
    let admission = config.assert_mint_admission(
        ENTRY_PROBABILITY_HALF,
        test_constants::mint_quantity(),
        LEVERAGE_TWO_POINT_SEVEN_X,
        constants::one_hour_ms!(),
    );
    assert_eq!(admission.net_premium(), HALF_PROBABILITY_TWO_POINT_SEVEN_X_NET_PREMIUM);
    assert_eq!(admission.floor_shares(), HALF_PROBABILITY_TWO_POINT_SEVEN_X_FLOOR_SHARES);
    destroy(config);
}

// The taper is linear: at a quarter of the window the multiplier is 0.25, giving
// cap 1 + 2 * 0.857142857 * 0.25 = 1.428571428x, so 1.5x is rejected — even though
// the same 1.5x clears the 1.857142857x cap at half the window (a second point on
// the taper line).
#[test, expected_failure(abort_code = strike_exposure_config::ELeverageAboveAdmissionCap)]
fun taper_quarter_window_rejects_leverage_admitted_at_half_window() {
    let config = strike_exposure_config::new();
    config.assert_mint_admission(
        ENTRY_PROBABILITY_HALF,
        test_constants::mint_quantity(),
        LEVERAGE_ONE_POINT_FIVE_X,
        QUARTER_TAPER_WINDOW_MS,
    );
    abort 999
}

// The near-expiry taper multiplies the low-probability risk curve. At p = 0.1 the
// full cap is 1.8x; at half the window the taper halves the excess to give
// 1 + 2 * 0.4 * 0.5 = 1.4x, so 1.5x is rejected here even though it would be
// admitted far from expiry.
#[test, expected_failure(abort_code = strike_exposure_config::ELeverageAboveAdmissionCap)]
fun taper_composes_with_low_probability_curve() {
    let config = strike_exposure_config::new();
    config.assert_mint_admission(
        ENTRY_PROBABILITY_LOW,
        test_constants::mint_quantity(),
        LEVERAGE_ONE_POINT_FIVE_X,
        HALF_TAPER_WINDOW_MS,
    );
    abort 999
}
