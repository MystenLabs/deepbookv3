// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

#[test_only]
module deepbook_predict::treap_tests;

use deepbook_predict::{oracle::new_curve_point, treap};
use std::unit_test::{destroy, assert_eq};

const FLOAT: u64 = 1_000_000_000;

// === Insert & Size ===

#[test]
fun insert_single_up() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(50 * FLOAT, 10 * FLOAT, true);
    assert_eq!(t.size(), 1);
    assert!(!t.is_empty());

    destroy(t);
}

#[test]
fun insert_single_dn() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(50 * FLOAT, 10 * FLOAT, false);
    assert_eq!(t.size(), 1);

    destroy(t);
}

#[test]
fun insert_same_strike_both_directions() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(50 * FLOAT, 10 * FLOAT, true);
    t.insert(50 * FLOAT, 5 * FLOAT, false);
    // Same strike — should still be 1 node
    assert_eq!(t.size(), 1);

    destroy(t);
}

#[test]
fun insert_same_strike_accumulates() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(50 * FLOAT, 10 * FLOAT, true);
    t.insert(50 * FLOAT, 7 * FLOAT, true);
    assert_eq!(t.size(), 1);
    let (q_up, q_dn) = t.quantities(50 * FLOAT);
    assert_eq!(q_up, 17 * FLOAT);
    assert_eq!(q_dn, 0);

    destroy(t);
}

#[test]
fun insert_multiple_strikes() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(30 * FLOAT, 5 * FLOAT, true);
    t.insert(50 * FLOAT, 5 * FLOAT, true);
    t.insert(70 * FLOAT, 5 * FLOAT, true);
    assert_eq!(t.size(), 3);

    destroy(t);
}

// === Strike Range ===

#[test]
fun strike_range_empty() {
    let ctx = &mut tx_context::dummy();
    let t = treap::new(ctx);

    let (min, max) = t.strike_range();
    assert_eq!(min, 0);
    assert_eq!(max, 0);

    destroy(t);
}

#[test]
fun strike_range_single() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(50 * FLOAT, 10 * FLOAT, true);
    let (min, max) = t.strike_range();
    assert_eq!(min, 50 * FLOAT);
    assert_eq!(max, 50 * FLOAT);

    destroy(t);
}

#[test]
fun strike_range_multiple() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(30 * FLOAT, 5 * FLOAT, true);
    t.insert(70 * FLOAT, 5 * FLOAT, false);
    t.insert(50 * FLOAT, 5 * FLOAT, true);

    let (min, max) = t.strike_range();
    assert_eq!(min, 30 * FLOAT);
    assert_eq!(max, 70 * FLOAT);

    destroy(t);
}

// === Remove ===

#[test]
fun remove_partial_quantity() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(50 * FLOAT, 10 * FLOAT, true);
    t.remove(50 * FLOAT, 3 * FLOAT, true);
    assert_eq!(t.size(), 1);
    let (q_up, q_dn) = t.quantities(50 * FLOAT);
    assert_eq!(q_up, 7 * FLOAT);
    assert_eq!(q_dn, 0);

    destroy(t);
}

#[test]
fun remove_full_quantity_removes_node() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(50 * FLOAT, 10 * FLOAT, true);
    t.remove(50 * FLOAT, 10 * FLOAT, true);
    assert_eq!(t.size(), 0);
    assert!(t.is_empty());

    destroy(t);
}

#[test]
fun remove_one_direction_keeps_node() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(50 * FLOAT, 10 * FLOAT, true);
    t.insert(50 * FLOAT, 5 * FLOAT, false);
    t.remove(50 * FLOAT, 10 * FLOAT, true);
    // DN quantity remains — node should still exist
    assert_eq!(t.size(), 1);
    let (q_up, q_dn) = t.quantities(50 * FLOAT);
    assert_eq!(q_up, 0);
    assert_eq!(q_dn, 5 * FLOAT);

    destroy(t);
}

#[test]
fun remove_both_directions_removes_node() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(50 * FLOAT, 10 * FLOAT, true);
    t.insert(50 * FLOAT, 5 * FLOAT, false);
    t.remove(50 * FLOAT, 10 * FLOAT, true);
    t.remove(50 * FLOAT, 5 * FLOAT, false);
    assert!(t.is_empty());

    destroy(t);
}

#[test, expected_failure(abort_code = treap::EInsufficientQuantity)]
fun remove_excess_up_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(50 * FLOAT, 10 * FLOAT, true);
    t.remove(50 * FLOAT, 11 * FLOAT, true);

    abort
}

#[test, expected_failure(abort_code = treap::EInsufficientQuantity)]
fun remove_excess_dn_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(50 * FLOAT, 10 * FLOAT, false);
    t.remove(50 * FLOAT, 11 * FLOAT, false);

    abort
}

#[test, expected_failure(abort_code = treap::ENodeNotFound)]
fun remove_nonexistent_strike_aborts() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(50 * FLOAT, 10 * FLOAT, true);
    t.remove(60 * FLOAT, 5 * FLOAT, true);

    abort
}

// === Remove with rotations (stress the remove_node path) ===

#[test]
fun remove_middle_node_with_children() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    // Insert many strikes to force a multi-level tree
    t.insert(10 * FLOAT, 1 * FLOAT, true);
    t.insert(20 * FLOAT, 1 * FLOAT, true);
    t.insert(30 * FLOAT, 1 * FLOAT, true);
    t.insert(40 * FLOAT, 1 * FLOAT, true);
    t.insert(50 * FLOAT, 1 * FLOAT, true);
    t.insert(60 * FLOAT, 1 * FLOAT, true);
    t.insert(70 * FLOAT, 1 * FLOAT, true);
    assert_eq!(t.size(), 7);

    // Remove interior nodes — exercises rotation-during-removal
    t.remove(30 * FLOAT, 1 * FLOAT, true);
    assert_eq!(t.size(), 6);
    t.remove(50 * FLOAT, 1 * FLOAT, true);
    assert_eq!(t.size(), 5);

    let (min, max) = t.strike_range();
    assert_eq!(min, 10 * FLOAT);
    assert_eq!(max, 70 * FLOAT);

    destroy(t);
}

#[test]
fun remove_all_nodes_one_by_one() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    let strikes = vector[15, 25, 35, 45, 55];
    strikes.do!(|s| t.insert(s * FLOAT, 2 * FLOAT, true));
    assert_eq!(t.size(), 5);

    // Remove in a different order than insertion
    let removal_order = vector[35, 15, 55, 25, 45];
    removal_order.do!(|s| {
        t.remove(s * FLOAT, 2 * FLOAT, true);
    });

    assert!(t.is_empty());
    assert_eq!(t.size(), 0);

    destroy(t);
}

// === Strike range updates after removal ===

#[test]
fun strike_range_updates_after_min_removed() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(30 * FLOAT, 5 * FLOAT, true);
    t.insert(50 * FLOAT, 5 * FLOAT, true);
    t.insert(70 * FLOAT, 5 * FLOAT, true);

    t.remove(30 * FLOAT, 5 * FLOAT, true);
    let (min, max) = t.strike_range();
    assert_eq!(min, 50 * FLOAT);
    assert_eq!(max, 70 * FLOAT);

    destroy(t);
}

#[test]
fun strike_range_updates_after_max_removed() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(30 * FLOAT, 5 * FLOAT, true);
    t.insert(50 * FLOAT, 5 * FLOAT, true);
    t.insert(70 * FLOAT, 5 * FLOAT, true);

    t.remove(70 * FLOAT, 5 * FLOAT, true);
    let (min, max) = t.strike_range();
    assert_eq!(min, 30 * FLOAT);
    assert_eq!(max, 50 * FLOAT);

    destroy(t);
}

// === MTM getters/setters ===

#[test]
fun mtm_default_zero() {
    let ctx = &mut tx_context::dummy();
    let t = treap::new(ctx);
    assert_eq!(t.mtm(), 0);
    destroy(t);
}

#[test]
fun set_and_get_mtm() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);
    t.set_mtm(42 * FLOAT);
    assert_eq!(t.mtm(), 42 * FLOAT);
    destroy(t);
}

// === Evaluate ===

#[test]
fun evaluate_empty_treap() {
    let ctx = &mut tx_context::dummy();
    let t = treap::new(ctx);

    let curve = vector[
        new_curve_point(40 * FLOAT, 600_000_000, 400_000_000),
        new_curve_point(60 * FLOAT, 400_000_000, 600_000_000),
    ];
    assert_eq!(t.evaluate(&curve), 0);

    destroy(t);
}

#[test]
fun evaluate_empty_curve() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);
    t.insert(50 * FLOAT, 10 * FLOAT, true);

    let curve = vector[];
    assert_eq!(t.evaluate(&curve), 0);

    destroy(t);
}

#[test]
fun evaluate_single_up_position_flat_curve() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    // 10 FLOAT quantity at strike 50, UP direction
    t.insert(50 * FLOAT, 10 * FLOAT, true);

    // Flat curve: UP price = 0.5 everywhere
    let curve = vector[
        new_curve_point(40 * FLOAT, 500_000_000, 500_000_000),
        new_curve_point(60 * FLOAT, 500_000_000, 500_000_000),
    ];

    // value = qty * up_price = 10 * 0.5 = 5 FLOAT
    let value = t.evaluate(&curve);
    assert_eq!(value, 5 * FLOAT);

    destroy(t);
}

#[test]
fun evaluate_single_dn_position_flat_curve() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(50 * FLOAT, 10 * FLOAT, false);

    let curve = vector[
        new_curve_point(40 * FLOAT, 300_000_000, 700_000_000),
        new_curve_point(60 * FLOAT, 300_000_000, 700_000_000),
    ];

    // value = qty * dn_price = 10 * 0.7 = 7 FLOAT
    let value = t.evaluate(&curve);
    assert_eq!(value, 7 * FLOAT);

    destroy(t);
}

#[test]
fun evaluate_both_directions_flat_curve() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(50 * FLOAT, 10 * FLOAT, true);
    t.insert(50 * FLOAT, 6 * FLOAT, false);

    // Flat curve: UP = 0.4, DN = 0.6
    let curve = vector[
        new_curve_point(40 * FLOAT, 400_000_000, 600_000_000),
        new_curve_point(60 * FLOAT, 400_000_000, 600_000_000),
    ];

    // value = 10 * 0.4 + 6 * 0.6 = 4 + 3.6 = 7.6 FLOAT
    let value = t.evaluate(&curve);
    assert_eq!(value, 7_600_000_000);

    destroy(t);
}

#[test]
fun evaluate_position_at_curve_edge_left() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    // Position below the curve range — should clamp to first point
    t.insert(20 * FLOAT, 10 * FLOAT, true);

    let curve = vector[
        new_curve_point(40 * FLOAT, 800_000_000, 200_000_000),
        new_curve_point(60 * FLOAT, 400_000_000, 600_000_000),
    ];

    // Clamped to first point: UP price = 0.8
    let value = t.evaluate(&curve);
    assert_eq!(value, 8 * FLOAT);

    destroy(t);
}

#[test]
fun evaluate_position_at_curve_edge_right() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    // Position above the curve range — should clamp to last point
    t.insert(80 * FLOAT, 10 * FLOAT, true);

    let curve = vector[
        new_curve_point(40 * FLOAT, 800_000_000, 200_000_000),
        new_curve_point(60 * FLOAT, 400_000_000, 600_000_000),
    ];

    // Clamped to last point: UP price = 0.4
    let value = t.evaluate(&curve);
    assert_eq!(value, 4 * FLOAT);

    destroy(t);
}

#[test]
fun evaluate_multiple_strikes_flat_curve() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    // Three positions, all UP
    t.insert(30 * FLOAT, 5 * FLOAT, true);
    t.insert(50 * FLOAT, 5 * FLOAT, true);
    t.insert(70 * FLOAT, 5 * FLOAT, true);

    // Flat curve: UP = 0.5 everywhere
    let curve = vector[
        new_curve_point(20 * FLOAT, 500_000_000, 500_000_000),
        new_curve_point(80 * FLOAT, 500_000_000, 500_000_000),
    ];

    // value = 3 * (5 * 0.5) = 7.5 FLOAT
    let value = t.evaluate(&curve);
    assert_eq!(value, 7_500_000_000);

    destroy(t);
}

#[test]
fun evaluate_settled_step_function() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    // Position at strike 50, UP direction
    t.insert(50 * FLOAT, 10 * FLOAT, true);

    // Settled curve: settlement at 60 (above 50) — UP wins
    // UP price = 1.0 for strikes <= settlement, 0.0 above
    let curve = vector[
        new_curve_point(59 * FLOAT, FLOAT, 0),
        new_curve_point(60 * FLOAT, 0, FLOAT),
    ];

    // Strike 50 < settlement boundary 59, so UP = 1.0
    let value = t.evaluate(&curve);
    assert_eq!(value, 10 * FLOAT);

    destroy(t);
}

#[test]
fun evaluate_settled_step_function_losing() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    // Position at strike 70, UP direction
    t.insert(70 * FLOAT, 10 * FLOAT, true);

    // Settled at 60 — strike 70 is above settlement, UP loses
    let curve = vector[
        new_curve_point(59 * FLOAT, FLOAT, 0),
        new_curve_point(60 * FLOAT, 0, FLOAT),
    ];

    // Strike 70 > curve max (60), clamped to last point: UP = 0
    let value = t.evaluate(&curve);
    assert_eq!(value, 0);

    destroy(t);
}

// === Evaluate after insert + remove lifecycle ===

#[test]
fun evaluate_after_partial_remove() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(50 * FLOAT, 10 * FLOAT, true);
    t.remove(50 * FLOAT, 4 * FLOAT, true);

    // 6 FLOAT remaining
    let curve = vector[
        new_curve_point(40 * FLOAT, 500_000_000, 500_000_000),
        new_curve_point(60 * FLOAT, 500_000_000, 500_000_000),
    ];

    let value = t.evaluate(&curve);
    assert_eq!(value, 3 * FLOAT);

    destroy(t);
}

#[test]
fun evaluate_after_full_remove_returns_zero() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(50 * FLOAT, 10 * FLOAT, true);
    t.remove(50 * FLOAT, 10 * FLOAT, true);

    let curve = vector[
        new_curve_point(40 * FLOAT, 500_000_000, 500_000_000),
        new_curve_point(60 * FLOAT, 500_000_000, 500_000_000),
    ];

    assert_eq!(t.evaluate(&curve), 0);

    destroy(t);
}

// === Larger tree stress tests ===

#[test]
fun insert_and_remove_many_maintains_consistency() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    // Insert 10 strikes
    let mut i = 1u64;
    while (i <= 10) {
        t.insert(i * 10 * FLOAT, 3 * FLOAT, true);
        t.insert(i * 10 * FLOAT, 2 * FLOAT, false);
        i = i + 1;
    };
    assert_eq!(t.size(), 10);

    let (min, max) = t.strike_range();
    assert_eq!(min, 10 * FLOAT);
    assert_eq!(max, 100 * FLOAT);

    // Remove half the strikes entirely
    let mut i = 1u64;
    while (i <= 5) {
        t.remove(i * 10 * FLOAT, 3 * FLOAT, true);
        t.remove(i * 10 * FLOAT, 2 * FLOAT, false);
        i = i + 1;
    };
    assert_eq!(t.size(), 5);

    let (min, max) = t.strike_range();
    assert_eq!(min, 60 * FLOAT);
    assert_eq!(max, 100 * FLOAT);

    destroy(t);
}

#[test]
fun evaluate_many_positions_flat_curve() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    // 10 strikes, each with 1 FLOAT UP
    let mut i = 1u64;
    while (i <= 10) {
        t.insert(i * 10 * FLOAT, 1 * FLOAT, true);
        i = i + 1;
    };

    // Flat curve: UP = 0.3 everywhere
    let curve = vector[
        new_curve_point(5 * FLOAT, 300_000_000, 700_000_000),
        new_curve_point(105 * FLOAT, 300_000_000, 700_000_000),
    ];

    // value = 10 * 1 * 0.3 = 3 FLOAT
    let value = t.evaluate(&curve);
    assert_eq!(value, 3 * FLOAT);

    destroy(t);
}

// === Evaluate with sloped curves (interpolation) ===

#[test]
fun evaluate_interpolated_midpoint() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    // Position at strike 50 (midpoint of curve range 40..60)
    t.insert(50 * FLOAT, 10 * FLOAT, true);

    // Sloped: UP goes from 0.8 at strike 40 to 0.4 at strike 60
    let curve = vector[
        new_curve_point(40 * FLOAT, 800_000_000, 200_000_000),
        new_curve_point(60 * FLOAT, 400_000_000, 600_000_000),
    ];

    // interp_at: offset=10*F, range=20*F, ratio=div(10*F,20*F)=500_000_000
    // p_lo=800M > p_hi=400M: 800M - mul(400M, 500M) = 800M - 200M = 600M
    // value = mul(10*F, 600M) = 6*F
    let value = t.evaluate(&curve);
    assert_eq!(value, 6 * FLOAT);

    destroy(t);
}

#[test]
fun evaluate_interpolated_off_center() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    // Position at strike 47 — not a clean midpoint
    t.insert(47 * FLOAT, 10 * FLOAT, true);

    // Sloped: UP from 0.8 @ 40 to 0.4 @ 60
    let curve = vector[
        new_curve_point(40 * FLOAT, 800_000_000, 200_000_000),
        new_curve_point(60 * FLOAT, 400_000_000, 600_000_000),
    ];

    // interp_at: offset=7*F, range=20*F, ratio=div(7*F,20*F)=350_000_000
    // 800M - mul(400M, 350M) = 800M - 140M = 660M
    // value = mul(10*F, 660M) = 6_600_000_000
    let value = t.evaluate(&curve);
    assert_eq!(value, 6_600_000_000);

    destroy(t);
}

#[test]
fun evaluate_interpolated_dn_direction() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(50 * FLOAT, 8 * FLOAT, false);

    // DN goes from 0.2 @ 40 to 0.6 @ 60 (increasing)
    let curve = vector[
        new_curve_point(40 * FLOAT, 800_000_000, 200_000_000),
        new_curve_point(60 * FLOAT, 400_000_000, 600_000_000),
    ];

    // interp_at DN: offset=10*F, range=20*F, ratio=500M
    // p_lo=200M < p_hi=600M: 200M + mul(400M, 500M) = 200M + 200M = 400M
    // value = mul(8*F, 400M) = 3_200_000_000
    let value = t.evaluate(&curve);
    assert_eq!(value, 3_200_000_000);

    destroy(t);
}

#[test]
fun evaluate_interpolated_multi_segment_curve() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    // Two positions in different curve segments
    t.insert(35 * FLOAT, 10 * FLOAT, true);
    t.insert(75 * FLOAT, 10 * FLOAT, true);

    // 3-point curve: two segments with different slopes
    // Segment 1: strike 30..50, UP 0.9 → 0.5
    // Segment 2: strike 50..80, UP 0.5 → 0.2
    let curve = vector[
        new_curve_point(30 * FLOAT, 900_000_000, 100_000_000),
        new_curve_point(50 * FLOAT, 500_000_000, 500_000_000),
        new_curve_point(80 * FLOAT, 200_000_000, 800_000_000),
    ];

    // Node 35: ratio=div(5*F,20*F)=250M. 900M - mul(400M,250M) = 800M.
    //   val = mul(10*F, 800M) = 8_000_000_000
    // Node 75: ratio=div(25*F,30*F)=833_333_333. mul(300M,833_333_333)=249_999_999.
    //   price = 500M - 249_999_999 = 250_000_001. val = mul(10*F, 250_000_001) = 2_500_000_010
    // total = 8_000_000_000 + 2_500_000_010 = 10_500_000_010
    let value = t.evaluate(&curve);
    assert_eq!(value, 10_500_000_010);

    destroy(t);
}

#[test]
fun evaluate_interpolated_both_directions_sloped() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    t.insert(50 * FLOAT, 10 * FLOAT, true);
    t.insert(50 * FLOAT, 10 * FLOAT, false);

    // Sloped: UP 0.7→0.3, DN 0.3→0.7 across 40..60
    let curve = vector[
        new_curve_point(40 * FLOAT, 700_000_000, 300_000_000),
        new_curve_point(60 * FLOAT, 300_000_000, 700_000_000),
    ];

    // interp_at: midpoint ratio=500M
    // UP: 700M - mul(400M, 500M) = 500M. DN: 300M + mul(400M, 500M) = 500M.
    // value = mul(10*F, 500M) + mul(10*F, 500M) = 5*F + 5*F = 10*F
    let value = t.evaluate(&curve);
    assert_eq!(value, 10 * FLOAT);

    destroy(t);
}

#[test]
fun evaluate_many_positions_sloped_curve() {
    let ctx = &mut tx_context::dummy();
    let mut t = treap::new(ctx);

    // 5 UP positions at strikes 20, 40, 60, 80, 100
    t.insert(20 * FLOAT, 2 * FLOAT, true);
    t.insert(40 * FLOAT, 2 * FLOAT, true);
    t.insert(60 * FLOAT, 2 * FLOAT, true);
    t.insert(80 * FLOAT, 2 * FLOAT, true);
    t.insert(100 * FLOAT, 2 * FLOAT, true);

    // Sloped: UP from 0.9 @ strike 10 to 0.1 @ strike 110
    let curve = vector[
        new_curve_point(10 * FLOAT, 900_000_000, 100_000_000),
        new_curve_point(110 * FLOAT, 100_000_000, 900_000_000),
    ];

    // No interior curve points (only 2 curve points, both outside strike range),
    // so treap uses aggregates:
    // agg_q_up = 10*F, agg_qk_up = sum of mul(2*F, strike) for each strike
    // k_avg = div(agg_qk_up, agg_q_up) = 60*F (weighted average strike)
    // interp_at: offset=50*F, range=100*F, ratio=div(50*F,100*F)=500M
    // 900M - mul(800M, 500M) = 900M - 400M = 500M
    // value = mul(10*F, 500M) = 5*F
    let value = t.evaluate(&curve);
    assert_eq!(value, 5 * FLOAT);

    destroy(t);
}
