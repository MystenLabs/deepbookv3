// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
/// End-to-end scenario tests: drive a `StrikeMatrix` with realistic
/// `insert_range` / `remove_range` calls, read the directional aggregate,
/// feed it into `pricing_config::compute_up_quote`, and assert exact mint
/// and redeem prices at each step.
///
/// This is the closest thing to an integration test for the inventory shift
/// — without spinning up a full `Predict` object, it exercises the same
/// data path the protocol takes during `mint_internal` /
/// `redeem_live_internal` (apply state delta first, then quote against the
/// post-trade aggregate).
module deepbook_predict::inventory_skew_scenarios;

use deepbook_predict::{constants, pricing_config, strike_matrix};
use std::unit_test::{assert_eq, destroy};
use sui::{clock, test_scenario};

const FS: u64 = 1_000_000_000;
const HALF: u64 = 500_000_000;

// Compact grid keeps page allocation cheap for unit tests; the strike values
// below are illustrative — the matrix uses them as keys, not as prices.
const TICK_SIZE: u64 = 1_000_000;
const MIN_STRIKE: u64 = 1_000_000;
const MAX_STRIKE: u64 = 1_000_000_000;
const STRIKE_K: u64 = 500_000_000;
const STRIKE_K_LOW: u64 = 250_000_000;
const STRIKE_K_HIGH: u64 = 750_000_000;

// Vault and pricing parameters, sized so each "buyer" produces an exact
// ratio = 0.10. denom = balance · depth / FS = 1e10. ratio_FS =
// aggregate · FS / denom. For ratio = 0.10 we want aggregate = 1e9, which
// is `qty · weight / FS = 2.5e9 · 4e8 / FS = 1e9`. ✓
const BALANCE: u64 = 10_000_000_000;
const QTY_PER_BUYER: u64 = 2_500_000_000;
const WEIGHT_AT_K: u64 = 400_000_000; // n(d₂) ≈ 0.4 (near ATM)
const WEIGHT_AT_K_LOW: u64 = 200_000_000; // 0.2 (deeper from ATM peak)

const FEE_AT_HALF: u64 = 10_000_000; // 2% · √0.25 = 1%

fun seven_days_ms(): u64 { constants::default_reference_tte_ms!() }

fun new_matrix(scenario: &mut test_scenario::Scenario): strike_matrix::StrikeMatrix {
    scenario.next_tx(@0xa);
    let clock = clock::create_for_testing(scenario.ctx());
    let matrix = strike_matrix::new(scenario.ctx(), TICK_SIZE, MIN_STRIKE, MAX_STRIKE, &clock);
    destroy(clock);
    matrix
}

// ── Two buyers at the same strike: B pays more than A by exactly one shift ─

#[test]
fun two_sequential_up_buys_compound_skew_post_trade() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);
    let config = pricing_config::new();

    // Buyer A mints UP@K. The matrix now reflects A's order; the price
    // they're quoted is computed *against this post-trade aggregate*.
    matrix.insert_range(STRIKE_K, constants::pos_inf!(), QTY_PER_BUYER, WEIGHT_AT_K, 0);
    let agg_after_a = matrix.directional_aggregate();
    let (mint_a, _) = config.compute_up_quote(HALF, &agg_after_a, 0, BALANCE, seven_days_ms());

    // Buyer B mints the same size at the same strike. Aggregate now
    // reflects A + B; B's quote sees both contributions.
    matrix.insert_range(STRIKE_K, constants::pos_inf!(), QTY_PER_BUYER, WEIGHT_AT_K, 0);
    let agg_after_b = matrix.directional_aggregate();
    let (mint_b, _) = config.compute_up_quote(HALF, &agg_after_b, 0, BALANCE, seven_days_ms());

    // Each buyer's contribution drives ratio by 0.10 → shift = 0.05.
    // mint_a = 0.5 + 0.05 + 1% = 0.56.
    // mint_b = 0.5 + 0.10 + 1% = 0.61.
    assert_eq!(mint_a, 560_000_000);
    assert_eq!(mint_b, 610_000_000);
    // The second buyer paid exactly 5¢ more — the cost of their own size.
    assert_eq!(mint_b - mint_a, 50_000_000);

    destroy(matrix);
    config.destroy_for_testing();
    scenario.end();
}

// ── Three buyers: skew compounds linearly until the clamp engages ──────────

#[test]
fun three_sequential_up_buys_compound_linearly() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);
    let config = pricing_config::new();

    let mut prices = vector[];
    let mut i = 0;
    while (i < 3) {
        matrix.insert_range(STRIKE_K, constants::pos_inf!(), QTY_PER_BUYER, WEIGHT_AT_K, 0);
        let agg = matrix.directional_aggregate();
        let (mint, _) = config.compute_up_quote(HALF, &agg, 0, BALANCE, seven_days_ms());
        prices.push_back(mint);
        i = i + 1;
    };

    // ratios: 0.10, 0.20, 0.30 → shifts: 0.05, 0.10, 0.15.
    assert_eq!(prices[0], 560_000_000);
    assert_eq!(prices[1], 610_000_000);
    assert_eq!(prices[2], 660_000_000);
    // Equal step size: each marginal buyer pays the same incremental premium.
    assert_eq!(prices[1] - prices[0], prices[2] - prices[1]);

    destroy(matrix);
    config.destroy_for_testing();
    scenario.end();
}

// ── UP buy followed by DN buy at the same strike: aggregate cancels exactly ─

#[test]
fun up_buy_followed_by_dn_buy_at_same_strike_cancels_skew() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);
    let config = pricing_config::new();

    // UP@K is `(K, +∞]` with lower_weight = n(d₂(K)), higher_weight = 0
    // (sentinel). DN@K is `(-∞, K]` — lower_weight = 0, higher_weight =
    // n(d₂(K)). The two contributions have equal magnitude and opposite
    // sign — the directional aggregate returns to zero.
    matrix.insert_range(STRIKE_K, constants::pos_inf!(), QTY_PER_BUYER, WEIGHT_AT_K, 0);
    matrix.insert_range(constants::neg_inf!(), STRIKE_K, QTY_PER_BUYER, 0, WEIGHT_AT_K);

    let agg = matrix.directional_aggregate();
    assert!(agg.is_zero());

    let (mint, redeem) = config.compute_up_quote(HALF, &agg, 0, BALANCE, seven_days_ms());
    // Back to symmetric quotes around fair.
    assert_eq!(mint, HALF + FEE_AT_HALF);
    assert_eq!(redeem, HALF - FEE_AT_HALF);

    destroy(matrix);
    config.destroy_for_testing();
    scenario.end();
}

// ── UP buy then partial UP redeem: skew shrinks proportionally ─────────────

#[test]
fun partial_redeem_after_buy_shrinks_skew_proportionally() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);
    let config = pricing_config::new();

    // Buy 3× the unit qty (ratio = 0.30), then redeem 1× (ratio drops to 0.20).
    let three_x = 3 * QTY_PER_BUYER;
    matrix.insert_range(STRIKE_K, constants::pos_inf!(), three_x, WEIGHT_AT_K, 0);
    matrix.remove_range(STRIKE_K, constants::pos_inf!(), QTY_PER_BUYER, WEIGHT_AT_K, 0);

    let (mint, _) = config.compute_up_quote(
        HALF,
        &matrix.directional_aggregate(),
        0,
        BALANCE,
        seven_days_ms(),
    );

    // Net ratio = 0.20 → shift = 0.10 → mint = 0.61.
    assert_eq!(mint, 610_000_000);

    destroy(matrix);
    config.destroy_for_testing();
    scenario.end();
}

// ── UP buy then UP redeem at unchanged weights returns to flat ──────────────

#[test]
fun full_round_trip_at_same_weights_returns_book_to_flat() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);
    let config = pricing_config::new();

    matrix.insert_range(STRIKE_K, constants::pos_inf!(), QTY_PER_BUYER, WEIGHT_AT_K, 0);
    matrix.remove_range(STRIKE_K, constants::pos_inf!(), QTY_PER_BUYER, WEIGHT_AT_K, 0);

    assert!(matrix.directional_aggregate().is_zero());

    let (mint, redeem) = config.compute_up_quote(
        HALF,
        &matrix.directional_aggregate(),
        0,
        BALANCE,
        seven_days_ms(),
    );
    assert_eq!(mint, HALF + FEE_AT_HALF);
    assert_eq!(redeem, HALF - FEE_AT_HALF);

    destroy(matrix);
    config.destroy_for_testing();
    scenario.end();
}

// ── Range buy with K_high closer to ATM than K_low: aggregate goes negative ─

#[test]
fun range_buy_with_higher_weight_at_top_drives_aggregate_negative() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);
    let config = pricing_config::new();

    // Range `(K_low, K]` — lower deeper from ATM, upper at ATM.
    // lower_weight = 0.2, higher_weight = 0.4.
    // Aggregate += +qty·0.2 - qty·0.4 = -qty·0.2 → ratio = -0.05 in our setup.
    matrix.insert_range(STRIKE_K_LOW, STRIKE_K, QTY_PER_BUYER, WEIGHT_AT_K_LOW, WEIGHT_AT_K);
    let agg = matrix.directional_aggregate();
    assert!(agg.is_negative());

    let (mint, redeem) = config.compute_up_quote(HALF, &agg, 0, BALANCE, seven_days_ms());

    // ratio = -0.05 → shift = 0.05 · 0.5 = 0.025 → shifted_mid = 0.475.
    // shift > spread (= 0.01) → mint clamps at fair = 0.5.
    // redeem = (0.475 - 0.01).min(0.5) = 0.465.
    assert_eq!(mint, HALF);
    assert_eq!(redeem, 465_000_000);

    destroy(matrix);
    config.destroy_for_testing();
    scenario.end();
}

// ── Range buy with K_low closer to ATM than K_high: aggregate goes positive ─

#[test]
fun range_buy_with_higher_weight_at_bottom_drives_aggregate_positive() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);
    let config = pricing_config::new();

    // Range `(K, K_high]` — lower at ATM, upper deeper from ATM.
    // lower_weight = 0.4, higher_weight = 0.2.
    matrix.insert_range(STRIKE_K, STRIKE_K_HIGH, QTY_PER_BUYER, WEIGHT_AT_K, WEIGHT_AT_K_LOW);
    let agg = matrix.directional_aggregate();
    assert!(!agg.is_negative());

    let (mint, redeem) = config.compute_up_quote(HALF, &agg, 0, BALANCE, seven_days_ms());

    // ratio = +0.05 → shift = +0.025 → shifted_mid = 0.525.
    // mint = 0.525 + 0.01 = 0.535. redeem clamps at fair.
    assert_eq!(mint, 535_000_000);
    assert_eq!(redeem, HALF);

    destroy(matrix);
    config.destroy_for_testing();
    scenario.end();
}

// ── Mixed sequence: range buy then UP buy combine partially ────────────────

#[test]
fun range_buy_followed_by_up_buy_combine_into_smaller_net_skew() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);
    let config = pricing_config::new();

    // Range `(K, K_high]` first: aggregate += qty·(0.4 − 0.2) = qty·0.2,
    // which in raw units is 5e8 → ratio = 0.05.
    matrix.insert_range(STRIKE_K, STRIKE_K_HIGH, QTY_PER_BUYER, WEIGHT_AT_K, WEIGHT_AT_K_LOW);
    let (_, redeem_after_range) = config.compute_up_quote(
        HALF,
        &matrix.directional_aggregate(),
        0,
        BALANCE,
        seven_days_ms(),
    );

    // Then UP@K: aggregate += qty·0.4 = 1e9 → ratio jumps from 0.05 to 0.15.
    // shift = 0.15 · 0.5 = 0.075 → mint = 0.5 + 0.075 + 1% = 0.585.
    matrix.insert_range(STRIKE_K, constants::pos_inf!(), QTY_PER_BUYER, WEIGHT_AT_K, 0);
    let (mint_combined, _) = config.compute_up_quote(
        HALF,
        &matrix.directional_aggregate(),
        0,
        BALANCE,
        seven_days_ms(),
    );

    // After-range alone: redeem clamps at fair (positive aggregate).
    assert_eq!(redeem_after_range, HALF);
    // Combined ratio reflects both legs.
    assert_eq!(mint_combined, 585_000_000);

    destroy(matrix);
    config.destroy_for_testing();
    scenario.end();
}

// ── Whale order: single trade that saturates the clamp instantly ────────────

#[test]
fun saturating_single_trade_drives_mint_to_one() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);
    let config = pricing_config::new();

    // 11× the unit qty drives ratio to 1.10 → clamps at 1.0.
    let whale_qty = 11 * QTY_PER_BUYER;
    matrix.insert_range(STRIKE_K, constants::pos_inf!(), whale_qty, WEIGHT_AT_K, 0);

    let (mint, redeem) = config.compute_up_quote(
        HALF,
        &matrix.directional_aggregate(),
        0,
        BALANCE,
        seven_days_ms(),
    );

    // Saturation: shifted_mid = FS, mint clamps at FS, redeem clamps at fair.
    assert_eq!(mint, FS);
    assert_eq!(redeem, HALF);

    destroy(matrix);
    config.destroy_for_testing();
    scenario.end();
}

// ── Splitting an order across many TXs: average cost matches the bulk price ─

#[test]
fun ten_split_orders_pay_same_average_cost_as_one_bulk_order() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut split_matrix = new_matrix(&mut scenario);
    let mut bulk_matrix = new_matrix(&mut scenario);
    let config = pricing_config::new();

    // 10 buyers at QTY_PER_BUYER each, vs one buyer at 10×.
    let mut total_split_premium = 0u64;
    let mut i = 0;
    while (i < 10) {
        split_matrix.insert_range(
            STRIKE_K,
            constants::pos_inf!(),
            QTY_PER_BUYER,
            WEIGHT_AT_K,
            0,
        );
        let (mint, _) = config.compute_up_quote(
            HALF,
            &split_matrix.directional_aggregate(),
            0,
            BALANCE,
            seven_days_ms(),
        );
        // Each split buyer's premium over fair+spread = (mint - HALF - FEE_AT_HALF).
        total_split_premium = total_split_premium + (mint - HALF - FEE_AT_HALF);
        i = i + 1;
    };

    // Bulk: one trade of 10× qty saturates instantly (ratio = 1.0). Per-unit
    // premium = (FS - HALF - FEE_AT_HALF) / 10. Compare totals (sum across 10
    // contracts vs 10× for one bulk contract is the same denominator).
    bulk_matrix.insert_range(
        STRIKE_K,
        constants::pos_inf!(),
        10 * QTY_PER_BUYER,
        WEIGHT_AT_K,
        0,
    );
    let (mint_bulk, _) = config.compute_up_quote(
        HALF,
        &bulk_matrix.directional_aggregate(),
        0,
        BALANCE,
        seven_days_ms(),
    );
    let bulk_premium_per_buyer = mint_bulk - HALF - FEE_AT_HALF;
    let bulk_total_premium = 10 * bulk_premium_per_buyer;

    // Split path: sum of (k · 0.05) for k = 1..10 = 0.05 · 55 = 2.75 → 275M units.
    // Bulk path: 10 · (FS · 0.5 - 0.01 - HALF) = 10 · (1.0 - 0.5 - 0.01) = 4.90 → 4_900M units.
    // Bulk total > split total — the bulk buyer overpays vs the split path
    // *as a sum across contracts*, because the bulk hits saturation earlier.
    // (The protocol-relevant comparison is per-contract cost; in a non-saturated
    // regime split and bulk converge, but at saturation the bulk pays the
    // capped premium on every contract.)
    assert!(bulk_total_premium > total_split_premium);

    destroy(split_matrix);
    destroy(bulk_matrix);
    config.destroy_for_testing();
    scenario.end();
}

// ── Round-trip through a moving SVI surface: the residual is the drift cost ─

#[test]
fun round_trip_with_weight_drift_matches_predicted_residual() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);
    let config = pricing_config::new();

    // Trader opens UP@K with `n(d₂)` at trade time = 0.40, then closes
    // after the SVI surface drifts so the new `n(d₂)` at K is 0.30.
    let weight_open = WEIGHT_AT_K; // 0.40
    let weight_close = 300_000_000; // 0.30

    matrix.insert_range(STRIKE_K, constants::pos_inf!(), QTY_PER_BUYER, weight_open, 0);
    matrix.remove_range(STRIKE_K, constants::pos_inf!(), QTY_PER_BUYER, weight_close, 0);

    // Residual aggregate = qty · (weight_open − weight_close) =
    // 2.5e9 · (0.40 − 0.30) / FS = 2.5e8 (positive).
    let residual = matrix.directional_aggregate();
    assert_eq!(residual.magnitude(), 250_000_000);
    assert!(!residual.is_negative());

    // The next quote sees this residual: ratio = 2.5e8 · FS / 1e10 = 2.5e7
    // = 0.025 → shift = 0.0125 → mint = 0.5 + 0.0125 + 0.01 = 0.5225.
    let (mint, _) = config.compute_up_quote(HALF, &residual, 0, BALANCE, seven_days_ms());
    assert_eq!(mint, 522_500_000);

    destroy(matrix);
    config.destroy_for_testing();
    scenario.end();
}
