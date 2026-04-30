// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::strike_matrix_aggregate_tests;

use deepbook_predict::{constants, i64, strike_matrix};
use std::unit_test::{assert_eq, destroy};
use sui::{clock, test_scenario};

const FS: u64 = 1_000_000_000;
const TICK_SIZE: u64 = 1_000_000;
const MIN_STRIKE: u64 = 1_000_000;
const MAX_STRIKE: u64 = 100_000_000;

const QTY: u64 = 1_000_000;
const STRIKE_LOW: u64 = 10_000_000;
const STRIKE_HIGH: u64 = 50_000_000;

// Hand-derived weights at two strikes (representative `n(d₂)` magnitudes,
// not tied to any particular SVI surface — the matrix doesn't compute them,
// it just folds them into the aggregate).
const WEIGHT_LOW: u64 = 300_000_000; // 0.30
const WEIGHT_HIGH: u64 = 100_000_000; // 0.10

fun new_matrix(scenario: &mut test_scenario::Scenario): strike_matrix::StrikeMatrix {
    scenario.next_tx(@0xa);
    let clock = clock::create_for_testing(scenario.ctx());
    let matrix = strike_matrix::new(scenario.ctx(), TICK_SIZE, MIN_STRIKE, MAX_STRIKE, &clock);
    destroy(clock);
    matrix
}

/// `qty · weight / FS` — the magnitude `apply_aggregate_delta` folds in.
fun weighted_magnitude(qty: u64, weight: u64): u64 {
    ((qty as u128) * (weight as u128) / (FS as u128)) as u64
}

// ── Fresh matrix has zero aggregate ─────────────────────────────────────────

#[test]
fun new_matrix_has_zero_aggregate() {
    let mut scenario = test_scenario::begin(@0xa);
    let matrix = new_matrix(&mut scenario);

    let aggregate = matrix.directional_aggregate();
    assert!(aggregate.is_zero());

    destroy(matrix);
    scenario.end();
}

// ── Insert range updates aggregate by qty·(lower_weight − higher_weight) ────

#[test]
fun insert_range_folds_lower_weight_positively_and_higher_weight_negatively() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);

    matrix.insert_range(STRIKE_LOW, STRIKE_HIGH, QTY, WEIGHT_LOW, WEIGHT_HIGH);

    let aggregate = matrix.directional_aggregate();
    let expected = weighted_magnitude(QTY, WEIGHT_LOW) - weighted_magnitude(QTY, WEIGHT_HIGH);
    assert_eq!(aggregate.magnitude(), expected);
    assert!(!aggregate.is_negative());

    destroy(matrix);
    scenario.end();
}

#[test]
fun insert_range_with_higher_weight_dominant_yields_negative_aggregate() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);

    // Swap roles so higher leg's weight is bigger — net long DN portion
    // (e.g., user is buying a range whose upper boundary is closer to ATM).
    matrix.insert_range(STRIKE_LOW, STRIKE_HIGH, QTY, WEIGHT_HIGH, WEIGHT_LOW);

    let aggregate = matrix.directional_aggregate();
    let expected = weighted_magnitude(QTY, WEIGHT_LOW) - weighted_magnitude(QTY, WEIGHT_HIGH);
    assert_eq!(aggregate.magnitude(), expected);
    assert!(aggregate.is_negative());

    destroy(matrix);
    scenario.end();
}

// ── Round-trip cancels exactly when weights are unchanged ───────────────────

#[test]
fun insert_then_remove_with_same_weights_returns_aggregate_to_zero() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);

    matrix.insert_range(STRIKE_LOW, STRIKE_HIGH, QTY, WEIGHT_LOW, WEIGHT_HIGH);
    matrix.remove_range(STRIKE_LOW, STRIKE_HIGH, QTY, WEIGHT_LOW, WEIGHT_HIGH);

    assert!(matrix.directional_aggregate().is_zero());

    destroy(matrix);
    scenario.end();
}

#[test]
fun remove_at_different_weights_leaves_residual_in_aggregate() {
    // Known approximation: when the SVI surface drifts between mint and redeem,
    // the close leg's weight differs from the open leg's weight, so a residual
    // `qty · (w_open − w_close)` remains.
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);

    let w_open_lower = 300_000_000u64;
    let w_open_higher = 100_000_000u64;
    let w_close_lower = 250_000_000u64;
    let w_close_higher = 80_000_000u64;

    matrix.insert_range(STRIKE_LOW, STRIKE_HIGH, QTY, w_open_lower, w_open_higher);
    matrix.remove_range(STRIKE_LOW, STRIKE_HIGH, QTY, w_close_lower, w_close_higher);

    // Net = (w_open_lower − w_close_lower) − (w_open_higher − w_close_higher),
    // weighted by qty / FS.
    let lower_residual_mag = weighted_magnitude(QTY, w_open_lower - w_close_lower);
    let higher_residual_mag = weighted_magnitude(QTY, w_open_higher - w_close_higher);
    let expected = lower_residual_mag - higher_residual_mag;

    let aggregate = matrix.directional_aggregate();
    assert_eq!(aggregate.magnitude(), expected);
    assert!(!aggregate.is_negative());

    destroy(matrix);
    scenario.end();
}

// ── Multiple inserts accumulate linearly ────────────────────────────────────

#[test]
fun sequential_inserts_accumulate_aggregate_linearly() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);

    matrix.insert_range(STRIKE_LOW, STRIKE_HIGH, QTY, WEIGHT_LOW, WEIGHT_HIGH);
    matrix.insert_range(STRIKE_LOW, STRIKE_HIGH, QTY, WEIGHT_LOW, WEIGHT_HIGH);
    matrix.insert_range(STRIKE_LOW, STRIKE_HIGH, QTY, WEIGHT_LOW, WEIGHT_HIGH);

    let single_delta =
        weighted_magnitude(QTY, WEIGHT_LOW)
        - weighted_magnitude(QTY, WEIGHT_HIGH);

    assert_eq!(matrix.directional_aggregate().magnitude(), 3 * single_delta);

    destroy(matrix);
    scenario.end();
}

// ── Order-size monotonicity ─────────────────────────────────────────────────

#[test]
fun larger_qty_produces_proportionally_larger_aggregate_update() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut small_matrix = new_matrix(&mut scenario);
    let mut large_matrix = new_matrix(&mut scenario);

    // Same fixture, two independent matrices.

    small_matrix.insert_range(STRIKE_LOW, STRIKE_HIGH, QTY, WEIGHT_LOW, WEIGHT_HIGH);
    // 10× the quantity at the same strikes/weights.
    large_matrix.insert_range(STRIKE_LOW, STRIKE_HIGH, 10 * QTY, WEIGHT_LOW, WEIGHT_HIGH);

    let small_mag = small_matrix.directional_aggregate().magnitude();
    let large_mag = large_matrix.directional_aggregate().magnitude();

    // Larger order moves aggregate by exactly 10× — same sign, same shape.
    assert_eq!(large_mag, 10 * small_mag);

    destroy(small_matrix);
    destroy(large_matrix);
    scenario.end();
}

// ── Sentinel boundaries treat the unbounded leg as zero-weight ──────────────

#[test]
fun upper_sentinel_range_contributes_only_lower_weight() {
    // `(K, +∞]` is "user is long UP@K". Caller passes `higher_weight = 0`
    // because `oracle::compute_risk_weight(pos_inf!()) == 0` — there's no
    // strike-dependent risk at the +∞ boundary.
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);

    matrix.insert_range(STRIKE_LOW, constants::pos_inf!(), QTY, WEIGHT_LOW, 0);

    let aggregate = matrix.directional_aggregate();
    assert_eq!(aggregate.magnitude(), weighted_magnitude(QTY, WEIGHT_LOW));
    assert!(!aggregate.is_negative());

    destroy(matrix);
    scenario.end();
}

#[test]
fun lower_sentinel_range_contributes_only_higher_weight_negatively() {
    // `(-∞, K]` is "user is long DN@K" — `lower_weight = 0` at the −∞ boundary,
    // and the K boundary is the short-UP leg (negative aggregate contribution).
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);

    matrix.insert_range(constants::neg_inf!(), STRIKE_LOW, QTY, 0, WEIGHT_LOW);

    let aggregate = matrix.directional_aggregate();
    assert_eq!(aggregate.magnitude(), weighted_magnitude(QTY, WEIGHT_LOW));
    assert!(aggregate.is_negative());

    destroy(matrix);
    scenario.end();
}

// ── No-op guards ────────────────────────────────────────────────────────────

#[test]
fun zero_qty_is_a_no_op_on_aggregate() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);

    matrix.insert_range(STRIKE_LOW, STRIKE_HIGH, 0, WEIGHT_LOW, WEIGHT_HIGH);
    assert!(matrix.directional_aggregate().is_zero());

    destroy(matrix);
    scenario.end();
}

#[test]
fun zero_weights_are_a_no_op_on_aggregate() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);

    matrix.insert_range(STRIKE_LOW, STRIKE_HIGH, QTY, 0, 0);
    assert!(matrix.directional_aggregate().is_zero());

    destroy(matrix);
    scenario.end();
}

// ── Per-matrix isolation (analog of per-oracle isolation in the vault) ──────

#[test]
fun two_matrices_track_independent_aggregates() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix_a = new_matrix(&mut scenario);
    let matrix_b = new_matrix(&mut scenario);

    matrix_a.insert_range(STRIKE_LOW, STRIKE_HIGH, QTY, WEIGHT_LOW, WEIGHT_HIGH);
    // matrix_b stays untouched.

    let agg_a = matrix_a.directional_aggregate();
    let agg_b = matrix_b.directional_aggregate();

    assert!(!agg_a.is_zero());
    assert!(agg_b.is_zero());

    destroy(matrix_a);
    destroy(matrix_b);
    scenario.end();
}

// ── Sign convention: insert + opposing-side insert net to zero magnitude ───

#[test]
fun insert_up_then_insert_dn_at_same_strike_cancel() {
    // Going long UP at K via `(K, pos_inf]` and short UP at K via `(-inf, K]`
    // (a user buying both sides of a binary) leaves zero directional inventory.
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);

    matrix.insert_range(STRIKE_LOW, constants::pos_inf!(), QTY, WEIGHT_LOW, 0);
    matrix.insert_range(constants::neg_inf!(), STRIKE_LOW, QTY, 0, WEIGHT_LOW);

    assert!(matrix.directional_aggregate().is_zero());

    destroy(matrix);
    scenario.end();
}

// ── Smoke: matrix's aggregate type is non-droppable; explicit destroy works ─

#[test]
fun aggregate_value_is_copyable_for_external_reads() {
    let mut scenario = test_scenario::begin(@0xa);
    let mut matrix = new_matrix(&mut scenario);

    matrix.insert_range(STRIKE_LOW, STRIKE_HIGH, QTY, WEIGHT_LOW, WEIGHT_HIGH);

    // Two reads return values that compare equal — the I64 value is `copy`,
    // so external pricing layers can stash it without mutating the matrix.
    let a = matrix.directional_aggregate();
    let b = matrix.directional_aggregate();
    assert_eq!(a.magnitude(), b.magnitude());
    assert!(a.is_negative() == b.is_negative());
    let _zero_check = i64::add(&a, &b.neg());
    assert!(_zero_check.is_zero());

    destroy(matrix);
    scenario.end();
}
