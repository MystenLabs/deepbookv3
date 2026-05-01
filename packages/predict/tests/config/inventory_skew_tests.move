// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::inventory_skew_tests;

use deepbook_predict::{constants, i64::{Self, I64}, pricing_config::{Self, PricingConfig}};
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

/// Quote a single-strike UP leg at strike K with `p_up(K) = fair`.
/// Range form: `(K, +∞]` → `p_up_lower = fair`, `p_up_higher = 0`,
/// `fair_range = fair`.
fun up_leg(config: &PricingConfig, fair: u64, agg: &I64, balance: u64, tte: u64): (u64, u64) {
    config.compute_range_quote(fair, fair, 0, agg, 0, balance, tte)
}

/// Quote a single-strike DN leg at strike K with `p_up(K) = p_up_at_k`.
/// Range form: `(−∞, K]` → `p_up_lower = FS` (sentinel), `p_up_higher = p_up_at_k`,
/// `fair_range = FS − p_up_at_k`.
fun dn_leg(config: &PricingConfig, p_up_at_k: u64, agg: &I64, balance: u64, tte: u64): (u64, u64) {
    config.compute_range_quote(FS - p_up_at_k, FS, p_up_at_k, agg, 0, balance, tte)
}

// ── Baseline: zero aggregate produces symmetric quote ───────────────────────

#[test]
fun zero_aggregate_keeps_quote_centered_on_fair() {
    let config = pricing_config::new();
    let agg = i64::zero();

    let (mint_price, redeem_price) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());

    assert_eq!(mint_price, HALF + FEE_AT_HALF);
    assert_eq!(redeem_price, HALF - FEE_AT_HALF);

    config.destroy_for_testing();
}

// ── Symmetric invariant: paired legs sum to FS ± 2·spread ───────────────────

#[test]
fun positive_aggregate_pushes_up_leg_up_and_dn_leg_down() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    // ratio = 0.4 at p_up(K) = 0.5 → m(K) = 0.5 + 0.4 · 0.5 = 0.7.
    let agg = i64::from_parts(aggregate_for_ratio(400_000_000, BALANCE, depth), false);

    let (mint_up, redeem_up) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());
    let (mint_dn, redeem_dn) = dn_leg(&config, HALF, &agg, BALANCE, seven_days_ms());

    // UP leg: m(K) = 0.7. mint = 0.71. redeem = 0.69.
    assert_eq!(mint_up, 710_000_000);
    assert_eq!(redeem_up, 690_000_000);
    // DN leg: shifted_mid = FS − 0.7 = 0.3. mint = 0.31. redeem = 0.29.
    assert_eq!(mint_dn, 310_000_000);
    assert_eq!(redeem_dn, 290_000_000);

    // Symmetric invariant: paired-leg cost = FS + 2·spread, paid out = FS − 2·spread.
    assert_eq!(mint_up + mint_dn, FS + 2 * FEE_AT_HALF);
    assert_eq!(redeem_up + redeem_dn, FS - 2 * FEE_AT_HALF);

    config.destroy_for_testing();
}

#[test]
fun negative_aggregate_mirrors_with_up_dn_swap() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    // ratio = −0.4 → m(K) = 0.5 − 0.4 · 0.5 = 0.3.
    let agg = i64::from_parts(aggregate_for_ratio(400_000_000, BALANCE, depth), true);

    let (mint_up, redeem_up) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());
    let (mint_dn, redeem_dn) = dn_leg(&config, HALF, &agg, BALANCE, seven_days_ms());

    // UP leg: m(K) = 0.3. mint = 0.31. redeem = 0.29.
    assert_eq!(mint_up, 310_000_000);
    assert_eq!(redeem_up, 290_000_000);
    // DN leg: shifted_mid = FS − 0.3 = 0.7. mint = 0.71. redeem = 0.69.
    assert_eq!(mint_dn, 710_000_000);
    assert_eq!(redeem_dn, 690_000_000);

    assert_eq!(mint_up + mint_dn, FS + 2 * FEE_AT_HALF);
    assert_eq!(redeem_up + redeem_dn, FS - 2 * FEE_AT_HALF);

    config.destroy_for_testing();
}

#[test]
fun paired_legs_sum_invariant_holds_across_aggregate_sweep() {
    // For any non-saturating aggregate, mint_up + mint_dn = FS + 2·spread and
    // redeem_up + redeem_dn = FS − 2·spread. The invariant only fails at the
    // FS / 0 clamps; this sweep stays well inside the unsaturated regime.
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();

    let cases = vector[
        i64::zero(),
        i64::from_parts(aggregate_for_ratio(50_000_000, BALANCE, depth), false),
        i64::from_parts(aggregate_for_ratio(50_000_000, BALANCE, depth), true),
        i64::from_parts(aggregate_for_ratio(300_000_000, BALANCE, depth), false),
        i64::from_parts(aggregate_for_ratio(300_000_000, BALANCE, depth), true),
        i64::from_parts(aggregate_for_ratio(600_000_000, BALANCE, depth), false),
        i64::from_parts(aggregate_for_ratio(600_000_000, BALANCE, depth), true),
    ];

    let mut i = 0;
    while (i < cases.length()) {
        let (mint_up, redeem_up) = up_leg(&config, HALF, &cases[i], BALANCE, seven_days_ms());
        let (mint_dn, redeem_dn) = dn_leg(&config, HALF, &cases[i], BALANCE, seven_days_ms());

        assert_eq!(mint_up + mint_dn, FS + 2 * FEE_AT_HALF);
        assert_eq!(redeem_up + redeem_dn, FS - 2 * FEE_AT_HALF);
        i = i + 1;
    };

    config.destroy_for_testing();
}

// ── Above-fair redeem / below-fair mint allowed under heavy imbalance ───────

#[test]
fun positive_aggregate_lifts_up_leg_redeem_above_fair() {
    // Heavy short-UP inventory: LP buys UP back from users at *above* fair to
    // incentivise them to close. Old design floored redeem at fair; new design
    // lets the mid walk.
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(800_000_000, BALANCE, depth), false);

    let (_, redeem_up) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());

    // ratio = 0.8 → m(K) = 0.5 + 0.8 · 0.5 = 0.9. redeem = 0.9 − 0.01 = 0.89.
    assert_eq!(redeem_up, 890_000_000);
    assert!(redeem_up > HALF);

    config.destroy_for_testing();
}

#[test]
fun negative_aggregate_drops_up_leg_mint_below_fair() {
    // Heavy long-UP inventory: LP sells UP to new users at *below* fair to
    // attract offsetting flow.
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(800_000_000, BALANCE, depth), true);

    let (mint_up, _) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());

    // ratio = −0.8 → m(K) = 0.1. mint = 0.11.
    assert_eq!(mint_up, 110_000_000);
    assert!(mint_up < HALF);

    config.destroy_for_testing();
}

// ── Saturation: ratio_mag clamps at 1.0; mid lands at the binary boundary ──

#[test]
fun saturated_positive_ratio_drives_up_leg_mid_to_one() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    // raw ratio = 5.0 → clamps to 1.0 → m(K) = 0.5 + 1 · 0.5 = 1.0.
    let agg = i64::from_parts(aggregate_for_ratio(5 * FS, BALANCE, depth), false);

    let (mint_up, redeem_up) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());

    // mint = (FS + 0.01).min(FS) = FS. redeem = FS − 0.01 = 0.99.
    assert_eq!(mint_up, FS);
    assert_eq!(redeem_up, FS - FEE_AT_HALF);

    config.destroy_for_testing();
}

#[test]
fun saturated_negative_ratio_drives_up_leg_mid_to_zero() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(5 * FS, BALANCE, depth), true);

    let (mint_up, redeem_up) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());

    // m(K) = 0. mint = 0 + 0.01 = 0.01. redeem = 0.
    assert_eq!(mint_up, FEE_AT_HALF);
    assert_eq!(redeem_up, 0);

    config.destroy_for_testing();
}

// ── Short-circuit guards ────────────────────────────────────────────────────

#[test]
fun balance_zero_disables_skew() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(900_000_000, BALANCE, depth), false);

    let (mint_price, redeem_price) = up_leg(&config, HALF, &agg, 0, seven_days_ms());

    assert_eq!(mint_price, HALF + FEE_AT_HALF);
    assert_eq!(redeem_price, HALF - FEE_AT_HALF);

    config.destroy_for_testing();
}

#[test]
fun zero_aggregate_short_circuits_even_with_extreme_inputs() {
    let mut config = pricing_config::new();
    config.set_min_tte_ms(1);
    let agg = i64::zero();

    let (mint_price, redeem_price) = up_leg(&config, HALF, &agg, 1, 0);

    assert_eq!(mint_price, HALF + FEE_AT_HALF);
    assert_eq!(redeem_price, HALF - FEE_AT_HALF);

    config.destroy_for_testing();
}

// ── Sentinel boundary inertness ─────────────────────────────────────────────

#[test]
fun sentinel_higher_boundary_contributes_zero_to_shift() {
    // UP-K range `(K, +∞]`: m(+∞) must be exactly 0 regardless of aggregate.
    // We assert this indirectly: at saturating positive ratio, the shifted_mid
    // is exactly m(K) (not m(K) + ratio · 1). If `m(0) ≠ 0`, the shifted_mid
    // would exceed FS and the .min(FS) clamp would kick in for both mint and
    // redeem alike — but we observe redeem = m(K) − spread strictly below FS.
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    // ratio = 0.6 → m(K) = 0.5 + 0.6 · 0.5 = 0.8. Sentinel m(0) = 0.
    let agg = i64::from_parts(aggregate_for_ratio(600_000_000, BALANCE, depth), false);

    let (mint_up, redeem_up) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());

    // shifted_mid = m(K) − m(+∞) = 0.8 − 0 = 0.8.
    assert_eq!(mint_up, 810_000_000);
    assert_eq!(redeem_up, 790_000_000);

    config.destroy_for_testing();
}

#[test]
fun sentinel_lower_boundary_holds_dn_mid_at_one_minus_strike_mid() {
    // DN-K range `(−∞, K]`: m(−∞) must be exactly FS regardless of aggregate.
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    // ratio = 0.6 → m(K) = 0.8. shifted_mid = FS − 0.8 = 0.2.
    let agg = i64::from_parts(aggregate_for_ratio(600_000_000, BALANCE, depth), false);

    let (mint_dn, redeem_dn) = dn_leg(&config, HALF, &agg, BALANCE, seven_days_ms());

    // mint = 0.2 + 0.01 = 0.21. redeem = 0.2 − 0.01 = 0.19.
    assert_eq!(mint_dn, 210_000_000);
    assert_eq!(redeem_dn, 190_000_000);

    config.destroy_for_testing();
}

// ── Range monotonicity guard ────────────────────────────────────────────────

#[test]
fun shifted_mid_does_not_underflow_for_valid_strike_ordering() {
    // Range `(L, H]` with both finite: p_up(L) > p_up(H). Sweep aggregates of
    // both signs near saturation and verify `compute_range_quote` does not
    // arithmetic-underflow on `m_lower − m_higher`. (The bug this guards is a
    // monotonicity break in `shifted_up_strike_mid` that would let the higher
    // boundary's shifted mid exceed the lower boundary's.)
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();

    let p_lower = 700_000_000; // p_up(L) = 0.7
    let p_higher = 300_000_000; // p_up(H) = 0.3
    let fair_range = p_lower - p_higher; // 0.4

    let cases = vector[
        i64::zero(),
        i64::from_parts(aggregate_for_ratio(990_000_000, BALANCE, depth), false),
        i64::from_parts(aggregate_for_ratio(990_000_000, BALANCE, depth), true),
        i64::from_parts(aggregate_for_ratio(5 * FS, BALANCE, depth), false),
        i64::from_parts(aggregate_for_ratio(5 * FS, BALANCE, depth), true),
    ];

    let mut i = 0;
    while (i < cases.length()) {
        let (mint, redeem) = config.compute_range_quote(
            fair_range,
            p_lower,
            p_higher,
            &cases[i],
            0,
            BALANCE,
            seven_days_ms(),
        );
        // Sanity bounds: prices live in [0, FS]; redeem ≤ mint.
        assert!(mint <= FS);
        assert!(redeem <= mint);
        i = i + 1;
    };

    config.destroy_for_testing();
}

// ── TTE amplification ───────────────────────────────────────────────────────

#[test]
fun shorter_tte_amplifies_skew_versus_reference_tte() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(100_000_000, BALANCE, depth), false);

    let (mint_far, _) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());
    let (mint_near, _) = up_leg(&config, HALF, &agg, BALANCE, constants::default_min_tte_ms!());

    // ratio_far = 0.10 → m(K) = 0.55 → mint = 0.56.
    assert_eq!(mint_far, 560_000_000);
    // ratio_near = 0.10 · √7 > 0.10 · 2.6 = 0.26 → m(K) > 0.63 → mint > 0.64.
    assert!(mint_near > 640_000_000);

    config.destroy_for_testing();
}

#[test]
fun tte_below_min_clamps_to_min_tte_factor() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(100_000_000, BALANCE, depth), false);

    let (mint_at_min, _) = up_leg(&config, HALF, &agg, BALANCE, constants::default_min_tte_ms!());
    let (mint_below_min, _) = up_leg(&config, HALF, &agg, BALANCE, 1);
    let (mint_at_zero, _) = up_leg(&config, HALF, &agg, BALANCE, 0);

    assert_eq!(mint_at_min, mint_below_min);
    assert_eq!(mint_at_min, mint_at_zero);

    config.destroy_for_testing();
}

// ── Asymmetric room at extreme fair prices ──────────────────────────────────

#[test]
fun positive_skew_at_low_fair_price_has_full_room_to_one() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    // Saturated positive ratio at p_up(K) = 0.20.
    let agg = i64::from_parts(aggregate_for_ratio(5 * FS, BALANCE, depth), false);

    let (mint_up, redeem_up) = up_leg(&config, TWENTY_CENT, &agg, BALANCE, seven_days_ms());

    // m(K) = 0.20 + 1.0 · (1 − 0.20) = 1.0; mint clamps at FS.
    assert_eq!(mint_up, FS);
    // spread at p=0.20: 2% · √(0.20·0.80) = 2% · 0.4 = 0.8%.
    // redeem = FS − 0.008 = 0.992.
    assert_eq!(redeem_up, 992_000_000);

    config.destroy_for_testing();
}

#[test]
fun negative_skew_at_high_fair_price_has_full_room_to_zero() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(5 * FS, BALANCE, depth), true);

    let (mint_up, redeem_up) = up_leg(&config, EIGHTY_CENT, &agg, BALANCE, seven_days_ms());

    // m(K) = 0.80 − 1.0 · 0.80 = 0; redeem floored at 0.
    // mint = 0 + 0.008 = 0.008.
    assert_eq!(mint_up, 8_000_000);
    assert_eq!(redeem_up, 0);

    config.destroy_for_testing();
}

// ── Half-saturated skew at off-center fair prices ───────────────────────────

#[test]
fun positive_skew_uses_room_to_one_at_twenty_cent_fair() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    // ratio = 0.5 at p_up(K) = 0.20 → m(K) = 0.20 + 0.5 · 0.80 = 0.60.
    let agg = i64::from_parts(aggregate_for_ratio(500_000_000, BALANCE, depth), false);

    let (mint_up, redeem_up) = up_leg(&config, TWENTY_CENT, &agg, BALANCE, seven_days_ms());

    // mint = 0.60 + 0.008 = 0.608. redeem = 0.60 − 0.008 = 0.592.
    assert_eq!(mint_up, 608_000_000);
    assert_eq!(redeem_up, 592_000_000);

    config.destroy_for_testing();
}

#[test]
fun negative_skew_uses_room_to_zero_at_eighty_cent_fair() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    // ratio = −0.5 at p_up(K) = 0.80 → m(K) = 0.80 − 0.5 · 0.80 = 0.40.
    let agg = i64::from_parts(aggregate_for_ratio(500_000_000, BALANCE, depth), true);

    let (mint_up, redeem_up) = up_leg(&config, EIGHTY_CENT, &agg, BALANCE, seven_days_ms());

    // mint = 0.40 + 0.008 = 0.408. redeem = 0.40 − 0.008 = 0.392.
    assert_eq!(mint_up, 408_000_000);
    assert_eq!(redeem_up, 392_000_000);

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

    let (mint_price, redeem_price) = up_leg(&config, HALF, &net, BALANCE, seven_days_ms());
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
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();

    let small_agg = i64::from_parts(aggregate_for_ratio(10_000_000, BALANCE, depth), false);
    let medium_agg = i64::from_parts(aggregate_for_ratio(100_000_000, BALANCE, depth), false);
    let large_agg = i64::from_parts(aggregate_for_ratio(500_000_000, BALANCE, depth), false);

    let (mint_small, _) = up_leg(&config, HALF, &small_agg, BALANCE, seven_days_ms());
    let (mint_medium, _) = up_leg(&config, HALF, &medium_agg, BALANCE, seven_days_ms());
    let (mint_large, _) = up_leg(&config, HALF, &large_agg, BALANCE, seven_days_ms());

    assert!(mint_small < mint_medium);
    assert!(mint_medium < mint_large);

    config.destroy_for_testing();
}

#[test]
fun redeem_price_is_strictly_decreasing_in_negative_aggregate() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();

    let small_agg = i64::from_parts(aggregate_for_ratio(10_000_000, BALANCE, depth), true);
    let medium_agg = i64::from_parts(aggregate_for_ratio(100_000_000, BALANCE, depth), true);
    let large_agg = i64::from_parts(aggregate_for_ratio(500_000_000, BALANCE, depth), true);

    let (_, redeem_small) = up_leg(&config, HALF, &small_agg, BALANCE, seven_days_ms());
    let (_, redeem_medium) = up_leg(&config, HALF, &medium_agg, BALANCE, seven_days_ms());
    let (_, redeem_large) = up_leg(&config, HALF, &large_agg, BALANCE, seven_days_ms());

    assert!(redeem_small > redeem_medium);
    assert!(redeem_medium > redeem_large);

    config.destroy_for_testing();
}

#[test]
fun doubling_aggregate_doubles_pre_clamp_shift() {
    // While the ratio is below 1.0, the shift is linear in the aggregate.
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();

    let agg = i64::from_parts(aggregate_for_ratio(100_000_000, BALANCE, depth), false);
    let agg_2x = i64::from_parts(aggregate_for_ratio(200_000_000, BALANCE, depth), false);

    let (mint, _) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());
    let (mint_2x, _) = up_leg(&config, HALF, &agg_2x, BALANCE, seven_days_ms());

    // ratio 0.10 → m(K) = 0.55 → mint = 0.56.
    // ratio 0.20 → m(K) = 0.60 → mint = 0.61.
    assert_eq!(mint, 560_000_000);
    assert_eq!(mint_2x, 610_000_000);
    assert_eq!(mint_2x - HALF - FEE_AT_HALF, 2 * (mint - HALF - FEE_AT_HALF));

    config.destroy_for_testing();
}

// ── Per-strike weight scales the impact: ATM weight bites harder than OTM ───

#[test]
fun higher_per_strike_weight_pushes_mint_further_for_same_qty() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();

    let qty = 1_000_000_000u64;
    let mag_otm = ((qty as u128) * 50_000_000u128 / (FS as u128)) as u64; // n ≈ 0.05
    let mag_atm = ((qty as u128) * 350_000_000u128 / (FS as u128)) as u64; // n ≈ 0.35

    let agg_otm = i64::from_parts(mag_otm, false);
    let agg_atm = i64::from_parts(mag_atm, false);
    let denom = (qty as u128) * (depth as u128) / (FS as u128);
    let balance = (denom * 1_000u128 / (depth as u128) * (FS as u128) / 1_000u128) as u64;

    let (mint_otm, _) = up_leg(&config, HALF, &agg_otm, balance, seven_days_ms());
    let (mint_atm, _) = up_leg(&config, HALF, &agg_atm, balance, seven_days_ms());

    assert!(mint_atm > mint_otm);

    config.destroy_for_testing();
}

// ── tte_factor at known ratios ──────────────────────────────────────────────

#[test]
fun tte_factor_equals_one_when_tte_matches_reference() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(100_000_000, BALANCE, depth), false);

    let (mint, _) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());

    // ratio = 0.10 → m(K) = 0.55 → mint = 0.56.
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

    let (mint, _) = up_leg(&config, HALF, &agg, BALANCE, quarter_tte);

    // ratio = 0.10 · 2 = 0.20 → m(K) = 0.60 → mint = 0.61.
    assert_eq!(mint, 610_000_000);

    config.destroy_for_testing();
}

#[test]
fun tte_factor_halves_at_four_times_reference_tte() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(100_000_000, BALANCE, depth), false);
    let four_x_tte = 4 * constants::default_reference_tte_ms!();

    let (mint, _) = up_leg(&config, HALF, &agg, BALANCE, four_x_tte);

    // ratio = 0.10 · 0.5 = 0.05 → m(K) = 0.525 → mint = 0.535.
    assert_eq!(mint, 535_000_000);

    config.destroy_for_testing();
}

// ── Ratio clamp behavior at the saturation boundary ─────────────────────────

#[test]
fun ratio_at_exactly_one_saturates_to_full_room() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(FS, BALANCE, depth), false);

    let (mint, redeem) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());

    // m(K) = 0.5 + 1.0 · 0.5 = 1.0 → mint = FS, redeem = FS − 0.01.
    assert_eq!(mint, FS);
    assert_eq!(redeem, FS - FEE_AT_HALF);

    config.destroy_for_testing();
}

#[test]
fun ratio_just_below_one_does_not_quite_saturate() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(999_000_000, BALANCE, depth), false);

    let (mint, redeem) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());

    // m(K) = 0.5 + 0.999 · 0.5 = 0.9995. mint = (0.9995 + 0.01).min(FS) = FS.
    assert_eq!(mint, FS);
    // redeem = 0.9995 − 0.01 = 0.9895.
    assert_eq!(redeem, 989_500_000);

    config.destroy_for_testing();
}

// ── Sub-spread shift: shifted_mid stays close to fair, no underflow on redeem

#[test]
fun negative_aggregate_with_shift_below_spread_keeps_mint_above_fair() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    // ratio = -0.005 → m(K) = 0.4975; spread (1%) > shift (0.0025).
    let agg = i64::from_parts(aggregate_for_ratio(5_000_000, BALANCE, depth), true);

    let (mint, _) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());

    // mint = 0.4975 + 0.01 = 0.5075. Above fair because spread > shift.
    assert_eq!(mint, 507_500_000);

    config.destroy_for_testing();
}

#[test]
fun positive_aggregate_with_shift_below_spread_keeps_redeem_below_fair() {
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(5_000_000, BALANCE, depth), false);

    let (_, redeem) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());

    // m(K) = 0.5025 → redeem = 0.5025 − 0.01 = 0.4925.
    assert_eq!(redeem, 492_500_000);

    config.destroy_for_testing();
}

// ── Rejected fair prices (settled boundaries) ───────────────────────────────

#[test, expected_failure(abort_code = pricing_config::EFairPriceAlreadySettled)]
fun compute_range_quote_aborts_when_fair_range_is_one() {
    // FS == 1.0 means the binary settled "yes". No live fee applies.
    let config = pricing_config::new();
    let agg = i64::zero();
    let (_, _) = config.compute_range_quote(FS, FS, 0, &agg, 0, BALANCE, seven_days_ms());
    abort 999
}

#[test, expected_failure(abort_code = pricing_config::EFairPriceAlreadySettled)]
fun compute_range_quote_aborts_when_fair_range_is_zero() {
    let config = pricing_config::new();
    let agg = i64::zero();
    let (_, _) = config.compute_range_quote(0, HALF, HALF, &agg, 0, BALANCE, seven_days_ms());
    abort 999
}

// ── Round-trip cost: 2·spread regardless of skew ────────────────────────────

#[test]
fun round_trip_cost_with_zero_aggregate_equals_two_spreads() {
    let config = pricing_config::new();
    let agg = i64::zero();

    let (mint, redeem) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());

    assert_eq!(mint - redeem, 2 * FEE_AT_HALF);

    config.destroy_for_testing();
}

#[test]
fun round_trip_cost_is_two_spreads_under_skew() {
    // Symmetric design: mint = m(K) + spread, redeem = m(K) − spread, so a
    // round-trip on the same leg always costs exactly 2·spread regardless of
    // the inventory shift.
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(100_000_000, BALANCE, depth), false);

    let (mint, redeem) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());

    assert_eq!(mint, 560_000_000);
    assert_eq!(redeem, 540_000_000);
    assert_eq!(mint - redeem, 2 * FEE_AT_HALF);

    config.destroy_for_testing();
}

// ── Very small balance: aggregate saturates the clamp instantly ─────────────

#[test]
fun tiny_balance_relative_to_aggregate_saturates_immediately() {
    let config = pricing_config::new();
    let agg = i64::from_parts(1_000_000_000_000, false);
    let tiny_balance = 1_000_000u64;

    let (mint, redeem) = up_leg(&config, HALF, &agg, tiny_balance, seven_days_ms());

    assert_eq!(mint, FS);
    assert_eq!(redeem, FS - FEE_AT_HALF);

    config.destroy_for_testing();
}

// ── Asymmetric room exact boundaries ────────────────────────────────────────

#[test]
fun positive_skew_at_one_cent_fair_uses_full_room_to_one() {
    // Far OTM (fair = 1¢): room for positive skew is 99¢.
    // spread at p=0.01: 2% · √(0.01·0.99) ≈ 0.199% — but min_fee floor (0.5%) kicks in.
    let config = pricing_config::new();
    let depth = constants::default_depth_multiplier!();
    let agg = i64::from_parts(aggregate_for_ratio(100_000_000, BALANCE, depth), false);

    let (mint, redeem) = up_leg(&config, 10_000_000, &agg, BALANCE, seven_days_ms());

    // ratio = 0.10 → m(K) = 0.01 + 0.10 · 0.99 = 0.109.
    // spread floor = 0.5% (min_fee) → mint = 0.109 + 0.005 = 0.114.
    assert_eq!(mint, 114_000_000);
    // redeem = 0.109 − 0.005 = 0.104.
    assert_eq!(redeem, 104_000_000);

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
