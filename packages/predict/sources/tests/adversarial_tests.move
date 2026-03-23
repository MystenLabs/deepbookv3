// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Adversarial tests probing rounding/truncation for exploitability.
///
/// These tests define correct behavior: the contract MUST reject
/// operations that would produce 0 shares (which enable theft via
/// rounding). Tests use expected_failure to verify the guards work.
#[test_only]
module deepbook_predict::adversarial_tests;

use deepbook::math;
use deepbook_predict::{math as predict_math, supply_manager};
use std::unit_test::{assert_eq, destroy};

const FLOAT: u64 = 1_000_000_000;
const ALICE: address = @0xA;
const BOB: address = @0xB;

// ============================================================
// Supply Manager: Zero-share mint must be rejected
// ============================================================

#[test, expected_failure(abort_code = supply_manager::EZeroSharesMinted)]
/// Depositing a tiny amount into a large vault would yield 0 shares.
/// The contract must reject this to prevent donation of funds to existing LPs.
fun supply_rejects_zero_share_mint() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);

    // 1 unit into a 1B vault → mul(1, div(1M, 1B)) = mul(1, 1M) = 0 shares
    // Must abort — depositor would lose their funds
    sm.supply(1, 1_000_000_000, BOB);

    abort
}

#[test, expected_failure(abort_code = supply_manager::EZeroSharesMinted)]
/// Classic ERC-4626 inflation attack: first depositor deposits 1 unit,
/// donates to inflate share price, next depositor gets 0 shares.
/// The contract must reject the second deposit.
fun inflation_attack_blocked() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    // Attacker deposits 1 unit (gets 1 share)
    sm.supply(1, 0, ALICE);

    // Attacker donates to inflate vault to 1_000_001
    // Bob deposits 1_000_000 → div(1, 1_000_001) = 999, mul(1M, 999) = 0
    // Must abort — Bob would lose 1_000_000
    sm.supply(1_000_000, 1_000_001, BOB);

    abort
}

#[test, expected_failure(abort_code = supply_manager::EZeroSharesMinted)]
/// Even amounts just below the threshold must be rejected.
/// With vault_value=3M and total_shares=1M:
/// div(1M, 3M) = 333_333_333, mul(3, 333_333_333) = 999_999_999/1e9 = 0
fun supply_rejects_below_threshold_amount() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);

    // 3 units → 0 shares at 3x vault value
    sm.supply(3, 3_000_000, BOB);

    abort
}

#[test]
/// The minimum deposit that yields 1 share must succeed.
fun supply_accepts_minimum_for_one_share() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);

    // 4 units → mul(4, 333_333_333) = 1_333_333_332/1e9 = 1 share
    let shares = sm.supply(4, 3_000_000, BOB);
    assert_eq!(shares, 1);

    destroy(sm);
}

// ============================================================
// Supply Manager: Zero-share withdrawal must be rejected
// ============================================================

#[test, expected_failure(abort_code = supply_manager::EZeroSharesBurned)]
/// Withdrawing a tiny amount from a large vault would burn 0 shares.
/// The contract must reject this — otherwise the user gets free money.
fun withdraw_rejects_zero_share_burn() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);

    // 1 unit from 1B vault → mul(1, div(1M, 1B)) = 0 shares burned
    // Must abort — Alice would extract value without burning shares
    sm.withdraw(1, 1_000_000_000, ALICE);

    abort
}

#[test, expected_failure(abort_code = supply_manager::EZeroSharesBurned)]
/// Repeated tiny withdrawals would drain the vault if allowed.
/// Even a single 0-share withdrawal must be rejected.
fun withdraw_rejects_small_amount_at_high_vault_value() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);

    // 3 units from 3M vault → mul(3, div(1M, 3M)) = mul(3, 333_333_333) = 0
    sm.withdraw(3, 3_000_000, ALICE);

    abort
}

#[test]
/// The minimum withdrawal that burns 1 share must succeed.
fun withdraw_accepts_minimum_for_one_share() {
    let ctx = &mut tx_context::dummy();
    let mut sm = supply_manager::new(ctx);

    sm.supply(1_000_000, 0, ALICE);

    // 4 units from 3M vault → mul(4, 333_333_333) = 1 share burned
    let burned = sm.withdraw(4, 3_000_000, ALICE);
    assert_eq!(burned, 1);

    destroy(sm);
}

// ============================================================
// Normal CDF: Pricing symmetry
// ============================================================

#[test]
/// Φ(x) + Φ(-x) must equal exactly 1e9 for all x.
/// If this breaks, UP + DOWN prices don't sum to the discount factor,
/// creating an arbitrage opportunity.
fun cdf_symmetry_invariant_holds() {
    let test_values = vector[
        0,
        1,
        100,
        1_000,
        10_000,
        100_000,
        1_000_000,
        10_000_000,
        100_000_000,
        250_000_000,
        500_000_000,
        750_000_000,
        FLOAT,
        2 * FLOAT,
        3 * FLOAT,
        4 * FLOAT,
        5 * FLOAT,
        6 * FLOAT,
        7 * FLOAT,
        8 * FLOAT,
    ];

    test_values.do!(|x| {
        let pos = predict_math::normal_cdf(x, false);
        let neg = predict_math::normal_cdf(x, true);
        assert_eq!(pos + neg, FLOAT);
    });
}

#[test]
/// Φ(0) produces 500_000_002 instead of the true 500_000_000.
/// This 2-unit error is inherent to the Abramowitz polynomial approximation.
/// At practical quantities (1 contract = 1_000_000 USDC units),
/// the price error rounds to 0 USDC — not exploitable.
fun cdf_at_zero_error_is_not_exploitable() {
    let phi_zero = predict_math::normal_cdf(0, false);
    assert_eq!(phi_zero, 500_000_002);

    // At 1 contract quantity, error = mul(1_000_000, 2) = 0 USDC
    assert_eq!(math::mul(1_000_000, 2), 0);

    // Even at 1000 contracts, error = mul(1e9, 2) = 2 USDC units ($0.000002)
    assert_eq!(math::mul(1_000_000_000, 2), 2);
}

// ============================================================
// Normal CDF: Monotonicity
// ============================================================

#[test]
/// CDF must be strictly monotonically increasing.
/// A non-monotonic CDF would allow buying cheap at one strike
/// and selling expensive at an adjacent strike.
fun cdf_strictly_monotonic() {
    let mut prev = predict_math::normal_cdf(0, false);
    let steps = vector[
        10_000_000,
        20_000_000,
        50_000_000,
        100_000_000,
        200_000_000,
        500_000_000,
        FLOAT,
        1_500_000_000,
        2 * FLOAT,
        3 * FLOAT,
    ];

    steps.do!(|x| {
        let current = predict_math::normal_cdf(x, false);
        assert!(current > prev);
        prev = current;
    });
}

// ============================================================
// Exp: Discount factor integrity
// ============================================================

#[test]
/// exp(-x) must never exceed 1.0 for any positive x.
/// A discount > 1.0 means future payouts worth MORE than present — arbitrage.
fun discount_factor_never_exceeds_one() {
    let test_rt = vector[
        1,
        100,
        1_000,
        10_000,
        100_000,
        1_000_000,
        10_000_000,
        50_000_000,
        100_000_000,
        500_000_000,
        FLOAT,
        2 * FLOAT,
        5 * FLOAT,
    ];

    test_rt.do!(|rt| {
        let discount = predict_math::exp(rt, true);
        assert!(discount <= FLOAT);
    });

    assert_eq!(predict_math::exp(0, true), FLOAT);
}

#[test]
/// exp(x) * exp(-x) should be close to 1.0.
/// For exact powers of ln(2), the roundtrip is perfect.
/// For other values, truncation causes at most 2 units of error.
fun exp_roundtrip_error_bounded() {
    // Exact at powers of ln(2)
    let pos = predict_math::exp(693_147_181, false);
    let neg = predict_math::exp(693_147_181, true);
    assert_eq!(math::mul(pos, neg), FLOAT);

    // At x=1: 2_718_281_818 * 367_879_442 / 1e9 = 999_999_998
    // 2 units below 1e9 — bounded and not exploitable
    let e = predict_math::exp(FLOAT, false);
    let e_inv = predict_math::exp(FLOAT, true);
    let product = math::mul(e, e_inv);
    assert_eq!(product, 999_999_998);
    // Error is exactly 2 units, must never be negative (> FLOAT)
    assert!(product <= FLOAT);
}
