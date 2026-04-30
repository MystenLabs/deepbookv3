// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::inventory_skew_tests;

use deepbook_predict::{constants, i64, pricing_config};
use std::unit_test::assert_eq;

const FS: u64 = 1_000_000_000;
const HALF: u64 = 500_000_000;
const TWENTY_CENT: u64 = 200_000_000;
const EIGHTY_CENT: u64 = 800_000_000;

const BALANCE: u64 = 1_000_000_000_000;

// Hand-derived from the protocol defaults:
// fee = max(default_base_fee · √(p·(1-p)), default_min_fee) at zero utilization.
//   p = 0.5: 2% · √0.25 = 1%.
const FEE_AT_HALF: u64 = 10_000_000;

/// Build an aggregate magnitude that drives `raw_ratio` to `target_ratio_fs`
/// (in FLOAT_SCALING) at the given depth_multiplier and tte_factor = 1.
///
/// `raw_ratio = aggregate · tte_factor / (balance · depth_multiplier)` where
/// the multiplications are FS-scaled (so `denom_fs = balance · depth / FS`).
/// Solve for `aggregate`: `aggregate = target_ratio_fs · denom_fs / FS`.
fun aggregate_for_ratio(target_ratio_fs: u64, balance: u64, depth_multiplier: u64): u64 {
    let denom = (balance as u128) * (depth_multiplier as u128) / (FS as u128);
    ((target_ratio_fs as u128) * denom / (FS as u128)) as u64
}

fun seven_days_ms(): u64 { constants::default_reference_tte_ms!() }

// ── Baseline: zero aggregate produces symmetric quote ───────────────────────

#[test]
fun zero_aggregate_keeps_quote_centered_on_fair() {
    let config = pricing_config::new();
    let agg = i64::zero();

    let (mint_price, redeem_price) = config.compute_up_quote(
        HALF,
        &agg,
        0,
        BALANCE,
        seven_days_ms(),
    );

    assert_eq!(mint_price, HALF + FEE_AT_HALF);
    assert_eq!(redeem_price, HALF - FEE_AT_HALF);

    config.destroy_for_testing();
}

// ── Positive aggregate: vault is short UP, push mid up; redeem clamps at fair ─

#[test]
fun positive_aggregate_pushes_mint_up_and_clamps_redeem_at_fair() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    // ratio = 0.4 → shifted_mid = 0.5 + 0.4 · (1 − 0.5) = 0.7.
    let agg_mag = aggregate_for_ratio(400_000_000, BALANCE, depth);
    let agg = i64::from_parts(agg_mag, false);

    let (mint_price, redeem_price) = config.compute_up_quote(
        HALF,
        &agg,
        0,
        BALANCE,
        seven_days_ms(),
    );

    // mint = 0.7 + 1% = 0.71; redeem clamped at fair (zero-edge floor).
    assert_eq!(mint_price, 710_000_000);
    assert_eq!(redeem_price, HALF);

    config.destroy_for_testing();
}

// ── Negative aggregate: symmetric, mint clamped at fair, redeem pushed down ─

#[test]
fun negative_aggregate_pushes_redeem_down_and_clamps_mint_at_fair() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    // ratio = −0.4 → shifted_mid = 0.5 − 0.4 · 0.5 = 0.3.
    let agg_mag = aggregate_for_ratio(400_000_000, BALANCE, depth);
    let agg = i64::from_parts(agg_mag, true);

    let (mint_price, redeem_price) = config.compute_up_quote(
        HALF,
        &agg,
        0,
        BALANCE,
        seven_days_ms(),
    );

    // redeem = 0.3 − 1% = 0.29; mint clamped at fair (zero-edge floor).
    assert_eq!(mint_price, HALF);
    assert_eq!(redeem_price, 290_000_000);

    config.destroy_for_testing();
}

// ── Saturation: ratio_mag clamps at 1.0; mid lands at the binary boundary ──

#[test]
fun saturated_positive_ratio_drives_mint_to_one() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    // raw ratio = 5.0 → clamps to 1.0 → shifted_mid = 0.5 + (1 − 0.5) = 1.0.
    let agg_mag = aggregate_for_ratio(5 * FS, BALANCE, depth);
    let agg = i64::from_parts(agg_mag, false);

    let (mint_price, redeem_price) = config.compute_up_quote(
        HALF,
        &agg,
        0,
        BALANCE,
        seven_days_ms(),
    );

    assert_eq!(mint_price, FS);
    assert_eq!(redeem_price, HALF);

    config.destroy_for_testing();
}

#[test]
fun saturated_negative_ratio_drives_redeem_to_zero() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg_mag = aggregate_for_ratio(5 * FS, BALANCE, depth);
    let agg = i64::from_parts(agg_mag, true);

    let (mint_price, redeem_price) = config.compute_up_quote(
        HALF,
        &agg,
        0,
        BALANCE,
        seven_days_ms(),
    );

    assert_eq!(mint_price, HALF);
    assert_eq!(redeem_price, 0);

    config.destroy_for_testing();
}

// ── Short-circuit guards ────────────────────────────────────────────────────

#[test]
fun balance_zero_disables_skew() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(900_000_000, BALANCE, depth), false);

    let (mint_price, redeem_price) = config.compute_up_quote(HALF, &agg, 0, 0, seven_days_ms());

    assert_eq!(mint_price, HALF + FEE_AT_HALF);
    assert_eq!(redeem_price, HALF - FEE_AT_HALF);

    config.destroy_for_testing();
}

#[test]
fun zero_aggregate_short_circuits_even_with_extreme_inputs() {
    let mut config = pricing_config::new();
    config.set_min_tte_ms(1);
    let agg = i64::zero();

    let (mint_price, redeem_price) = config.compute_up_quote(HALF, &agg, 0, 1, 0);

    assert_eq!(mint_price, HALF + FEE_AT_HALF);
    assert_eq!(redeem_price, HALF - FEE_AT_HALF);

    config.destroy_for_testing();
}

// ── TTE amplification ───────────────────────────────────────────────────────

#[test]
fun shorter_tte_amplifies_skew_versus_reference_tte() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(100_000_000, BALANCE, depth), false);

    let (mint_far, _) = config.compute_up_quote(HALF, &agg, 0, BALANCE, seven_days_ms());
    let (mint_near, _) = config.compute_up_quote(
        HALF,
        &agg,
        0,
        BALANCE,
        constants::default_min_tte_ms!(), // tte_factor = √(7d/1d) = √7
    );

    // ratio_far = 0.10, shifted_mid = 0.55, mint = 0.55 + 1% = 0.56.
    assert_eq!(mint_far, 560_000_000);
    // ratio_near = 0.10 · √7 > 0.10 · 2.6 = 0.26 → mid > 0.5 + 0.26·0.5 = 0.63
    //   → mint > 0.63 + 0.01 = 0.64.
    assert!(mint_near > 640_000_000);

    config.destroy_for_testing();
}

#[test]
fun tte_below_min_clamps_to_min_tte_factor() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(100_000_000, BALANCE, depth), false);

    let (mint_at_min, _) = config.compute_up_quote(
        HALF,
        &agg,
        0,
        BALANCE,
        constants::default_min_tte_ms!(),
    );
    let (mint_below_min, _) = config.compute_up_quote(HALF, &agg, 0, BALANCE, 1);
    let (mint_at_zero, _) = config.compute_up_quote(HALF, &agg, 0, BALANCE, 0);

    // Anything ≤ min_tte_ms must produce the same shift.
    assert_eq!(mint_at_min, mint_below_min);
    assert_eq!(mint_at_min, mint_at_zero);

    config.destroy_for_testing();
}

// ── Asymmetric room at extreme fair prices ──────────────────────────────────

#[test]
fun positive_skew_at_low_fair_price_has_full_room_to_one() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    // Saturated positive ratio at fair = 0.20.
    let agg = i64::from_parts(aggregate_for_ratio(5 * FS, BALANCE, depth), false);

    let (mint_price, redeem_price) = config.compute_up_quote(
        TWENTY_CENT,
        &agg,
        0,
        BALANCE,
        seven_days_ms(),
    );

    // shifted_mid = 0.20 + (1.0 − 0.20) = 1.0; mint clamps at FS.
    assert_eq!(mint_price, FS);
    assert_eq!(redeem_price, TWENTY_CENT);

    config.destroy_for_testing();
}

#[test]
fun negative_skew_at_high_fair_price_has_full_room_to_zero() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(5 * FS, BALANCE, depth), true);

    let (mint_price, redeem_price) = config.compute_up_quote(
        EIGHTY_CENT,
        &agg,
        0,
        BALANCE,
        seven_days_ms(),
    );

    // shifted_mid = 0.80 − 0.80 = 0; redeem floored at 0.
    assert_eq!(mint_price, EIGHTY_CENT);
    assert_eq!(redeem_price, 0);

    config.destroy_for_testing();
}

// ── Half-saturated skew at off-center fair prices ───────────────────────────

#[test]
fun positive_skew_uses_room_to_one_at_twenty_cent_fair() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    // ratio = 0.5 at fair = 0.20 → shift = 0.5 · (1 − 0.20) = 0.4 → mid = 0.60.
    // fee at p=0.20: 2% · √0.16 = 0.8% = 8_000_000.
    let agg = i64::from_parts(aggregate_for_ratio(500_000_000, BALANCE, depth), false);

    let (mint_price, redeem_price) = config.compute_up_quote(
        TWENTY_CENT,
        &agg,
        0,
        BALANCE,
        seven_days_ms(),
    );

    // mint = 0.60 + 0.8% = 0.608.
    assert_eq!(mint_price, 608_000_000);
    // redeem = 0.60 − 0.8% = 0.592, but zero-edge floor caps at fair (0.20).
    assert_eq!(redeem_price, TWENTY_CENT);

    config.destroy_for_testing();
}

#[test]
fun negative_skew_uses_room_to_zero_at_eighty_cent_fair() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    // ratio = −0.5 at fair = 0.80 → shift = −0.5 · 0.80 = −0.4 → mid = 0.40.
    let agg = i64::from_parts(aggregate_for_ratio(500_000_000, BALANCE, depth), true);

    let (mint_price, redeem_price) = config.compute_up_quote(
        EIGHTY_CENT,
        &agg,
        0,
        BALANCE,
        seven_days_ms(),
    );

    // mint floored at fair (0.80). redeem = 0.40 − 0.8% = 0.392.
    assert_eq!(mint_price, EIGHTY_CENT);
    assert_eq!(redeem_price, 392_000_000);

    config.destroy_for_testing();
}

// ── Zero-edge floor invariant under all configurations ──────────────────────

#[test]
fun mint_never_below_fair_and_redeem_never_above_fair() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();

    let cases = vector[
        i64::zero(),
        i64::from_parts(aggregate_for_ratio(50_000_000, BALANCE, depth), false),
        i64::from_parts(aggregate_for_ratio(50_000_000, BALANCE, depth), true),
        i64::from_parts(aggregate_for_ratio(990_000_000, BALANCE, depth), false),
        i64::from_parts(aggregate_for_ratio(990_000_000, BALANCE, depth), true),
        i64::from_parts(aggregate_for_ratio(5 * FS, BALANCE, depth), false),
        i64::from_parts(aggregate_for_ratio(5 * FS, BALANCE, depth), true),
    ];
    let prices = vector[100_000_000u64, HALF, EIGHTY_CENT, 950_000_000u64];

    let mut i = 0;
    while (i < prices.length()) {
        let p = prices[i];
        let mut j = 0;
        while (j < cases.length()) {
            let (mint_price, redeem_price) = config.compute_up_quote(
                p,
                &cases[j],
                0,
                BALANCE,
                seven_days_ms(),
            );
            assert!(mint_price >= p);
            assert!(redeem_price <= p);
            assert!(mint_price <= FS);
            j = j + 1;
        };
        i = i + 1;
    };

    config.destroy_for_testing();
}

// ── Sign convention: signed delta cancels exactly across insert+remove ──────

#[test]
fun equal_and_opposite_aggregate_contributions_cancel() {
    let config = pricing_config::new();

    let qty = 1_000_000_000u64;
    let weight = 250_000_000u64; // n(d₂) ≈ 0.25 (d ≈ ±0.95)
    let mag = ((qty as u128) * (weight as u128) / (FS as u128)) as u64;

    let positive = i64::from_parts(mag, false);
    let negative = i64::from_parts(mag, true);
    let net = positive.add(&negative);
    assert!(net.is_zero());

    let (mint_price, redeem_price) = config.compute_up_quote(
        HALF,
        &net,
        0,
        BALANCE,
        seven_days_ms(),
    );
    assert_eq!(mint_price, HALF + FEE_AT_HALF);
    assert_eq!(redeem_price, HALF - FEE_AT_HALF);

    config.destroy_for_testing();
}

#[test]
fun differing_open_and_close_weights_leave_a_residual() {
    // Known approximation: weight is recomputed at trade time, so a position
    // closed under a different SVI surface leaves a `qty · (w_open − w_close)`
    // residual in the directional aggregate.
    let qty = 1_000_000_000u64;
    let w_open = 250_000_000u64;
    let w_close = 200_000_000u64;
    let mag_open = ((qty as u128) * (w_open as u128) / (FS as u128)) as u64;
    let mag_close = ((qty as u128) * (w_close as u128) / (FS as u128)) as u64;

    let opened = i64::from_parts(mag_open, false);
    let closed_negation = i64::from_parts(mag_close, true);
    let residual = opened.add(&closed_negation);

    assert_eq!(residual.magnitude(), mag_open - mag_close);
    assert!(!residual.is_negative());
}

// ── Order-size monotonicity: bigger aggregate → strictly worse mint price ──

#[test]
fun mint_price_is_strictly_increasing_in_positive_aggregate() {
    // Post-trade pricing (the protocol calls `apply_*_delta` before
    // `quote_*_amounts`) means a buyer is quoted against the inventory
    // their own order created. A 10× larger order should produce a 10×
    // larger pre-clamp ratio and a strictly higher mint price (until the
    // clamp at FS hits).
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();

    let small_agg = i64::from_parts(aggregate_for_ratio(10_000_000, BALANCE, depth), false);
    let medium_agg = i64::from_parts(aggregate_for_ratio(100_000_000, BALANCE, depth), false);
    let large_agg = i64::from_parts(aggregate_for_ratio(500_000_000, BALANCE, depth), false);

    let (mint_small, _) = config.compute_up_quote(HALF, &small_agg, 0, BALANCE, seven_days_ms());
    let (mint_medium, _) = config.compute_up_quote(HALF, &medium_agg, 0, BALANCE, seven_days_ms());
    let (mint_large, _) = config.compute_up_quote(HALF, &large_agg, 0, BALANCE, seven_days_ms());

    assert!(mint_small < mint_medium);
    assert!(mint_medium < mint_large);

    config.destroy_for_testing();
}

#[test]
fun redeem_price_is_strictly_decreasing_in_negative_aggregate() {
    // Symmetric: a redeemer who pushes the aggregate further negative gets
    // a worse (lower) bid.
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();

    let small_agg = i64::from_parts(aggregate_for_ratio(10_000_000, BALANCE, depth), true);
    let medium_agg = i64::from_parts(aggregate_for_ratio(100_000_000, BALANCE, depth), true);
    let large_agg = i64::from_parts(aggregate_for_ratio(500_000_000, BALANCE, depth), true);

    let (_, redeem_small) = config.compute_up_quote(HALF, &small_agg, 0, BALANCE, seven_days_ms());
    let (_, redeem_medium) = config.compute_up_quote(
        HALF,
        &medium_agg,
        0,
        BALANCE,
        seven_days_ms(),
    );
    let (_, redeem_large) = config.compute_up_quote(HALF, &large_agg, 0, BALANCE, seven_days_ms());

    assert!(redeem_small > redeem_medium);
    assert!(redeem_medium > redeem_large);

    config.destroy_for_testing();
}

#[test]
fun doubling_aggregate_doubles_pre_clamp_shift() {
    // While the ratio is below 1.0, the shift is linear in the aggregate.
    // ratio = 0.10 → shift = 0.05; ratio = 0.20 → shift = 0.10.
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();

    let agg = i64::from_parts(aggregate_for_ratio(100_000_000, BALANCE, depth), false);
    let agg_2x = i64::from_parts(aggregate_for_ratio(200_000_000, BALANCE, depth), false);

    let (mint, _) = config.compute_up_quote(HALF, &agg, 0, BALANCE, seven_days_ms());
    let (mint_2x, _) = config.compute_up_quote(HALF, &agg_2x, 0, BALANCE, seven_days_ms());

    // mint   = 0.5 + 0.10·0.5 + fee = 0.55 + 1% = 0.56
    // mint_2x = 0.5 + 0.20·0.5 + fee = 0.60 + 1% = 0.61
    assert_eq!(mint, 560_000_000);
    assert_eq!(mint_2x, 610_000_000);
    assert_eq!(mint_2x - HALF - FEE_AT_HALF, 2 * (mint - HALF - FEE_AT_HALF));

    config.destroy_for_testing();
}

// ── Per-strike weight scales the impact: ATM weight bites harder than OTM ───

#[test]
fun higher_per_strike_weight_pushes_mint_further_for_same_qty() {
    // Two trades of the same size at different strikes. The one with bigger
    // `n(d₂)` (closer to ATM) moves the aggregate more, so the resulting
    // mint price is higher even though `quantity` is identical.
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();

    let qty = 1_000_000_000u64;
    let mag_otm = ((qty as u128) * 50_000_000u128 / (FS as u128)) as u64; // n ≈ 0.05
    let mag_atm = ((qty as u128) * 350_000_000u128 / (FS as u128)) as u64; // n ≈ 0.35

    // Drive ratios to comparable levels by varying `balance` so the aggregate
    // numerics stay representative without saturating the clamp.
    let agg_otm = i64::from_parts(mag_otm, false);
    let agg_atm = i64::from_parts(mag_atm, false);
    let denom = (qty as u128) * (depth as u128) / (FS as u128); // pick balance so denom_fs = qty
    let balance = (denom * 1_000u128 / (depth as u128) * (FS as u128) / 1_000u128) as u64;

    let (mint_otm, _) = config.compute_up_quote(HALF, &agg_otm, 0, balance, seven_days_ms());
    let (mint_atm, _) = config.compute_up_quote(HALF, &agg_atm, 0, balance, seven_days_ms());

    assert!(mint_atm > mint_otm);

    config.destroy_for_testing();
}

// ── tte_factor at known ratios ──────────────────────────────────────────────

#[test]
fun tte_factor_equals_one_when_tte_matches_reference() {
    // At τ = ref_tte the time-amplification factor is exactly 1, so the
    // shift is purely the raw aggregate ratio scaled by room.
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(100_000_000, BALANCE, depth), false);

    let (mint, _) = config.compute_up_quote(HALF, &agg, 0, BALANCE, seven_days_ms());

    // ratio = 0.10 → shift = 0.10 · 0.5 = 0.05 → mint = 0.5 + 0.05 + 1% = 0.56.
    assert_eq!(mint, 560_000_000);

    config.destroy_for_testing();
}

#[test]
fun tte_factor_doubles_at_quarter_reference_tte() {
    // tte_factor = √(ref_tte / τ). At τ = ref_tte/4 the factor is exactly 2.
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(100_000_000, BALANCE, depth), false);
    let quarter_tte = constants::default_reference_tte_ms!() / 4;

    let (mint, _) = config.compute_up_quote(HALF, &agg, 0, BALANCE, quarter_tte);

    // ratio = 0.10 · 2 = 0.20 → shift = 0.20 · 0.5 = 0.10 → mint = 0.61.
    assert_eq!(mint, 610_000_000);

    config.destroy_for_testing();
}

#[test]
fun tte_factor_halves_at_four_times_reference_tte() {
    // tte_factor = √(ref_tte / (4·ref_tte)) = 0.5. Skew dampens for far-dated
    // expiries because the binary delta is correspondingly smaller.
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(100_000_000, BALANCE, depth), false);
    let four_x_tte = 4 * constants::default_reference_tte_ms!();

    let (mint, _) = config.compute_up_quote(HALF, &agg, 0, BALANCE, four_x_tte);

    // ratio = 0.10 · 0.5 = 0.05 → shift = 0.05 · 0.5 = 0.025 → mint = 0.535.
    assert_eq!(mint, 535_000_000);

    config.destroy_for_testing();
}

// ── Ratio clamp behavior at the saturation boundary ─────────────────────────

#[test]
fun ratio_at_exactly_one_saturates_to_full_room() {
    // At raw ratio == 1.0 exactly the clamp is a no-op: shift = 1 · room.
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(FS, BALANCE, depth), false);

    let (mint, redeem) = config.compute_up_quote(HALF, &agg, 0, BALANCE, seven_days_ms());

    // shifted_mid = 0.5 + 1.0 · 0.5 = 1.0 → mint = FS, redeem clamps at fair.
    assert_eq!(mint, FS);
    assert_eq!(redeem, HALF);

    config.destroy_for_testing();
}

#[test]
fun ratio_just_below_one_does_not_quite_saturate() {
    // ratio = 0.999 → shift = 0.999 · 0.5 = 0.4995, mid = 0.9995, mint = FS
    // (clamped by .min(FS) at the end), but the mid is still strictly < FS.
    // This isolates the difference between the ratio_mag.min(FS) clamp and
    // the final mint_price.min(FS) clamp.
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(999_000_000, BALANCE, depth), false);

    let (mint, redeem) = config.compute_up_quote(HALF, &agg, 0, BALANCE, seven_days_ms());

    // shifted_mid = 0.5 + 0.999 · 0.5 = 0.9995, mint = (0.9995 + 0.01).min(FS) = FS.
    assert_eq!(mint, FS);
    // redeem = (0.9995 - 0.01).min(0.5) = 0.5 (still clamped at fair).
    assert_eq!(redeem, HALF);

    config.destroy_for_testing();
}

// ── Sub-spread shift: zero-edge floor doesn't engage ────────────────────────

#[test]
fun negative_aggregate_with_shift_below_spread_keeps_mint_above_fair_only() {
    // Small negative aggregate: shift < spread, so `shifted_mid + spread`
    // still exceeds fair on its own — the .max(fair) clamp is a no-op and
    // mint sits between fair and (fair + spread).
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    // ratio = -0.005 → shift = 0.005 · 0.5 = 0.0025; spread (1%) > shift.
    let agg = i64::from_parts(aggregate_for_ratio(5_000_000, BALANCE, depth), true);

    let (mint, _) = config.compute_up_quote(HALF, &agg, 0, BALANCE, seven_days_ms());

    // shifted_mid = 0.5 - 0.0025 = 0.4975 → mint = 0.4975 + 0.01 = 0.5075.
    // Above fair (= 0.5) but strictly below the unshifted mint (= 0.51).
    assert_eq!(mint, 507_500_000);

    config.destroy_for_testing();
}

#[test]
fun positive_aggregate_with_shift_below_spread_keeps_redeem_below_fair_only() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(5_000_000, BALANCE, depth), false);

    let (_, redeem) = config.compute_up_quote(HALF, &agg, 0, BALANCE, seven_days_ms());

    // shifted_mid = 0.5025 → redeem = 0.5025 - 0.01 = 0.4925 (below fair, above 0).
    assert_eq!(redeem, 492_500_000);

    config.destroy_for_testing();
}

// ── Rejected fair prices (settled boundaries) ───────────────────────────────

#[test, expected_failure(abort_code = pricing_config::EFairPriceAlreadySettled)]
fun compute_up_quote_aborts_when_fair_price_is_one() {
    // FS == 1.0 means the binary settled "yes". No live fee applies.
    let config = pricing_config::new();
    let agg = i64::zero();
    let (_, _) = config.compute_up_quote(FS, &agg, 0, BALANCE, seven_days_ms());
    abort 999
}

#[test, expected_failure(abort_code = pricing_config::EFairPriceAlreadySettled)]
fun compute_up_quote_aborts_when_fair_price_is_zero() {
    let config = pricing_config::new();
    let agg = i64::zero();
    let (_, _) = config.compute_up_quote(0, &agg, 0, BALANCE, seven_days_ms());
    abort 999
}

// ── Round-trip cost without skew equals two spreads ─────────────────────────

#[test]
fun round_trip_cost_with_zero_aggregate_equals_two_spreads() {
    // Round-trip cost = mint − redeem. With a flat book this is purely
    // bid-ask, no inventory penalty.
    let config = pricing_config::new();
    let agg = i64::zero();

    let (mint, redeem) = config.compute_up_quote(HALF, &agg, 0, BALANCE, seven_days_ms());

    assert_eq!(mint - redeem, 2 * FEE_AT_HALF);

    config.destroy_for_testing();
}

#[test]
fun round_trip_cost_with_positive_aggregate_widens_by_shift() {
    // After a one-sided buy, the round trip costs more by exactly `shift` —
    // the buyer's own order pushed the mid against them, and the redeem
    // side pinned at fair while mint widened.
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(100_000_000, BALANCE, depth), false);

    let (mint, redeem) = config.compute_up_quote(HALF, &agg, 0, BALANCE, seven_days_ms());

    // mint = 0.56, redeem clamps at 0.5 → cost = 0.06 = 6¢.
    assert_eq!(mint, 560_000_000);
    assert_eq!(redeem, HALF);
    assert_eq!(mint - redeem, 60_000_000);

    config.destroy_for_testing();
}

// ── Very small balance: aggregate saturates the clamp instantly ─────────────

#[test]
fun tiny_balance_relative_to_aggregate_saturates_immediately() {
    // With balance ≪ aggregate, the raw ratio explodes past 1 and clamps.
    // Models the worst-case behavior right after a high-leverage trade.
    let config = pricing_config::new();
    let agg = i64::from_parts(1_000_000_000_000, false); // 1e12, large
    let tiny_balance = 1_000_000u64; // 1 USDC vault

    let (mint, redeem) = config.compute_up_quote(
        HALF,
        &agg,
        0,
        tiny_balance,
        seven_days_ms(),
    );

    assert_eq!(mint, FS);
    assert_eq!(redeem, HALF);

    config.destroy_for_testing();
}

// ── Asymmetric room exact boundaries ────────────────────────────────────────

#[test]
fun positive_skew_at_one_cent_fair_uses_full_room_to_one() {
    // Far OTM (fair = 1¢): room for positive skew is 99¢, so the shift can
    // dominate. spread at p=0.01: 2% · √(0.01·0.99) ≈ 2% · 0.0995 = 0.199%
    // — but min_fee floor (0.5%) kicks in.
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(100_000_000, BALANCE, depth), false);

    let (mint, redeem) = config.compute_up_quote(
        10_000_000,
        &agg,
        0,
        BALANCE,
        seven_days_ms(),
    );

    // ratio = 0.10 → shift = 0.10 · (1 - 0.01) = 0.099 → mid = 0.109.
    // spread floor = 0.5% (min_fee) → mint = 0.109 + 0.005 = 0.114.
    assert_eq!(mint, 114_000_000);
    // redeem = 0.109 - 0.005 = 0.104, but clamped at fair (0.01).
    assert_eq!(redeem, 10_000_000);

    config.destroy_for_testing();
}

// ── Defaults and getters ────────────────────────────────────────────────────

#[test]
fun defaults_expose_skew_terms() {
    let config = pricing_config::new();
    assert_eq!(config.depth_multiplier(), constants::default_depth_multiplier!());
    assert_eq!(config.reference_tte_ms(), constants::default_reference_tte_ms!());
    assert_eq!(config.min_tte_ms(), constants::default_min_tte_ms!());
    config.destroy_for_testing();
}

// ── Admin-setter abort guards ───────────────────────────────────────────────

#[test, expected_failure(abort_code = pricing_config::EInvalidDepthMultiplier)]
fun set_depth_multiplier_rejects_zero() {
    let mut config = pricing_config::new();
    config.set_depth_multiplier(0);
    abort 999
}

#[test, expected_failure(abort_code = pricing_config::EInvalidTteBound)]
fun set_min_tte_ms_rejects_zero() {
    let mut config = pricing_config::new();
    config.set_min_tte_ms(0);
    abort 999
}

#[test, expected_failure(abort_code = pricing_config::EInvalidTteBound)]
fun set_min_tte_ms_rejects_value_above_reference_tte() {
    let mut config = pricing_config::new();
    let above_ref = constants::default_reference_tte_ms!() + 1;
    config.set_min_tte_ms(above_ref);
    abort 999
}

#[test, expected_failure(abort_code = pricing_config::EInvalidTteBound)]
fun set_reference_tte_ms_rejects_value_below_min_tte() {
    let mut config = pricing_config::new();
    let below_min = constants::default_min_tte_ms!() - 1;
    config.set_reference_tte_ms(below_min);
    abort 999
}
