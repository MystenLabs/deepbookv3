// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Tick-time pricing for delayed execution: `pricing::pricer_at`, the non-aborting
/// `try_up_price` / `try_range`, and the committed-spot bound `safe_spot`.
///
/// `pricer_at` must rebuild exactly the Pricer the live load builds from the same
/// inputs, re-anchor the snapshot basis on the committed spot, roll the SVI down to the
/// tick (pinned against `tick_pricing_reference_data`, generated independently by
/// `generate_pricing_reference.py --tick-only`), and return `none` rather than abort at
/// or past expiry, on a zero forward, and on a rolled surface with no positive variance.
///
/// The `try_*` reads must return the aborting reads' bits wherever those price, and
/// `none` wherever they abort. The aborting counterparts on the same surfaces are
/// pinned in `pricing_guard_tests` (`re_anchored_zero_forward_aborts`,
/// `boundary_loaded_surface_with_nonpositive_per_strike_variance_aborts`,
/// `live_quote_with_equal_range_bounds_aborts`); the range-path aborts below pin that
/// `range_price` still raises the digital's own code. `ECannotBeNegative` is a
/// backstop no input reaches (see `pricing_guard_tests`), so its `none` has no test.
#[test_only]
module deepbook_predict::tick_pricing_tests;

use deepbook_predict::{
    constants,
    oracle_fixture::{Self, OracleBundle, OracleFixture},
    pricing::{Self, Pricer, VolSnapshot},
    pricing_reference_data as ref_data,
    range_codec::strike_for_testing as strike,
    test_constants,
    test_helpers,
    tick_pricing_reference_data as tick_ref,
    vol_snapshot_test_helpers::{Self as helpers, load_snapshot}
};
use fixed_math::{i64, math::float_scaling as float};
use std::unit_test::assert_eq;

const EUnexpectedSuccess: u64 = 999;

// === Live-equivalence fixture ===

/// Block Scholes forward at basis 1.005 over the default 100e9 spot.
const BASIS_BS_FORWARD: u64 = 100_500_000_000;
/// Fresh Pyth prints diverged from the Block Scholes spot, so the forward is
/// genuinely re-anchored. Sources are strictly newer than the 119_000 bootstrap.
const FIRST_PYTH_SPOT: u64 = 102_000_000_000;
const FIRST_PYTH_SOURCE_MS: u64 = 119_500;
const SECOND_PYTH_SPOT: u64 = 103_000_000_000;
/// One second after the snapshot: Block Scholes prices sourced at 119_000 are exactly
/// 2_000 ms old (the inclusive window), and the SVI sourced at 120_000 is 1 s old.
const LATER_MS: u64 = 121_000;

// === Hand-checked re-anchoring ===

/// `100e9 * 2e9 / 3e9 = 66_666_666_666.67`, floored.
const REANCHOR_SPOT: u64 = 100_000_000_000;
const REANCHOR_BS_SPOT: u64 = 3_000_000_000;
const REANCHOR_BS_FORWARD: u64 = 2_000_000_000;
const REANCHORED_FORWARD: u64 = 66_666_666_666;
/// A basis-one snapshot prices exactly on the spot it is given.
const UNIT_BASIS_PRICE: u64 = 1_000_000_000;
const SNAPSHOT_SOURCE_MS: u64 = 119_000;
const GENERATION_MS: u64 = 119_950;
const TICK_MS: u64 = 120_000;

// === None cases ===

/// Basis 0.99: a committed spot of 1 re-anchors to `floor(0.99) = 0`, a spot of 2 to
/// `floor(1.98) = 1`.
const SUB_UNIT_BS_FORWARD: u64 = 99_000_000_000;
const ZERO_SPOT: u64 = 0;
const ZERO_FORWARD_SPOT: u64 = 1;
const UNIT_FORWARD_SPOT: u64 = 2;
/// Raw `a = 1e-9`, `b = 0`, sourced at the 120_000 fixture clock against the default
/// expiry 31_536_120_000, so the roll-down anchor is 31_536_000_000 ms. At 31 ms to
/// expiry the rolled `a` is `floor(1 * 1e9 * 31 / 31_536_000_000) = floor(0.983) = 0`
/// at 1e18 and the surface has no variance; at 32 ms it is `floor(1.0147) = 1`.
const FLAT_SVI_A: u64 = 1;
const FLAT_SVI_B: u64 = 0;
const ZERO_SHAPE_PARAM: u64 = 0;
const NO_VARIANCE_REMAINING_MS: u64 = 31;
const ONE_UNIT_VARIANCE_REMAINING_MS: u64 = 32;
/// With `w = 1e-18` and `b = 0`, the at-the-forward digital is `Phi(-sqrt(w)/2) =
/// Phi(-5e-10) = 0.4999999998`, i.e. 500_000_000 at 1e9.
const ONE_UNIT_VARIANCE_ATM_UP: u64 = 500_000_000;

// === try_* surfaces ===

/// Mirrors `pricing_guard_tests::re_anchored_zero_forward_aborts`: no lower basis
/// bound, so a Pyth spot far below the Block Scholes spot re-anchors to
/// `1e9 * 1 / 1e17 = 0`.
const ZERO_FORWARD_BS_SPOT: u64 = 100_000_000_000_000_000;
const ZERO_FORWARD_BS_FORWARD: u64 = 1;
const ZERO_FORWARD_PYTH_SPOT: u64 = 1_000_000_000;
/// Mirrors `pricing_guard_tests`' per-strike non-positive surface: its rounded
/// analytical minimum variance is one raw unit, so it loads, but at the forward strike
/// the floored smile root takes that unit back and total variance rounds to zero.
const PER_STRIKE_NONPOSITIVE_A_MAG: u64 = 2_904_653;
const PER_STRIKE_NONPOSITIVE_B: u64 = 1_000_000_000;
const PER_STRIKE_NONPOSITIVE_SIGMA: u64 = 3_315_343;
const PER_STRIKE_NONPOSITIVE_RHO: u64 = 482_084_487;
const PER_STRIKE_NONPOSITIVE_M: u64 = 1_824_257;
/// Twice the forward, where `k = ln 2` keeps the variance well positive.
const DOUBLE_FORWARD_STRIKE: u64 = 200_000_000_000;
/// Strikes around the 102.51e9 tick-reference forward.
const STRIKE_BELOW: u64 = 101_000_000_000;
const STRIKE_ABOVE: u64 = 104_000_000_000;

// === safe_spot (hand-derived) ===

/// `u64::MAX / 100`, Predict's pricing-safe spot ceiling.
const MAX_PRICING_SPOT: u64 = 184_467_440_737_095_516;

// === pricer_at matches the live pricer ===

/// The Pricer rebuilt from a snapshot is bit-identical to the live pricer loaded from
/// the same oracle state: at the snapshot instant, and one second later after a new
/// Pyth print (the snapshot's Block Scholes rows and SVI are unchanged, so only the
/// committed spot and the roll-down time move).
#[test]
fun pricer_at_matches_the_live_pricer_at_the_same_inputs() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    prepare_default_surface(&mut fx, &mut oracle, BASIS_BS_FORWARD);
    fx.set_pyth_bundle(&mut oracle, FIRST_PYTH_SPOT, FIRST_PYTH_SOURCE_MS);

    let (snapshot, t0_pricer) = load_snapshot(
        &mut fx,
        &oracle,
        helpers::default_svi_max_age_ms(),
    );
    let live = fx.load_pricer_bundle(&oracle);
    assert_eq!(t0_pricer, live);
    assert_eq!(
        pricer_at_or_abort(&fx, &snapshot, FIRST_PYTH_SPOT, FIRST_PYTH_SOURCE_MS, TICK_MS),
        live,
    );

    fx.set_clock_for_testing(LATER_MS);
    fx.set_pyth_bundle(&mut oracle, SECOND_PYTH_SPOT, LATER_MS);
    let later_live = fx.load_pricer_bundle(&oracle);
    assert_eq!(
        pricer_at_or_abort(&fx, &snapshot, SECOND_PYTH_SPOT, LATER_MS, LATER_MS),
        later_live,
    );

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// `forward = floor(spot * bs_forward / bs_spot)`. A basis-one snapshot prices exactly
/// on the spot it is given, so the re-anchored Pricer must equal the basis-one Pricer
/// at the hand-computed 66_666_666_666, and not at the next unit up.
#[test]
fun pricer_at_reanchors_the_snapshot_basis_on_the_committed_spot() {
    let id = object::id_from_address(@0x1);
    let expiry = test_constants::default_expiry_ms();
    let basis = default_surface_snapshot(REANCHOR_BS_SPOT, REANCHOR_BS_FORWARD);
    let unit = default_surface_snapshot(UNIT_BASIS_PRICE, UNIT_BASIS_PRICE);

    let reanchored = pricing::pricer_at(&basis, REANCHOR_SPOT, GENERATION_MS, TICK_MS, id, expiry);
    let expected = pricing::pricer_at(
        &unit,
        REANCHORED_FORWARD,
        GENERATION_MS,
        TICK_MS,
        id,
        expiry,
    );
    let one_up = pricing::pricer_at(
        &unit,
        REANCHORED_FORWARD + 1,
        GENERATION_MS,
        TICK_MS,
        id,
        expiry,
    );

    assert!(reanchored.is_some());
    assert_eq!(reanchored, expected);
    assert!(reanchored != one_up);
}

// === pricer_at against the independent reference ===

/// At each reference tick, the Pricer rebuilt on the committed 102e9 spot prices the
/// at-the-forward digital of the surface rolled down to that tick. The four ticks span
/// roll-down ratios 1 to 1/120 and their references sit hundreds of thousands of units
/// apart, so a missing or mistimed roll-down, or a forward re-anchored on the wrong
/// spot, misses every band.
#[test]
fun pricer_at_prices_the_surface_rolled_down_to_the_tick() {
    let (mut fx, oracle) = setup_tick_reference();
    let (snapshot, _) = load_snapshot(&mut fx, &oracle, helpers::default_svi_max_age_ms());
    assert_eq!(snapshot.svi_source_timestamp_ms(), tick_ref::svi_source_timestamp_ms());

    tick_ref::points().do!(|point| {
        let pricer = pricer_at_or_abort(
            &fx,
            &snapshot,
            tick_ref::committed_spot(),
            point.priced_at_ms(),
            point.priced_at_ms(),
        );
        test_helpers::assert_within(
            pricer.up_price(strike(tick_ref::forward())),
            point.reference(),
            point.tolerance(),
        );
    });

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// The rebuilt Pricer reports the committed update's generation time as its Pyth
/// timestamp and the snapshot's own Block Scholes and SVI timestamps, so trade events
/// report exactly what was priced.
#[test]
fun pricer_at_reports_the_generation_and_snapshot_timestamps() {
    let (mut fx, oracle) = setup_tick_reference();
    let (snapshot, _) = load_snapshot(&mut fx, &oracle, helpers::default_svi_max_age_ms());

    let pricer = pricer_at_or_abort(
        &fx,
        &snapshot,
        tick_ref::committed_spot(),
        GENERATION_MS,
        TICK_MS,
    );

    assert_eq!(pricer.expiry_market_id(), fx.expiry_id());
    assert_eq!(pricer.pyth_ts(), GENERATION_MS);
    assert_eq!(
        pricer.bs_spot_ts(),
        test_constants::live_source_timestamp_ms(),
    );
    assert_eq!(
        pricer.bs_fwd_ts(),
        test_constants::live_source_timestamp_ms(),
    );
    assert_eq!(pricer.bs_svi_ts(), tick_ref::svi_source_timestamp_ms());

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

// === pricer_at none cases ===

#[test]
fun pricer_at_is_none_at_and_after_expiry() {
    let (mut fx, oracle) = setup_tick_reference();
    let (snapshot, _) = load_snapshot(&mut fx, &oracle, helpers::default_svi_max_age_ms());
    let expiry = fx.expiry();

    assert!(pricer_at_tick(&fx, &snapshot, tick_ref::committed_spot(), expiry - 1).is_some());
    assert!(pricer_at_tick(&fx, &snapshot, tick_ref::committed_spot(), expiry).is_none());
    assert!(pricer_at_tick(&fx, &snapshot, tick_ref::committed_spot(), expiry + 1).is_none());

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

#[test]
fun pricer_at_is_none_on_a_zero_forward() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    prepare_default_surface(&mut fx, &mut oracle, SUB_UNIT_BS_FORWARD);
    let (snapshot, _) = load_snapshot(&mut fx, &oracle, helpers::default_svi_max_age_ms());

    assert!(pricer_at_tick(&fx, &snapshot, ZERO_SPOT, TICK_MS).is_none());
    assert!(pricer_at_tick(&fx, &snapshot, ZERO_FORWARD_SPOT, TICK_MS).is_none());
    assert!(pricer_at_tick(&fx, &snapshot, UNIT_FORWARD_SPOT, TICK_MS).is_some());

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// A valid snapshot priced at a tick so close to expiry that the rolled `a` floors to
/// zero has no variance anywhere, so `pricer_at` returns none instead of a Pricer every
/// quote would abort on; one millisecond earlier it keeps one raw unit and prices.
#[test]
fun pricer_at_is_none_once_the_rolled_variance_floors_to_zero() {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        FLAT_SVI_A,
        false,
        FLAT_SVI_B,
        test_constants::default_svi_sigma(),
        ZERO_SHAPE_PARAM,
        false,
        ZERO_SHAPE_PARAM,
        false,
    );
    let (snapshot, _) = load_snapshot(&mut fx, &oracle, helpers::default_svi_max_age_ms());
    let expiry = fx.expiry();
    let spot = test_constants::default_live_price();

    assert!(pricer_at_tick(&fx, &snapshot, spot, expiry - NO_VARIANCE_REMAINING_MS).is_none());
    let pricer = pricer_at_tick(&fx, &snapshot, spot, expiry - ONE_UNIT_VARIANCE_REMAINING_MS);
    test_helpers::assert_within(
        pricer.destroy_some().up_price(strike(spot)),
        ONE_UNIT_VARIANCE_ATM_UP,
        ref_data::flat_surface_atm_budget(),
    );

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

// === try_* reads ===

/// Wherever the aborting reads price, the `try_*` reads return the same bits: every
/// strike shape and every range shape, on the tick-reference surface (live skew) at a
/// rolled tick.
#[test]
fun try_reads_match_the_aborting_reads_where_those_price() {
    let (mut fx, oracle) = setup_tick_reference();
    let (snapshot, _) = load_snapshot(&mut fx, &oracle, helpers::default_svi_max_age_ms());
    let pricer = pricer_at_or_abort(
        &fx,
        &snapshot,
        tick_ref::committed_spot(),
        GENERATION_MS,
        LATER_MS,
    );

    let strikes = vector[
        strike(constants::neg_inf!()),
        strike(STRIKE_BELOW),
        strike(tick_ref::forward()),
        strike(STRIKE_ABOVE),
        strike(constants::pos_inf!()),
    ];
    strikes.do_ref!(|s| assert_eq!(pricer.try_up_price(*s), option::some(pricer.up_price(*s))));
    let ranges = vector[
        vector[strike(constants::neg_inf!()), strike(STRIKE_BELOW)],
        vector[strike(STRIKE_BELOW), strike(STRIKE_ABOVE)],
        vector[strike(STRIKE_ABOVE), strike(constants::pos_inf!())],
        vector[strike(constants::neg_inf!()), strike(constants::pos_inf!())],
    ];
    ranges.do_ref!(|r| {
        assert_eq!(
            pricer.try_range(r[0], r[1]),
            option::some(pricer.range_price(r[0], r[1])),
        );
    });

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// On a zero forward every finite strike is unpriceable: `none` where `up_price`
/// aborts `EZeroForward`. The infinite sentinels never read the surface, so they still
/// price, and so does the whole line.
#[test]
fun try_reads_are_none_on_a_zero_forward() {
    let (mut fx, oracle) = setup_zero_forward();
    let pricer = fx.load_pricer_bundle(&oracle);
    let finite = strike(test_constants::default_live_price());
    let neg_inf = strike(constants::neg_inf!());
    let pos_inf = strike(constants::pos_inf!());

    assert!(pricer.try_up_price(finite).is_none());
    assert_eq!(pricer.try_up_price(neg_inf), option::some(float!()));
    assert_eq!(pricer.try_up_price(pos_inf), option::some(0));
    assert!(pricer.try_range(finite, pos_inf).is_none());
    assert!(pricer.try_range(neg_inf, finite).is_none());
    let whole_line = pricer.try_range(neg_inf, pos_inf);
    assert_eq!(whole_line.destroy_some().probability(), float!());

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// Where total variance rounds to zero (`ENonPositiveVariance`), the strike and every
/// range touching it are `none`; a strike where the variance is positive still prices
/// with the aborting read's bits.
#[test]
fun try_reads_are_none_where_the_variance_rounds_to_zero() {
    let (mut fx, oracle) = setup_per_strike_nonpositive();
    let pricer = fx.load_pricer_bundle(&oracle);
    let at_forward = strike(test_constants::default_live_price());
    let double_forward = strike(DOUBLE_FORWARD_STRIKE);

    assert!(pricer.try_up_price(at_forward).is_none());
    assert!(pricer.try_range(at_forward, strike(constants::pos_inf!())).is_none());
    assert!(pricer.try_range(strike(constants::neg_inf!()), at_forward).is_none());
    assert!(pricer.try_range(at_forward, double_forward).is_none());
    assert_eq!(pricer.try_up_price(double_forward), option::some(pricer.up_price(double_forward)));

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// An empty or inverted range is `none` where `range_price` aborts `EInvalidRange`.
#[test]
fun try_range_price_is_none_on_an_empty_range() {
    let (mut fx, oracle) = setup_tick_reference();
    let pricer = fx.load_pricer_bundle(&oracle);

    assert!(pricer.try_range(strike(STRIKE_BELOW), strike(STRIKE_BELOW)).is_none());
    assert!(pricer.try_range(strike(STRIKE_ABOVE), strike(STRIKE_BELOW)).is_none());

    oracle_fixture::return_oracle_bundle(oracle);
    fx.finish();
}

/// `range_price` raises the digital's own code from the lower boundary.
#[test, expected_failure(abort_code = pricing::EZeroForward)]
fun range_price_on_a_zero_forward_aborts_with_the_digital_code() {
    let (mut fx, oracle) = setup_zero_forward();
    let pricer = fx.load_pricer_bundle(&oracle);
    pricer.range_price(strike(test_constants::default_live_price()), strike(constants::pos_inf!()));
    abort EUnexpectedSuccess
}

/// `range_price` raises the digital's own code from the higher boundary.
#[test, expected_failure(abort_code = pricing::ENonPositiveVariance)]
fun range_price_where_the_variance_rounds_to_zero_aborts_from_the_higher_boundary() {
    let (mut fx, oracle) = setup_per_strike_nonpositive();
    let pricer = fx.load_pricer_bundle(&oracle);
    pricer.range_price(strike(constants::neg_inf!()), strike(test_constants::default_live_price()));
    abort EUnexpectedSuccess
}

// === safe_spot ===

/// A committed spot must be positive and at most the inclusive ceiling.
#[test]
fun safe_spot_is_positive_and_capped_at_the_pricing_safe_ceiling() {
    assert!(pricing::safe_spot(1));
    assert!(pricing::safe_spot(MAX_PRICING_SPOT));
    assert!(!pricing::safe_spot(ZERO_SPOT));
    assert!(!pricing::safe_spot(MAX_PRICING_SPOT + 1));
}

// === Helpers ===

fun pricer_at_tick(
    fx: &OracleFixture,
    snapshot: &VolSnapshot,
    spot: u64,
    tick_ms: u64,
): Option<Pricer> {
    pricing::pricer_at(snapshot, spot, GENERATION_MS, tick_ms, fx.expiry_id(), fx.expiry())
}

fun pricer_at_or_abort(
    fx: &OracleFixture,
    snapshot: &VolSnapshot,
    spot: u64,
    generation_ms: u64,
    tick_ms: u64,
): Pricer {
    pricing::pricer_at(
        snapshot,
        spot,
        generation_ms,
        tick_ms,
        fx.expiry_id(),
        fx.expiry(),
    ).destroy_some()
}

/// The default test surface with spot and the Block Scholes spot at 100e9 and the
/// given Block Scholes forward; the SVI is sourced at the fixture clock.
fun prepare_default_surface(fx: &mut OracleFixture, oracle: &mut OracleBundle, bs_forward: u64) {
    fx.prepare_real_oracle_bundle(
        oracle,
        test_constants::default_live_price(),
        bs_forward,
        test_constants::default_svi_a(),
        false,
        test_constants::default_svi_b(),
        test_constants::default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        test_constants::default_svi_m(),
        false,
    );
}

/// A pricing-safe default surface snapshot for direct `pricer_at` unit checks.
fun default_surface_snapshot(bs_spot: u64, bs_forward: u64): VolSnapshot {
    pricing::new_vol_snapshot_for_testing(
        test_constants::pyth_feed_id(),
        bs_spot,
        bs_forward,
        i64::from_u64(test_constants::default_svi_a()),
        test_constants::default_svi_b(),
        i64::from_u64(test_constants::default_svi_rho_magnitude()),
        i64::from_u64(test_constants::default_svi_m()),
        test_constants::default_svi_sigma(),
        SNAPSHOT_SOURCE_MS,
        SNAPSHOT_SOURCE_MS,
        SNAPSHOT_SOURCE_MS,
    )
}

/// The tick-reference market and surface: expiry 240_000, Block Scholes spot 100e9
/// and forward 100.5e9 sourced at 119_000, the reference SVI sourced at the 120_000
/// fixture clock.
fun setup_tick_reference(): (OracleFixture, OracleBundle) {
    let mut fx = oracle_fixture::setup_oracle(
        tick_ref::bs_spot(),
        test_constants::default_tick_size(),
        tick_ref::expiry_ms(),
    );
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        tick_ref::bs_spot(),
        tick_ref::bs_forward(),
        tick_ref::svi_a(),
        tick_ref::svi_a_is_negative(),
        tick_ref::svi_b(),
        tick_ref::svi_sigma(),
        tick_ref::svi_rho_magnitude(),
        tick_ref::svi_rho_is_negative(),
        tick_ref::svi_m_magnitude(),
        tick_ref::svi_m_is_negative(),
    );
    (fx, oracle)
}

fun setup_zero_forward(): (OracleFixture, OracleBundle) {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        ZERO_FORWARD_BS_SPOT,
        ZERO_FORWARD_BS_FORWARD,
        test_constants::default_svi_a(),
        false,
        test_constants::default_svi_b(),
        test_constants::default_svi_sigma(),
        test_constants::default_svi_rho_magnitude(),
        false,
        test_constants::default_svi_m(),
        false,
    );
    let pyth_source_ms = fx.clock().timestamp_ms();
    fx.set_pyth_bundle(&mut oracle, ZERO_FORWARD_PYTH_SPOT, pyth_source_ms);
    (fx, oracle)
}

fun setup_per_strike_nonpositive(): (OracleFixture, OracleBundle) {
    let mut fx = oracle_fixture::setup_oracle_default();
    let mut oracle = fx.take_oracle_bundle();
    fx.prepare_real_oracle_bundle(
        &mut oracle,
        test_constants::default_live_price(),
        test_constants::default_live_price(),
        PER_STRIKE_NONPOSITIVE_A_MAG,
        true,
        PER_STRIKE_NONPOSITIVE_B,
        PER_STRIKE_NONPOSITIVE_SIGMA,
        PER_STRIKE_NONPOSITIVE_RHO,
        false,
        PER_STRIKE_NONPOSITIVE_M,
        false,
    );
    (fx, oracle)
}
