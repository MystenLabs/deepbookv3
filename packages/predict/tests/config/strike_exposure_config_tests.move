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
const HALF_PROBABILITY_TWO_AND_HALF_X_NET_PREMIUM: u64 = 200_000_000;
const HALF_PROBABILITY_TWO_AND_HALF_X_FLOOR_SHARES: u64 = 300_000_000;
const UNLEVERAGED_FLOOR_SHARES: u64 = 0;
/// Time-to-expiry far outside the default 1h no-leverage window (1 week), so the
/// block is inactive and admission runs at the full probability-derived cap.
const FAR_FROM_EXPIRY_MS: u64 = 604_800_000;
/// Expiry itself: zero time left, the deepest point inside the window.
const AT_EXPIRY_MS: u64 = 0;
/// Smallest leverage strictly above 1x; inside the window even this is refused.
const LEVERAGE_JUST_ABOVE_ONE_X: u64 = 1_000_000_001;
const LEVERAGE_ONE_POINT_FIVE_X: u64 = 1_500_000_000;
/// p = 0.5 at 1x: net premium is the full entry value 500_000_000, floor 0.
const HALF_PROBABILITY_ONE_X_NET_PREMIUM: u64 = 500_000_000;
/// p = 0.1, 1.5x, quantity 1e9: entry value 100_000_000; net premium
/// 100_000_000 / 1.5 = 66_666_666 (floor); floor shares the 33_333_334 remainder.
const LOW_PROBABILITY_ONE_POINT_FIVE_X_NET_PREMIUM: u64 = 66_666_666;
const LOW_PROBABILITY_ONE_POINT_FIVE_X_FLOOR_SHARES: u64 = 33_333_334;
const PROBABILITY_TWENTY_CENTS: u64 = 200_000_000;
const LOADING_ONE_HOUR_TWENTY_CENTS: u64 = 1_680_000_000;
const LOADING_EIGHT_HOURS_ATM: u64 = 1_000_000_000;
const LOADING_THIRTY_DAYS_ATM: u64 = 85_714_286;
const LOADING_ONE_MINUTE_ATM: u64 = 15_400_000_000;
const LOADING_FIVE_MINUTES_ATM: u64 = 8_000_000_000;
const LOADING_ONE_MINUTE_TWENTY_CENTS: u64 = 6_857_142_858;
const LOADING_LARGE: u64 = 10_000_000_000;
const ONE_BASIS_POINT: u64 = 100_000;
const FEE_ONE_HOUR_TWENTY_CENTS_BPS: u64 = 127;
const FEE_EIGHT_HOURS_ATM_BPS: u64 = 135;
const FEE_THIRTY_DAYS_ATM_BPS: u64 = 103;
const FEE_CAP_BPS: u64 = 300;
const MIN_FEE_BPS: u64 = 50;
const FEE_ONE_MINUTE_TWENTY_CENTS_BPS: u64 = 272;
const PROBABILITY_TWO_CENTS: u64 = 20_000_000;
const PROBABILITY_NINETY_EIGHT_CENTS: u64 = 980_000_000;
const SYMMETRY_LOADING: u64 = 500_000_000;

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

// === Near-expiry no-leverage window (template wiring) ===

// The default seeds a 1h block, and the template setter reaches the snapshot that
// future expiry markets take.
#[test]
fun template_no_leverage_window_defaults_to_one_hour_and_is_tunable() {
    let (scenario, admin_cap, config_id) = new_shared_config();
    let mut config = scenario.take_shared_by_id<ProtocolConfig>(config_id);

    let default_snapshot = config.strike_exposure_config_snapshot();
    assert_eq!(default_snapshot.no_leverage_window_ms(), constants::one_hour_ms!());
    destroy(default_snapshot);

    config.set_template_no_leverage_window_ms(&admin_cap, constants::one_day_ms!());
    let tuned_snapshot = config.strike_exposure_config_snapshot();
    assert_eq!(tuned_snapshot.no_leverage_window_ms(), constants::one_day_ms!());
    destroy(tuned_snapshot);

    return_shared(config);
    destroy(admin_cap);
    scenario.end();
}

// === EInvalidFeeProbability (leaf math guard, direct call) ===

#[test, expected_failure(abort_code = strike_exposure_config::EInvalidFeeProbability)]
fun trading_fee_probability_above_one_aborts() {
    let config = strike_exposure_config::new();
    config.trading_fee(
        float!() + 1,
        test_constants::mint_quantity(),
        0,
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
            float!(),
            float!(),
            0,
        ),
        config_constants::default_min_fee!(),
    );
    destroy(config);
}

// === Confidence-fee assembly ===

#[test]
fun confidence_fee_matches_published_surface_cells() {
    let config = strike_exposure_config::new();

    // Published calibration inputs, independent of the arithmetic under test:
    // 1h/20c has loading 1.68; 8h/50c is the unit reference; 30d/50c
    // implies loading 0.085714286 from its 103 bps table cell.
    assert_eq!(
        config.trading_fee(
            PROBABILITY_TWENTY_CENTS,
            float!(),
            LOADING_ONE_HOUR_TWENTY_CENTS,
        ) / ONE_BASIS_POINT,
        FEE_ONE_HOUR_TWENTY_CENTS_BPS,
    );
    assert_eq!(
        config.trading_fee(ENTRY_PROBABILITY_HALF, float!(), LOADING_EIGHT_HOURS_ATM)
            / ONE_BASIS_POINT,
        FEE_EIGHT_HOURS_ATM_BPS,
    );
    assert_eq!(
        config.trading_fee(ENTRY_PROBABILITY_HALF, float!(), LOADING_THIRTY_DAYS_ATM)
            / ONE_BASIS_POINT,
        FEE_THIRTY_DAYS_ATM_BPS,
    );
    assert_eq!(
        config.trading_fee(ENTRY_PROBABILITY_HALF, float!(), LOADING_ONE_MINUTE_ATM)
            / ONE_BASIS_POINT,
        FEE_CAP_BPS,
    );
    assert_eq!(
        config.trading_fee(ENTRY_PROBABILITY_HALF, float!(), LOADING_FIVE_MINUTES_ATM)
            / ONE_BASIS_POINT,
        FEE_CAP_BPS,
    );
    // The 1m 20c shoulder remains below the absolute cap; capping the
    // multiplier itself would incorrectly clip this published 272 bps cell.
    assert_eq!(
        config.trading_fee(
            PROBABILITY_TWENTY_CENTS,
            float!(),
            LOADING_ONE_MINUTE_TWENTY_CENTS,
        ) / ONE_BASIS_POINT,
        FEE_ONE_MINUTE_TWENTY_CENTS_BPS,
    );
    destroy(config);
}

#[test]
fun confidence_fee_caps_the_assembled_product() {
    let config = strike_exposure_config::new();

    // At 20c the base is 80 bps. A loading of 10 gives a 4.5x multiplier,
    // so the assembled 360 bps fee binds at the absolute 300 bps cap. A
    // mistaken cap on the multiplier would produce 240 bps instead.
    assert_eq!(
        config.trading_fee(PROBABILITY_TWENTY_CENTS, float!(), LOADING_LARGE)
            / ONE_BASIS_POINT,
        FEE_CAP_BPS,
    );
    destroy(config);
}

#[test]
fun confidence_fee_deep_wing_keeps_the_minimum_floor() {
    let config = strike_exposure_config::new();
    assert_eq!(config.trading_fee(0, float!(), 0) / ONE_BASIS_POINT, MIN_FEE_BPS);
    destroy(config);
}

#[test]
fun confidence_fee_is_symmetric_for_equal_tail_loading() {
    let config = strike_exposure_config::new();
    assert_eq!(
        config.trading_fee(PROBABILITY_TWO_CENTS, float!(), SYMMETRY_LOADING),
        config.trading_fee(PROBABILITY_NINETY_EIGHT_CENTS, float!(), SYMMETRY_LOADING),
    );
    destroy(config);
}

#[test, expected_failure(abort_code = strike_exposure_config::EFeeCapBelowMinimum)]
fun confidence_fee_cap_below_minimum_aborts() {
    let mut config = strike_exposure_config::new();
    config.set_fee_cap(config_constants::default_min_fee!() - 1);
    abort 999
}

#[test, expected_failure(abort_code = strike_exposure_config::EFeeCapBelowMinimum)]
fun confidence_fee_minimum_above_cap_aborts() {
    let mut config = strike_exposure_config::new();
    config.set_min_fee(config_constants::default_fee_cap!() + 1);
    abort 999
}

#[test]
fun confidence_fee_cap_may_equal_minimum() {
    let mut config = strike_exposure_config::new();
    config.set_min_fee(config_constants::default_fee_cap!());
    assert_eq!(config.min_fee(), config.fee_cap());
    destroy(config);
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

// === Near-expiry no-leverage window (mint admission) ===
//
// Independently derived caps for the default config (max admission leverage 3x,
// curve k = 0.2, cap = 1 + (3 - 1) * p * 1.2 / (p + 0.2)):
//   p = 0.5 -> 1 + 2 * (0.6 / 0.7)  = 2.714285714x
//   p = 0.1 -> 1 + 2 * (0.12 / 0.3) = 1.8x
// Inside the window the cap is exactly 1x regardless of p.

// 2x at p = 0.5 clears the 2.714285714x cap far from expiry
// (`mint_admission_half_probability_two_and_half_x_succeeds` admits even 2.5x).
// One millisecond inside the window the cap drops to 1x and the same order is
// refused — the tightest just-inside value for the `<` edge.
#[test, expected_failure(abort_code = strike_exposure_config::ELeverageAboveAdmissionCap)]
fun no_leverage_window_rejects_two_x_admitted_far_from_expiry() {
    let config = strike_exposure_config::new();
    config.assert_mint_admission(
        ENTRY_PROBABILITY_HALF,
        test_constants::mint_quantity(),
        LEVERAGE_TWO_X,
        config_constants::default_no_leverage_window_ms!() - 1,
    );
    abort 999
}

// The block is `time_to_expiry < window`, so at exactly the window edge the full
// probability-derived cap still applies. Pins the `<` boundary from the outside:
// 2.5x admits here with the same terms it gets far from expiry.
#[test]
fun no_leverage_window_boundary_admits_full_cap() {
    let config = strike_exposure_config::new();

    let admission = config.assert_mint_admission(
        ENTRY_PROBABILITY_HALF,
        test_constants::mint_quantity(),
        LEVERAGE_TWO_AND_HALF_X,
        config_constants::default_no_leverage_window_ms!(),
    );
    assert_eq!(admission.net_premium(), HALF_PROBABILITY_TWO_AND_HALF_X_NET_PREMIUM);
    assert_eq!(admission.floor_shares(), HALF_PROBABILITY_TWO_AND_HALF_X_FLOOR_SHARES);
    destroy(config);
}

// The cap inside the window is exactly 1x, not "nearly 1x": one unit of leverage
// above 1x is already above the cap.
#[test, expected_failure(abort_code = strike_exposure_config::ELeverageAboveAdmissionCap)]
fun no_leverage_window_rejects_smallest_leverage_above_one_x() {
    let config = strike_exposure_config::new();
    config.assert_mint_admission(
        ENTRY_PROBABILITY_HALF,
        test_constants::mint_quantity(),
        LEVERAGE_JUST_ABOVE_ONE_X,
        AT_EXPIRY_MS,
    );
    abort 999
}

// The window blocks leverage, not trading: an unleveraged mint still succeeds at
// the deepest point inside it. p = 0.5, quantity 1e9, 1x -> net premium is the
// full entry value 500_000_000 and the floor is 0.
#[test]
fun no_leverage_window_admits_one_x_at_expiry() {
    let config = strike_exposure_config::new();

    let admission = config.assert_mint_admission(
        ENTRY_PROBABILITY_HALF,
        test_constants::mint_quantity(),
        test_constants::leverage_one_x(),
        AT_EXPIRY_MS,
    );
    assert_eq!(admission.net_premium(), HALF_PROBABILITY_ONE_X_NET_PREMIUM);
    assert_eq!(admission.floor_shares(), UNLEVERAGED_FLOOR_SHARES);
    destroy(config);
}

// A 0 window is the admin escape hatch: the block never engages, so a leveraged
// mint is admitted even with zero time left.
#[test]
fun no_leverage_window_zero_disables_block() {
    let mut config = strike_exposure_config::new();
    config.set_no_leverage_window_ms(config_constants::min_no_leverage_window_ms!());

    let admission = config.assert_mint_admission(
        ENTRY_PROBABILITY_HALF,
        test_constants::mint_quantity(),
        LEVERAGE_TWO_AND_HALF_X,
        AT_EXPIRY_MS,
    );
    assert_eq!(admission.net_premium(), HALF_PROBABILITY_TWO_AND_HALF_X_NET_PREMIUM);
    assert_eq!(admission.floor_shares(), HALF_PROBABILITY_TWO_AND_HALF_X_FLOOR_SHARES);
    destroy(config);
}

// Control for the next test: at p = 0.1 the curve caps admission at 1.8x, so 1.5x
// is admitted far from expiry. Entry value 100_000_000; net premium
// 100_000_000 / 1.5 = 66_666_666 (floor); floor shares 100_000_000 - 66_666_666.
#[test]
fun low_probability_one_point_five_x_admitted_far_from_expiry() {
    let config = strike_exposure_config::new();

    let admission = config.assert_mint_admission(
        ENTRY_PROBABILITY_LOW,
        test_constants::mint_quantity(),
        LEVERAGE_ONE_POINT_FIVE_X,
        FAR_FROM_EXPIRY_MS,
    );
    assert_eq!(admission.net_premium(), LOW_PROBABILITY_ONE_POINT_FIVE_X_NET_PREMIUM);
    assert_eq!(admission.floor_shares(), LOW_PROBABILITY_ONE_POINT_FIVE_X_FLOOR_SHARES);
    destroy(config);
}

// The block replaces the curve rather than composing with it: inside the window
// the cap is 1x even at a probability whose curve cap (1.8x) would have admitted
// this order. Paired with the control above, the rejection is attributable to the
// window alone.
#[test, expected_failure(abort_code = strike_exposure_config::ELeverageAboveAdmissionCap)]
fun no_leverage_window_overrides_low_probability_curve() {
    let config = strike_exposure_config::new();
    config.assert_mint_admission(
        ENTRY_PROBABILITY_LOW,
        test_constants::mint_quantity(),
        LEVERAGE_ONE_POINT_FIVE_X,
        AT_EXPIRY_MS,
    );
    abort 999
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
