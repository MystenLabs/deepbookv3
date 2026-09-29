// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for `strike_payout_tree::walk_linear` — the NAV linear walk —
/// driven by a real live `Pricer` over standalone trees. These exercise paths
/// `current_nav` cannot reach directly: the skip-zero-delta path over an equal
/// live start/end boundary, and the boundary-aggregation dust clamp — the
/// flat-price-tail integer underflow the ATM `current_nav` fixtures miss.
///
/// The tree keys boundaries by absolute tick; the walk recovers each raw strike as
/// `tick * tick_size`. These tests use the default `tick_size` (1e9) so tick `100`
/// is raw strike `100e9`.
///
/// References are independent of the walk (unit-tests rule 1): the exact walk is
/// checked against a per-order `Σ mul(range_price, qty)` sum (a different pricer
/// path than the walk's `up_price`).
#[test_only]
module deepbook_predict::payout_tree_walk_tests;

use deepbook_predict::{
    constants,
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    pricing::{Self, Pricer},
    pricing_reference_data as ref_data,
    range_codec::{Self, Strike},
    strike_payout_tree::{Self, StrikePayoutTree},
    test_constants
};
use fixed_math::math;
use std::unit_test::{assert_eq, destroy};

/// Inflated SVI base variance (0.1 in 1e9 fixed point) so adjacent-tick strikes
/// price close together and smoothly — a real clustered-price regime.
const HIGH_VARIANCE_A: u64 = 100_000_000;
/// Dominant high-price quantity so the midpoint collapse visibly moves the mark.
const Q0: u64 = 10_000_000_000;
const Q1: u64 = 2_000_000_000;
const Q2: u64 = 2_000_000_000;
/// Forward far above the grid so low strikes sit in the deep-ITM flat price tail
/// where adjacent ticks price within a floor bucket — the dust-underflow regime.
const FLAT_REGION_FORWARD: u64 = 435_000_000_000;
/// Tiny quantity (a partial-close survivor) whose per-order range value rounds to
/// zero, so only boundary-aggregation rounding remains.
const DUST_QUANTITY: u64 = 100_000;
const GC_SURVIVOR_A_LOWER: u64 = 98;
const GC_REMOVED_LOWER: u64 = 100;
const GC_SURVIVOR_C_LOWER: u64 = 102;
const GC_SURVIVOR_A_HIGHER: u64 = 104;
const GC_REMOVED_HIGHER: u64 = 106;
const GC_SURVIVOR_C_HIGHER: u64 = 108;
/// Survivors left after the middle range is removed; bounds the aggregation dust.
const GC_SURVIVOR_COUNT: u64 = 2;
const GC_SURVIVOR_A_QUANTITY: u64 = 1_000_000_000;
const GC_REMOVED_QUANTITY: u64 = 500_000_000;
const GC_SURVIVOR_C_QUANTITY: u64 = 300_000_000;
const GC_SETTLEMENT_A_ONLY_TICK: u64 = 100;
const GC_SETTLEMENT_OVERLAP_TICK: u64 = 103;
const GC_SETTLEMENT_C_ONLY_TICK: u64 = 106;
/// Two adjacent equal-quantity ranges sharing one boundary, the second open-ended.
/// The shared tick's start and end cancel AND it is the last node in the tree, so
/// no later boundary can re-observe an inversion sitting on it.
const CANCEL_LOWER_TICK: u64 = 90;
const CANCEL_SHARED_TICK: u64 = 100;
const CANCEL_QUANTITY: u64 = 3_000_000;
/// Adjacent $10-grid ticks on committed real scenario 0 whose UP prices RISE by one
/// raw unit: `N(d2)` sits on the deep-ITM plateau while the floored skew term steps.
/// The surface itself is valid and butterfly-free — the rise is the pricer's own
/// fixed point, which is why it must not abort a mandatory walk.
const DUST_INVERSION_LOWER_TICK: u64 = 55_240;
const DUST_INVERSION_HIGHER_TICK: u64 = 55_250;
/// Shared upper boundary near scenario 0's forward, so both ranges price near 0.5.
const DUST_INVERSION_SHARED_TICK: u64 = 75_800;
const DUST_INVERSION_QUANTITY: u64 = 2_000_000_000;
/// SVI `b` of a shallow inverted surface (`rho = -1` at the default forward): its
/// UP price falls to a minimum near $81.707 and rises gently past it, so adjacent
/// $0.0001 strikes there differ by a raw unit or two.
const SHALLOW_INVERSION_B: u64 = 100_000_000;
const STAIR_TICK_SIZE: u64 = 100_000;
/// Four strikes past that minimum whose UP prices are consecutive integers
/// `p, p + 1, p + 2, p + 3`: the first and third rise by exactly the tolerance, the
/// first and last by one unit more, and all four form a staircase of one-unit
/// steps. They are fixture inputs tuned to the pricer. To re-derive them, walk
/// ascending $0.0001 ticks past the minimum and take the first tick at each of four
/// consecutive prices; every test asserts the differences it relies on before
/// walking, so drift fails loudly.
const STAIR_TICK_0: u64 = 817_236;
const STAIR_TICK_1: u64 = 817_241;
const STAIR_TICK_2: u64 = 817_243;
const STAIR_TICK_3: u64 = 817_246;
const STAIR_QUANTITY: u64 = 1_000_000;
const SNAPSHOT_SEQ: u64 = 1;
/// P-35's real short-dated slices (raw SVI, `rho` negative, spot set to the
/// forward), each carrying a one-raw-unit ripple between adjacent strikes. The
/// backfill slice was published 2026-03-19 07:06:40 for the 07:15 expiry.
const BACKFILL_FORWARD: u64 = 70_464_040_000_000;
const BACKFILL_SVI_A: u64 = 2_218;
const BACKFILL_SVI_B: u64 = 926_157;
const BACKFILL_SVI_SIGMA: u64 = 2_395_589;
const BACKFILL_SVI_RHO_MAGNITUDE: u64 = 28_390_040;
const BACKFILL_SVI_M: u64 = 68_038;
const BACKFILL_RIPPLE_LOWER_TICK: u64 = 72_670;
const BACKFILL_RIPPLE_HIGHER_TICK: u64 = 72_680;
/// The one-minute SSVI slice published 20 s before expiry.
const ONE_MINUTE_FORWARD: u64 = 66_415_250_000_000;
const ONE_MINUTE_SVI_A: u64 = 63;
const ONE_MINUTE_SVI_B: u64 = 185_973;
const ONE_MINUTE_SVI_SIGMA: u64 = 337_252;
const ONE_MINUTE_SVI_RHO_MAGNITUDE: u64 = 2_190_270;
const ONE_MINUTE_SVI_M: u64 = 739;
const ONE_MINUTE_RIPPLE_LOWER_TICK: u64 = 66_811;
const ONE_MINUTE_RIPPLE_HIGHER_TICK: u64 = 66_812;
const RIPPLE_QUANTITY: u64 = 2_000_000_000;
/// A butterfly-free surface (smallest Durrleman `g` 0.027) on which adjacent $0.01
/// strikes rise by exactly two raw units: rounding noise beyond the one-unit ripple,
/// which the tolerance's headroom admits. From RP-15's tolerance audit (`rho`
/// positive, `m` negative).
const TWO_UNIT_FORWARD: u64 = 131_066_329_593_242;
const TWO_UNIT_SVI_A: u64 = 27_519_073;
const TWO_UNIT_SVI_B: u64 = 507_873_048;
const TWO_UNIT_SVI_SIGMA: u64 = 106_067_390;
const TWO_UNIT_SVI_RHO_MAGNITUDE: u64 = 859_667_519;
const TWO_UNIT_SVI_M_MAGNITUDE: u64 = 178_490_722;
const CENT_TICK_SIZE: u64 = 10_000_000;
const TWO_UNIT_LOWER_TICK: u64 = 16_320_146;
const TWO_UNIT_HIGHER_TICK: u64 = 16_320_147;
const TWO_UNIT_RISE: u64 = 2;
/// A surface that is still butterfly-free but sits at the arbitrage edge (smallest
/// `g` 0.00026): adjacent $1 strikes rise by 502 raw units, so the walk fails closed
/// on it, which is RP-15's accepted residual. From the same audit (`rho` and `m`
/// negative).
const BUTTERFLY_EDGE_FORWARD: u64 = 170_742_326_426_584;
const BUTTERFLY_EDGE_SVI_A: u64 = 4_003;
const BUTTERFLY_EDGE_SVI_B: u64 = 2_375_780;
const BUTTERFLY_EDGE_SVI_SIGMA: u64 = 11_969;
const BUTTERFLY_EDGE_SVI_RHO_MAGNITUDE: u64 = 701_075_992;
const BUTTERFLY_EDGE_SVI_M_MAGNITUDE: u64 = 7_234;
const BUTTERFLY_EDGE_LOWER_TICK: u64 = 170_691;
const BUTTERFLY_EDGE_HIGHER_TICK: u64 = 170_692;
/// A whole multiple of 1e9, so every boundary product is exact and the walk's
/// divergence from the per-order sum is exactly the rise times it.
const SELF_INVERTED_QUANTITY: u64 = 2_000_000_000_000;

/// A cancelling boundary must still be PRICED, not just skipped in the arithmetic.
///
/// Regression for the boundary-skip bug: `walk_linear` once skipped pricing a node
/// whose start and end quantities cancel, which silently disarmed the monotonicity
/// guard for any inversion sitting on such a node. The construction below is the
/// one that distinguishes the two behaviours — the cancelling tick is the LAST
/// node (the second range is open-ended, so `pos_inf` is never stored), so there is
/// no later boundary whose own comparison would catch the inversion anyway.
/// Skipping the observation here lets NAV understate liability by the inverted
/// segment while the flush completes.
#[test, expected_failure(abort_code = strike_payout_tree::ENonMonotonePrice)]
fun inversion_on_a_cancelling_last_boundary_still_aborts() {
    let (mut fixture, oracle, pricer) = non_monotone_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    // A = (90, 100], B = (100, +inf], equal quantity: tick 100's start and end
    // cancel, and it is the only node after 90.
    tree.insert_range(CANCEL_LOWER_TICK, CANCEL_SHARED_TICK, CANCEL_QUANTITY);
    insert_up(&mut tree, CANCEL_SHARED_TICK, CANCEL_QUANTITY);

    tree.walk_linear(&pricer, tick_size());

    destroy(tree);
    cleanup(fixture, oracle);
}

#[test]
fun exact_walk_matches_per_order_reference() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    let (t0, t1, t2) = clustered_ticks();
    insert_up(&mut tree, t0, Q0);
    insert_up(&mut tree, t1, Q1);
    insert_up(&mut tree, t2, Q2);

    // The exact walk equals the independent per-order sum bit-for-bit: each
    // one-sided order is its own node, so there is no aggregation dust.
    let exact = walk_linear(&tree, &pricer);
    assert_eq!(exact, up_reference(&pricer, vector[t0, t1, t2], vector[Q0, Q1, Q2]));

    destroy(tree);
    cleanup(fixture, oracle);
}

#[test]
fun walk_linear_nets_same_total_regardless_of_insertion_order() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    let (t0, t1, t2) = clustered_ticks();
    insert_up(&mut tree, t2, Q2);
    insert_up(&mut tree, t0, Q0);
    insert_up(&mut tree, t1, Q1);
    // Insertion order is intentionally not sorted; the in-order walk must still
    // net the same total.
    let walk = tree.walk_linear(&pricer, tick_size());
    assert_eq!(walk, up_reference(&pricer, vector[t0, t1, t2], vector[Q0, Q1, Q2]));
    destroy(tree);
    cleanup(fixture, oracle);
}

#[test]
fun walk_linear_clamps_boundary_aggregation_dust() {
    let (mut fixture, oracle, pricer) = live_pricer_at(FLAT_REGION_FORWARD);
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    let t0 = test_constants::default_strike_tick();
    let lower_a = t0; // raw 100e9, up ~999_996_456
    let lower_b = t0 + 1; // raw 101e9, up ~999_995_893
    let higher = t0 + 2; // raw 102e9, up ~999_995_253, shared upper boundary

    // Two thin ITM ranges sharing the higher boundary, each one dust lot. In this
    // flat tail the end-side floor at the shared boundary aggregates 1 ulp above the
    // two start-side floors (199_999 vs 99_999+99_999), so the raw
    // base+start-end would underflow to -1 and abort. The clamp returns 0.
    tree.insert_range(lower_a, higher, DUST_QUANTITY);
    tree.insert_range(lower_b, higher, DUST_QUANTITY);

    // Independent per-order reference: both ranges' values round to 0, so true
    // linear liability is 0 — the clamped walk agrees (the floored dust was spurious).
    let reference =
        math::mul_down(pricer.range_price(raw(lower_a), raw(higher)).probability(), DUST_QUANTITY) +
        math::mul_down(pricer.range_price(raw(lower_b), raw(higher)).probability(), DUST_QUANTITY);
    assert_eq!(reference, 0);
    assert_eq!(walk_linear(&tree, &pricer), 0);

    destroy(tree);
    cleanup(fixture, oracle);
}

#[test]
fun gc_mutated_tree_walk_matches_rebuilt_survivor_tree() {
    let (mut fixture, oracle, pricer) = live_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    tree.insert_range(GC_SURVIVOR_A_LOWER, GC_SURVIVOR_A_HIGHER, GC_SURVIVOR_A_QUANTITY);
    tree.insert_range(GC_REMOVED_LOWER, GC_REMOVED_HIGHER, GC_REMOVED_QUANTITY);
    tree.insert_range(GC_SURVIVOR_C_LOWER, GC_SURVIVOR_C_HIGHER, GC_SURVIVOR_C_QUANTITY);

    // Removing the middle range deletes two interior boundary nodes through GC; the walk, settlement,
    // and rebuilt-tree assertions below prove those boundaries left no trace.
    tree.remove_range(GC_REMOVED_LOWER, GC_REMOVED_HIGHER, GC_REMOVED_QUANTITY);

    let mut rebuilt = strike_payout_tree::new(fixture.scenario_mut().ctx());
    rebuilt.insert_range(GC_SURVIVOR_A_LOWER, GC_SURVIVOR_A_HIGHER, GC_SURVIVOR_A_QUANTITY);
    rebuilt.insert_range(GC_SURVIVOR_C_LOWER, GC_SURVIVOR_C_HIGHER, GC_SURVIVOR_C_QUANTITY);

    let settlement_a_only = GC_SETTLEMENT_A_ONLY_TICK * tick_size();
    let settled_a_only = tree.settled_payout_liability(settlement_a_only, tick_size());
    assert_eq!(settled_a_only, rebuilt.settled_payout_liability(settlement_a_only, tick_size()));
    assert_eq!(settled_a_only, GC_SURVIVOR_A_QUANTITY);
    let settlement_overlap = GC_SETTLEMENT_OVERLAP_TICK * tick_size();
    let settled_overlap = tree.settled_payout_liability(settlement_overlap, tick_size());
    assert_eq!(settled_overlap, rebuilt.settled_payout_liability(settlement_overlap, tick_size()));
    assert_eq!(settled_overlap, GC_SURVIVOR_A_QUANTITY + GC_SURVIVOR_C_QUANTITY);
    let settlement_c_only = GC_SETTLEMENT_C_ONLY_TICK * tick_size();
    let settled_c_only = tree.settled_payout_liability(settlement_c_only, tick_size());
    assert_eq!(settled_c_only, rebuilt.settled_payout_liability(settlement_c_only, tick_size()));
    assert_eq!(settled_c_only, GC_SURVIVOR_C_QUANTITY);

    let mutated_walk = walk_linear(&tree, &pricer);
    let rebuilt_walk = walk_linear(&rebuilt, &pricer);
    let reference = range_reference(
        &pricer,
        vector[GC_SURVIVOR_A_LOWER, GC_SURVIVOR_C_LOWER],
        vector[GC_SURVIVOR_A_HIGHER, GC_SURVIVOR_C_HIGHER],
        vector[GC_SURVIVOR_A_QUANTITY, GC_SURVIVOR_C_QUANTITY],
    );
    assert_eq!(mutated_walk, rebuilt_walk);
    // The GC claim is the assertion above — the mutated tree and a tree that never
    // held the removed range walk identically. Against the per-order reference the
    // two survivors share no boundary, so each one floors its start and end
    // independently and contributes `floor(p_lo·q) - floor(p_hi·q) -
    // floor((p_lo - p_hi)·q) ∈ {0, 1}`: the bound is one raw unit per order that
    // truncates, so `GC_SURVIVOR_COUNT`, not one less. Survivor A happens to
    // contribute 0 today because its quantity is exactly `1e9`, which makes
    // `mul_down` the identity — do not tighten the bound to that coincidence, it is
    // the same class of accident as the bit-equality this replaced (that one held
    // only for the price low bits the old log-moneyness path produced). The gap is
    // protocol-favoured either way: R2, the walk is a liability and never
    // understates the per-order sum.
    assert!(mutated_walk >= reference);
    assert!(mutated_walk - reference <= GC_SURVIVOR_COUNT);

    destroy(tree);
    destroy(rebuilt);
    cleanup(fixture, oracle);
}

/// Two ordinary ranges whose lower boundaries straddle a one-unit fixed-point
/// inversion on a REAL committed surface walk to the per-order figure instead of
/// aborting. The prices are asserted to invert first, so the test drives the guard
/// rather than merely passing beside it; the rise is dust by the pricer's own
/// precision, which is what `price_monotonicity_tolerance` admits.
#[test]
fun a_fixed_point_dust_inversion_on_a_real_surface_is_walked_not_aborted() {
    let (mut fixture, oracle, pricer) = real_scenario_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    let lower_price = pricer.up_price(raw(DUST_INVERSION_LOWER_TICK));
    let higher_price = pricer.up_price(raw(DUST_INVERSION_HIGHER_TICK));
    assert!(higher_price > lower_price);
    assert!(higher_price - lower_price <= pricing::price_monotonicity_tolerance!());

    tree.insert_range(
        DUST_INVERSION_LOWER_TICK,
        DUST_INVERSION_SHARED_TICK,
        DUST_INVERSION_QUANTITY,
    );
    tree.insert_range(
        DUST_INVERSION_HIGHER_TICK,
        DUST_INVERSION_SHARED_TICK,
        DUST_INVERSION_QUANTITY,
    );

    // The netted aggregate still equals the independent per-order sum: the walk
    // prices the inverted boundary at its quote, so admitting the dust costs the
    // mark nothing.
    assert_eq!(
        walk_linear(&tree, &pricer),
        range_reference(
            &pricer,
            vector[DUST_INVERSION_LOWER_TICK, DUST_INVERSION_HIGHER_TICK],
            vector[DUST_INVERSION_SHARED_TICK, DUST_INVERSION_SHARED_TICK],
            vector[DUST_INVERSION_QUANTITY, DUST_INVERSION_QUANTITY],
        ),
    );

    destroy(tree);
    cleanup(fixture, oracle);
}

/// P-35's two real short-dated slices each carry a one-raw-unit ripple between
/// adjacent strikes on a valid surface; a book straddling either walks at the
/// independent per-order sum instead of aborting.
#[test]
fun a_ripple_on_a_short_dated_backfill_slice_is_walked() {
    let (fixture, oracle, pricer) = svi_pricer(
        BACKFILL_FORWARD,
        BACKFILL_SVI_A,
        BACKFILL_SVI_B,
        BACKFILL_SVI_SIGMA,
        BACKFILL_SVI_RHO_MAGNITUDE,
        true,
        BACKFILL_SVI_M,
        false,
    );
    assert_ripple_is_walked(
        fixture,
        oracle,
        &pricer,
        BACKFILL_RIPPLE_LOWER_TICK,
        BACKFILL_RIPPLE_HIGHER_TICK,
    );
}

#[test]
fun a_ripple_on_a_one_minute_ssvi_slice_is_walked() {
    let (fixture, oracle, pricer) = svi_pricer(
        ONE_MINUTE_FORWARD,
        ONE_MINUTE_SVI_A,
        ONE_MINUTE_SVI_B,
        ONE_MINUTE_SVI_SIGMA,
        ONE_MINUTE_SVI_RHO_MAGNITUDE,
        true,
        ONE_MINUTE_SVI_M,
        false,
    );
    assert_ripple_is_walked(
        fixture,
        oracle,
        &pricer,
        ONE_MINUTE_RIPPLE_LOWER_TICK,
        ONE_MINUTE_RIPPLE_HIGHER_TICK,
    );
}

/// Headroom above the one-unit ripple: on a butterfly-free surface where adjacent
/// $0.01 strikes rise by exactly two raw units, the book walks at the per-order
/// sum. A tolerance of one would abort it.
#[test]
fun a_two_unit_rise_on_a_valid_surface_is_walked() {
    let (mut fixture, oracle, pricer) = svi_pricer(
        TWO_UNIT_FORWARD,
        TWO_UNIT_SVI_A,
        TWO_UNIT_SVI_B,
        TWO_UNIT_SVI_SIGMA,
        TWO_UNIT_SVI_RHO_MAGNITUDE,
        false,
        TWO_UNIT_SVI_M_MAGNITUDE,
        true,
    );
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    let lower_price = pricer.up_price(
        range_codec::strike_from_tick(TWO_UNIT_LOWER_TICK, CENT_TICK_SIZE),
    );
    let higher_price = pricer.up_price(
        range_codec::strike_from_tick(TWO_UNIT_HIGHER_TICK, CENT_TICK_SIZE),
    );
    assert_eq!(higher_price - lower_price, TWO_UNIT_RISE);
    assert!(TWO_UNIT_RISE <= pricing::price_monotonicity_tolerance!());

    insert_up(&mut tree, TWO_UNIT_LOWER_TICK, RIPPLE_QUANTITY);
    insert_up(&mut tree, TWO_UNIT_HIGHER_TICK, RIPPLE_QUANTITY);
    assert_eq!(
        tree.walk_linear(&pricer, CENT_TICK_SIZE),
        math::mul_down(lower_price, RIPPLE_QUANTITY) + math::mul_down(higher_price, RIPPLE_QUANTITY),
    );

    destroy(tree);
    cleanup(fixture, oracle);
}

/// RP-15's accepted residual: a surface that is butterfly-free but at the
/// arbitrage edge rises by far more than the tolerance between adjacent $1 strikes,
/// because the true slope there no longer outruns the pricer's rounding, and the
/// walk fails closed on it.
#[test, expected_failure(abort_code = strike_payout_tree::ENonMonotonePrice)]
fun a_valid_surface_at_the_butterfly_edge_fails_closed() {
    let (mut fixture, oracle, pricer) = svi_pricer(
        BUTTERFLY_EDGE_FORWARD,
        BUTTERFLY_EDGE_SVI_A,
        BUTTERFLY_EDGE_SVI_B,
        BUTTERFLY_EDGE_SVI_SIGMA,
        BUTTERFLY_EDGE_SVI_RHO_MAGNITUDE,
        true,
        BUTTERFLY_EDGE_SVI_M_MAGNITUDE,
        true,
    );
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    let lower_price = pricer.up_price(raw(BUTTERFLY_EDGE_LOWER_TICK));
    let higher_price = pricer.up_price(raw(BUTTERFLY_EDGE_HIGHER_TICK));
    assert!(higher_price - lower_price > pricing::price_monotonicity_tolerance!());

    insert_up(&mut tree, BUTTERFLY_EDGE_LOWER_TICK, RIPPLE_QUANTITY);
    insert_up(&mut tree, BUTTERFLY_EDGE_HIGHER_TICK, RIPPLE_QUANTITY);
    tree.walk_linear(&pricer, tick_size());

    destroy(tree);
    cleanup(fixture, oracle);
}

/// The sign and size of the walk's one divergence from the per-order sum: when an
/// order's own two boundaries invert, its per-order value floors at zero while the
/// netted walk lets the pair cancel, so the walk understates liability (NAV reads
/// high) by exactly the rise times that order's quantity.
#[test]
fun a_self_inverted_order_understates_liability_by_its_rise() {
    let (mut fixture, oracle, pricer) = real_scenario_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    let lower_price = pricer.up_price(raw(DUST_INVERSION_LOWER_TICK));
    let higher_price = pricer.up_price(raw(DUST_INVERSION_HIGHER_TICK));
    assert!(higher_price > lower_price);

    // The first order spans the inverted pair itself; the second continues from its
    // top boundary, so that boundary's start and end cancel.
    tree.insert_range(
        DUST_INVERSION_LOWER_TICK,
        DUST_INVERSION_HIGHER_TICK,
        SELF_INVERTED_QUANTITY,
    );
    tree.insert_range(
        DUST_INVERSION_HIGHER_TICK,
        DUST_INVERSION_SHARED_TICK,
        SELF_INVERTED_QUANTITY,
    );

    let reference = range_reference(
        &pricer,
        vector[DUST_INVERSION_LOWER_TICK, DUST_INVERSION_HIGHER_TICK],
        vector[DUST_INVERSION_HIGHER_TICK, DUST_INVERSION_SHARED_TICK],
        vector[SELF_INVERTED_QUANTITY, SELF_INVERTED_QUANTITY],
    );
    assert_eq!(
        reference - walk_linear(&tree, &pricer),
        math::mul_down(higher_price - lower_price, SELF_INVERTED_QUANTITY),
    );

    destroy(tree);
    cleanup(fixture, oracle);
}

/// A rise of exactly the tolerance prices through at the quoted boundary prices:
/// the netted walk equals the independent per-order sum. With the test below it
/// pins the bound to the unit, including that the comparison is `<=`.
#[test]
fun a_rise_of_exactly_the_tolerance_is_walked_at_its_quoted_prices() {
    let (mut fixture, oracle, pricer) = shallow_inversion_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    let lower_price = stair_up_price(&pricer, STAIR_TICK_0);
    let higher_price = stair_up_price(&pricer, STAIR_TICK_2);
    assert_eq!(higher_price - lower_price, pricing::price_monotonicity_tolerance!());

    // Open-topped ranges store only their lower boundary, so the walk compares
    // exactly these two prices.
    insert_up(&mut tree, STAIR_TICK_0, STAIR_QUANTITY);
    insert_up(&mut tree, STAIR_TICK_2, STAIR_QUANTITY);

    assert_eq!(
        tree.walk_linear(&pricer, STAIR_TICK_SIZE),
        math::mul_down(lower_price, STAIR_QUANTITY) + math::mul_down(higher_price, STAIR_QUANTITY),
    );

    destroy(tree);
    cleanup(fixture, oracle);
}

#[test, expected_failure(abort_code = strike_payout_tree::ENonMonotonePrice)]
fun a_rise_one_unit_past_the_tolerance_aborts() {
    let (mut fixture, oracle, pricer) = shallow_inversion_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    let lower_price = stair_up_price(&pricer, STAIR_TICK_0);
    let higher_price = stair_up_price(&pricer, STAIR_TICK_3);
    assert_eq!(higher_price - lower_price, pricing::price_monotonicity_tolerance!() + 1);

    insert_up(&mut tree, STAIR_TICK_0, STAIR_QUANTITY);
    insert_up(&mut tree, STAIR_TICK_3, STAIR_QUANTITY);
    tree.walk_linear(&pricer, STAIR_TICK_SIZE);

    destroy(tree);
    cleanup(fixture, oracle);
}

/// The walk compares each price with the running minimum, not the previous
/// boundary: a staircase whose every step is inside the tolerance still aborts
/// once its total rise passes it, so dust cannot ratchet underneath the bound.
#[test, expected_failure(abort_code = strike_payout_tree::ENonMonotonePrice)]
fun a_staircase_of_tolerable_rises_aborts_past_the_tolerance() {
    let (mut fixture, oracle, pricer) = shallow_inversion_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());
    let ticks = vector[STAIR_TICK_0, STAIR_TICK_1, STAIR_TICK_2, STAIR_TICK_3];

    let first_price = stair_up_price(&pricer, STAIR_TICK_0);
    let mut previous_price = first_price;
    ticks.do_ref!(|tick| {
        let price = stair_up_price(&pricer, *tick);
        assert!(price - previous_price <= pricing::price_monotonicity_tolerance!());
        previous_price = price;
    });
    assert!(previous_price - first_price > pricing::price_monotonicity_tolerance!());

    ticks.do_ref!(|tick| insert_up(&mut tree, *tick, STAIR_QUANTITY));
    tree.walk_linear(&pricer, STAIR_TICK_SIZE);

    destroy(tree);
    cleanup(fixture, oracle);
}

/// The frozen walk keeps one running minimum across its whole snapshot view,
/// whether it reads a node's snapshot copy (a husk emptied after the snapshot) or
/// its untouched live terms. Closing the staircase's two end orders after the
/// snapshot leaves a live view whose interior rise is inside the tolerance, while
/// the frozen view still spans the full staircase and aborts.
#[test, expected_failure(abort_code = strike_payout_tree::ENonMonotonePrice)]
fun the_frozen_walk_keeps_one_running_minimum_across_husks() {
    let (mut fixture, oracle, pricer) = shallow_inversion_pricer();
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    vector[STAIR_TICK_0, STAIR_TICK_1, STAIR_TICK_2, STAIR_TICK_3].do!(|tick| {
        insert_up(&mut tree, tick, STAIR_QUANTITY);
    });
    tree.activate_snapshot(SNAPSHOT_SEQ);
    tree.remove_range(STAIR_TICK_0, constants::pos_inf_tick!(), STAIR_QUANTITY);
    tree.remove_range(STAIR_TICK_3, constants::pos_inf_tick!(), STAIR_QUANTITY);

    // The live view is the interior, which walks at the independent per-order sum.
    let interior_lower_price = stair_up_price(&pricer, STAIR_TICK_1);
    let interior_higher_price = stair_up_price(&pricer, STAIR_TICK_2);
    assert!(
        interior_higher_price - interior_lower_price <= pricing::price_monotonicity_tolerance!(),
    );
    assert_eq!(
        tree.walk_linear(&pricer, STAIR_TICK_SIZE),
        math::mul_down(interior_lower_price, STAIR_QUANTITY)
            + math::mul_down(interior_higher_price, STAIR_QUANTITY),
    );

    // The frozen view still holds both ends, whose rise is past the tolerance.
    let first_price = stair_up_price(&pricer, STAIR_TICK_0);
    let last_price = stair_up_price(&pricer, STAIR_TICK_3);
    assert!(last_price - first_price > pricing::price_monotonicity_tolerance!());
    tree.walk_linear_frozen(&pricer, STAIR_TICK_SIZE, SNAPSHOT_SEQ);

    destroy(tree);
    cleanup(fixture, oracle);
}

// === Helpers ===

/// The walk's `tick_size`: the default (1e9), so tick `t` maps to raw strike
/// `t * 1e9`.
fun tick_size(): u64 { test_constants::default_tick_size() }

/// Strike for a tick under the default `tick_size` (tick 0 and `pos_inf_tick`
/// map to the open-ended sentinels).
fun raw(tick: u64): Strike { range_codec::strike_from_tick(tick, tick_size()) }

/// UP price at `tick` on the staircase's $0.0001 grid.
fun stair_up_price(pricer: &Pricer, tick: u64): u64 {
    pricer.up_price(range_codec::strike_from_tick(tick, STAIR_TICK_SIZE))
}

/// Walk two open-topped ranges whose lower boundaries straddle a ripple, after
/// asserting that the prices really rise, and require the per-order sum.
fun assert_ripple_is_walked(
    mut fixture: OracleFixture,
    oracle: OracleBundle,
    pricer: &Pricer,
    lower_tick: u64,
    higher_tick: u64,
) {
    let mut tree = strike_payout_tree::new(fixture.scenario_mut().ctx());

    let lower_price = pricer.up_price(raw(lower_tick));
    let higher_price = pricer.up_price(raw(higher_tick));
    assert!(higher_price > lower_price);
    assert!(higher_price - lower_price <= pricing::price_monotonicity_tolerance!());

    insert_up(&mut tree, lower_tick, RIPPLE_QUANTITY);
    insert_up(&mut tree, higher_tick, RIPPLE_QUANTITY);
    assert_eq!(
        walk_linear(&tree, pricer),
        up_reference(
            pricer,
            vector[lower_tick, higher_tick],
            vector[RIPPLE_QUANTITY, RIPPLE_QUANTITY],
        ),
    );

    destroy(tree);
    cleanup(fixture, oracle);
}

/// Run the exact linear walk.
fun walk_linear(tree: &StrikePayoutTree, pricer: &Pricer): u64 {
    tree.walk_linear(pricer, tick_size())
}

/// Three adjacent finite ticks around the canonical finite strike (100, 101, 102).
fun clustered_ticks(): (u64, u64, u64) {
    let t0 = test_constants::default_strike_tick();
    (t0, t0 + 1, t0 + 2)
}

/// Insert a one-sided up range `(tick, pos_inf]` carrying `quantity`;
/// `walk_linear` reads only the quantity.
fun insert_up(tree: &mut StrikePayoutTree, tick: u64, quantity: u64) {
    tree.insert_range(tick, constants::pos_inf_tick!(), quantity);
}

/// Independent linear reference: `Σ mul(range_price(tick·ts, +inf), quantity)`.
/// Uses `range_price` (a different pricer path than the walk's `up_price`).
fun up_reference(pricer: &Pricer, ticks: vector<u64>, quantities: vector<u64>): u64 {
    let mut total = 0;
    ticks.length().do!(|i| {
        total =
            total + math::mul_down(
                pricer.range_price(raw(ticks[i]), raw(constants::pos_inf_tick!())).probability(),
                quantities[i],
            );
    });
    total
}

/// Independent finite-range reference: `Σ mul(range_price(lower·ts, higher·ts), quantity)`.
/// Uses `range_price` (a different pricer path than the walk's `up_price`).
fun range_reference(
    pricer: &Pricer,
    lower_ticks: vector<u64>,
    higher_ticks: vector<u64>,
    quantities: vector<u64>,
): u64 {
    let mut total = 0;
    lower_ticks.length().do!(|i| {
        let range_price = pricer
            .range_price(raw(lower_ticks[i]), raw(higher_ticks[i]))
            .probability();
        total = total + math::mul_down(range_price, quantities[i]);
    });
    total
}

/// A live market at the default ATM forward with an inflated base variance so
/// adjacent strikes are clustered in price, plus a `Pricer` snapshot over it.
fun live_pricer(): (OracleFixture, OracleBundle, Pricer) {
    live_pricer_at(test_constants::default_live_price())
}

/// `live_pricer` with an explicit forward (used to reach the deep-ITM flat tail).
fun live_pricer_at(forward: u64): (OracleFixture, OracleBundle, Pricer) {
    let mut fixture = oracle_fixture::setup_oracle_default();
    let mut oracle = fixture.take_oracle_bundle();
    // Inflated base variance, otherwise the default (positive) SVI shape; spot ==
    // forward gives basis 1.0. sigma == default_svi_sigma (1e-3).
    fixture.prepare_real_oracle_bundle(
        &mut oracle,
        forward,
        forward,
        HIGH_VARIANCE_A,
        false,
        test_constants::default_svi_b(),
        test_constants::default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        test_constants::default_svi_m(),
        false,
    );
    let pricer = fixture.load_pricer_bundle(&oracle);
    (fixture, oracle, pricer)
}

/// A surface whose UP price RISES with strike over the active ticks — impossible
/// for a valid curve, and what `ENonMonotonePrice` exists to reject. Same extreme
/// SVI parametrisation the deleted price-memo guard test used: tiny positive `a`,
/// max `b`, min `sigma`, `rho = -1`.
fun non_monotone_pricer(): (OracleFixture, OracleBundle, Pricer) {
    let mut fixture = oracle_fixture::setup_oracle_default();
    let mut oracle = fixture.take_oracle_bundle();
    fixture.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        1,
        false,
        test_constants::pricing_max_svi_input(),
        test_constants::pricing_min_svi_sigma(),
        test_constants::float(),
        true,
        0,
        false,
    );
    let pricer = fixture.load_pricer_bundle(&oracle);
    (fixture, oracle, pricer)
}

/// The shallow inverted surface the tolerance-edge tests walk: the extreme
/// parametrisation above with `b` reduced so the rise past its minimum is gentle.
fun shallow_inversion_pricer(): (OracleFixture, OracleBundle, Pricer) {
    let mut fixture = oracle_fixture::setup_oracle_default();
    let mut oracle = fixture.take_oracle_bundle();
    fixture.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        1,
        false,
        SHALLOW_INVERSION_B,
        test_constants::pricing_min_svi_sigma(),
        test_constants::float(),
        true,
        0,
        false,
    );
    let pricer = fixture.load_pricer_bundle(&oracle);
    (fixture, oracle, pricer)
}

/// A real SVI surface at `forward` (spot set to the forward) with positive `a` and
/// the given signs for `rho` and `m`.
fun svi_pricer(
    forward: u64,
    svi_a: u64,
    svi_b: u64,
    svi_sigma: u64,
    svi_rho_magnitude: u64,
    svi_rho_is_negative: bool,
    svi_m_magnitude: u64,
    svi_m_is_negative: bool,
): (OracleFixture, OracleBundle, Pricer) {
    let mut fixture = oracle_fixture::setup_oracle(
        forward,
        test_constants::default_tick_size(),
        test_constants::default_expiry_ms(),
    );
    let mut oracle = fixture.take_oracle_bundle();
    fixture.prepare_real_oracle_bundle(
        &mut oracle,
        forward,
        forward,
        svi_a,
        false,
        svi_b,
        svi_sigma,
        svi_rho_magnitude,
        svi_rho_is_negative,
        svi_m_magnitude,
        svi_m_is_negative,
    );
    let pricer = fixture.load_pricer_bundle(&oracle);
    (fixture, oracle, pricer)
}

/// A pricer carrying committed real scenario 0 — a provider-valid, butterfly-free
/// surface, unlike `non_monotone_pricer`'s synthetic one.
fun real_scenario_pricer(): (OracleFixture, OracleBundle, Pricer) {
    let mut fixture = oracle_fixture::setup_oracle(
        ref_data::creation_spot(0),
        ref_data::tick_size(0),
        test_constants::default_expiry_ms(),
    );
    let mut oracle = fixture.take_oracle_bundle();
    fixture.prepare_real_oracle_bundle(
        &mut oracle,
        ref_data::spot(0),
        ref_data::forward(0),
        ref_data::svi_a(0),
        false,
        ref_data::svi_b(0),
        ref_data::svi_sigma(0),
        ref_data::svi_rho_magnitude(0),
        ref_data::svi_rho_is_negative(0),
        ref_data::svi_m_magnitude(0),
        ref_data::svi_m_is_negative(0),
    );
    let pricer = fixture.load_pricer_bundle(&oracle);
    (fixture, oracle, pricer)
}

fun cleanup(fixture: OracleFixture, oracle: OracleBundle) {
    oracle_fixture::return_oracle_bundle(oracle);
    fixture.finish();
}
