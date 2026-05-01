// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
/// End-to-end scenario tests: drive a `StrikeMatrix` with realistic
/// `insert_range` / `remove_range` calls, read the directional aggregate,
/// feed it into `pricing_config::compute_range_quote`, and assert exact
/// mint and redeem prices at each step.
///
/// This is the closest thing to an integration test for the inventory shift
/// — without spinning up a full `Predict` object, it exercises the same
/// data path the protocol takes during `mint_internal` /
/// `redeem_live_internal` (apply state delta first, then quote against the
/// post-trade aggregate).
module deepbook_predict::inventory_skew_scenarios;

use deepbook_predict::{constants, i64::I64, pricing_config::{Self, PricingConfig}, strike_matrix};
use std::unit_test::{assert_eq, destroy};
use sui::{clock, test_scenario};

const FS: u64 = 1_000_000_000;
const HALF: u64 = 500_000_000;

const TICK_SIZE: u64 = 1_000_000;
const MIN_STRIKE: u64 = 1_000_000;
const MAX_STRIKE: u64 = 1_000_000_000;
const STRIKE_K: u64 = 500_000_000;
const STRIKE_K_LOW: u64 = 250_000_000;
const STRIKE_K_HIGH: u64 = 750_000_000;

// Sized so each "buyer" produces an exact ratio = 0.10 in our setup:
//   denom = balance · depth / FS = 1e10
//   aggregate_per_buyer = qty · weight / FS = 2.5e9 · 4e8 / FS = 1e9
//   ratio = aggregate · FS / denom = 1e9 · FS / 1e10 = 0.10.
const BALANCE: u64 = 10_000_000_000;
const QTY_PER_BUYER: u64 = 2_500_000_000;
const WEIGHT_AT_K: u64 = 400_000_000; // n(d₂) ≈ 0.4 (near ATM)
const WEIGHT_AT_K_LOW: u64 = 200_000_000; // 0.2 (deeper from ATM peak)

const FEE_AT_HALF: u64 = 10_000_000; // 2% · √0.25 = 1%

fun seven_days_ms(): u64 { constants::default_reference_tte_ms!() }

/// Quote a single-strike UP leg at K with `p_up(K) = fair`. Range form
/// `(K, +∞]` → `p_up_lower = fair`, `p_up_higher = 0`.
fun up_leg(config: &PricingConfig, fair: u64, agg: &I64, balance: u64, tte: u64): (u64, u64) {
    config.compute_range_quote(fair, fair, 0, agg, 0, balance, tte)
}

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
    let (mint_a, _) = up_leg(&config, HALF, &agg_after_a, BALANCE, seven_days_ms());

    // Buyer B mints the same size at the same strike.
    matrix.insert_range(STRIKE_K, constants::pos_inf!(), QTY_PER_BUYER, WEIGHT_AT_K, 0);
    let agg_after_b = matrix.directional_aggregate();
    let (mint_b, _) = up_leg(&config, HALF, &agg_after_b, BALANCE, seven_days_ms());

    // ratio_a = 0.10 → m(K) = 0.55 → mint_a = 0.56.
    // ratio_b = 0.20 → m(K) = 0.60 → mint_b = 0.61.
    assert_eq!(mint_a, 560_000_000);
    assert_eq!(mint_b, 610_000_000);
    assert_eq!(mint_b - mint_a, 50_000_000);

    destroy(matrix);
    config.destroy_for_testing();
    scenario.end();
}

// ── Three buyers: skew compounds linearly ──────────────────────────────────

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
        let (mint, _) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());
        prices.push_back(mint);
        i = i + 1;
    };

    // ratios: 0.10, 0.20, 0.30 → mints: 0.56, 0.61, 0.66.
    assert_eq!(prices[0], 560_000_000);
    assert_eq!(prices[1], 610_000_000);
    assert_eq!(prices[2], 660_000_000);
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

    matrix.insert_range(STRIKE_K, constants::pos_inf!(), QTY_PER_BUYER, WEIGHT_AT_K, 0);
    matrix.insert_range(constants::neg_inf!(), STRIKE_K, QTY_PER_BUYER, 0, WEIGHT_AT_K);

    let agg = matrix.directional_aggregate();
    assert!(agg.is_zero());

    let (mint, redeem) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());
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

    let three_x = 3 * QTY_PER_BUYER;
    matrix.insert_range(STRIKE_K, constants::pos_inf!(), three_x, WEIGHT_AT_K, 0);
    matrix.remove_range(STRIKE_K, constants::pos_inf!(), QTY_PER_BUYER, WEIGHT_AT_K, 0);

    let (mint, _) = up_leg(
        &config,
        HALF,
        &matrix.directional_aggregate(),
        BALANCE,
        seven_days_ms(),
    );

    // Net ratio = 0.20 → m(K) = 0.60 → mint = 0.61.
    assert_eq!(mint, 610_000_000);

    destroy(matrix);
    config.destroy_for_testing();
    scenario.end();
}

// ── UP buy then UP redeem at unchanged weights returns to flat ─────────────

#[test]
fun full_round_trip_at_same_weights_returns_book_to_flat() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);
    let config = pricing_config::new();

    matrix.insert_range(STRIKE_K, constants::pos_inf!(), QTY_PER_BUYER, WEIGHT_AT_K, 0);
    matrix.remove_range(STRIKE_K, constants::pos_inf!(), QTY_PER_BUYER, WEIGHT_AT_K, 0);

    assert!(matrix.directional_aggregate().is_zero());

    let (mint, redeem) = up_leg(
        &config,
        HALF,
        &matrix.directional_aggregate(),
        BALANCE,
        seven_days_ms(),
    );
    assert_eq!(mint, HALF + FEE_AT_HALF);
    assert_eq!(redeem, HALF - FEE_AT_HALF);

    destroy(matrix);
    config.destroy_for_testing();
    scenario.end();
}

// ── Range buy with K_high closer to ATM: aggregate goes negative ────────────

#[test]
fun range_buy_with_higher_weight_at_top_drives_aggregate_negative() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);
    let config = pricing_config::new();

    // Range `(K_low, K]` — lower weight 0.2, higher weight 0.4.
    // Aggregate += qty·(0.2 - 0.4) = -qty·0.2 → ratio = -0.05.
    matrix.insert_range(STRIKE_K_LOW, STRIKE_K, QTY_PER_BUYER, WEIGHT_AT_K_LOW, WEIGHT_AT_K);
    let agg = matrix.directional_aggregate();
    assert!(agg.is_negative());

    // Quote a separate UP-K leg at fair=HALF against this oracle aggregate.
    let (mint, redeem) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());

    // ratio = -0.05 → m(K) = 0.5 - 0.05·0.5 = 0.475.
    // mint = 0.475 + 0.01 = 0.485 (now below fair — the discount that draws
    // in the offsetting flow when the vault is long UP).
    // redeem = 0.475 - 0.01 = 0.465.
    assert_eq!(mint, 485_000_000);
    assert_eq!(redeem, 465_000_000);

    destroy(matrix);
    config.destroy_for_testing();
    scenario.end();
}

// ── Range buy with K_low closer to ATM: aggregate goes positive ─────────────

#[test]
fun range_buy_with_higher_weight_at_bottom_drives_aggregate_positive() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);
    let config = pricing_config::new();

    // Range `(K, K_high]` — lower weight 0.4, higher weight 0.2.
    matrix.insert_range(STRIKE_K, STRIKE_K_HIGH, QTY_PER_BUYER, WEIGHT_AT_K, WEIGHT_AT_K_LOW);
    let agg = matrix.directional_aggregate();
    assert!(!agg.is_negative());

    let (mint, redeem) = up_leg(&config, HALF, &agg, BALANCE, seven_days_ms());

    // ratio = +0.05 → m(K) = 0.525 → mint = 0.535, redeem = 0.515.
    assert_eq!(mint, 535_000_000);
    assert_eq!(redeem, 515_000_000);

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

    // Range `(K, K_high]`: aggregate += qty·(0.4 − 0.2). ratio = +0.05.
    matrix.insert_range(STRIKE_K, STRIKE_K_HIGH, QTY_PER_BUYER, WEIGHT_AT_K, WEIGHT_AT_K_LOW);
    let (_, redeem_after_range) = up_leg(
        &config,
        HALF,
        &matrix.directional_aggregate(),
        BALANCE,
        seven_days_ms(),
    );

    // Then UP@K: aggregate += qty·0.4 → ratio jumps from 0.05 to 0.15.
    matrix.insert_range(STRIKE_K, constants::pos_inf!(), QTY_PER_BUYER, WEIGHT_AT_K, 0);
    let (mint_combined, _) = up_leg(
        &config,
        HALF,
        &matrix.directional_aggregate(),
        BALANCE,
        seven_days_ms(),
    );

    // After-range alone: ratio=0.05 → m(K)=0.525 → redeem = 0.515.
    assert_eq!(redeem_after_range, 515_000_000);
    // Combined: ratio=0.15 → m(K) = 0.575 → mint = 0.585.
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

    let (mint, redeem) = up_leg(
        &config,
        HALF,
        &matrix.directional_aggregate(),
        BALANCE,
        seven_days_ms(),
    );

    // Saturation: m(K) = FS, mint clamps at FS, redeem = FS - spread.
    assert_eq!(mint, FS);
    assert_eq!(redeem, FS - FEE_AT_HALF);

    destroy(matrix);
    config.destroy_for_testing();
    scenario.end();
}

// ── Splitting an order across many TXs: bulk pays more total than split ─────

#[test]
fun ten_split_orders_pay_less_than_one_bulk_order() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut split_matrix = new_matrix(&mut scenario);
    let mut bulk_matrix = new_matrix(&mut scenario);
    let config = pricing_config::new();

    // 10 buyers at QTY_PER_BUYER each (ratios 0.10, 0.20, ..., 1.00 with the
    // 10th saturating). Sum of premiums over fair+spread:
    //   k=1..9: k·0.05·FS sum = 0.05·45·FS = 2.25e9
    //   k=10: saturates at m(K)=FS → mint=FS → premium = 0.49·FS = 0.49e9
    //   total = 2.74e9.
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
        let (mint, _) = up_leg(
            &config,
            HALF,
            &split_matrix.directional_aggregate(),
            BALANCE,
            seven_days_ms(),
        );
        total_split_premium = total_split_premium + (mint - HALF - FEE_AT_HALF);
        i = i + 1;
    };

    // Bulk: one trade of 10× qty saturates instantly.
    bulk_matrix.insert_range(
        STRIKE_K,
        constants::pos_inf!(),
        10 * QTY_PER_BUYER,
        WEIGHT_AT_K,
        0,
    );
    let (mint_bulk, _) = up_leg(
        &config,
        HALF,
        &bulk_matrix.directional_aggregate(),
        BALANCE,
        seven_days_ms(),
    );
    let bulk_premium_per_buyer = mint_bulk - HALF - FEE_AT_HALF;
    let bulk_total_premium = 10 * bulk_premium_per_buyer;

    // Bulk total > split total — the bulk hits saturation on every contract,
    // while the split path's first 9 buyers pay strictly less than the cap.
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

    let weight_open = WEIGHT_AT_K; // 0.40
    let weight_close = 300_000_000; // 0.30

    matrix.insert_range(STRIKE_K, constants::pos_inf!(), QTY_PER_BUYER, weight_open, 0);
    matrix.remove_range(STRIKE_K, constants::pos_inf!(), QTY_PER_BUYER, weight_close, 0);

    // Residual aggregate = qty · (weight_open − weight_close) = 2.5e8.
    let residual = matrix.directional_aggregate();
    assert_eq!(residual.magnitude(), 250_000_000);
    assert!(!residual.is_negative());

    // ratio = 0.025 → m(K) = 0.5 + 0.025·0.5 = 0.5125 → mint = 0.5225.
    let (mint, _) = up_leg(&config, HALF, &residual, BALANCE, seven_days_ms());
    assert_eq!(mint, 522_500_000);

    destroy(matrix);
    config.destroy_for_testing();
    scenario.end();
}
