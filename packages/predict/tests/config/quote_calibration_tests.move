// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Behaviour of the quote calibration correction: what a publication must look
/// like, when a published correction applies, how it resolves across time, and
/// what it may do to a probability once it does.
///
/// Every test drives the real path — publish, then resolve in a later
/// transaction — because pricing refuses a correction its own transaction wrote,
/// and because that is the only composition production ever performs. Expected
/// values are hand-derived from the interpolation rule with the arithmetic shown,
/// never read back from the contract.
#[test_only]
module deepbook_predict::quote_calibration_tests;

use deepbook_predict::{
    config_constants,
    quote_calibration::{Self, QuoteCalibrationConfig, CalibrationRow},
    test_constants
};
use fixed_math::math;
use std::unit_test::assert_eq;
use sui::{clock::{Self, Clock}, test_scenario::{Self as test, Scenario}, test_utils::destroy};

const KNOT_STEP: u64 = 50_000_000;
const KNOT_COUNT: u64 = 19;
const TIME_KEYS: vector<u64> = vector[
    1_000, 2_000, 5_000, 10_000, 20_000, 45_000, 90_000, 180_000, 300_000, 600_000, 900_000,
];

/// Wall-clock instant every test publishes at; expiries are expressed as offsets
/// from it so a test names the remaining time it cares about.
const PUBLISH_AT_MS: u64 = 1_000_000;

// === Fixtures ===

/// The probability knot `j` corrects: 5%, 10%, ... 95%.
fun grid_probability(j: u64): u64 {
    (j + 1) * KNOT_STEP
}

fun row_count(): u64 {
    let keys = TIME_KEYS;
    keys.length()
}

/// A table built by applying `shape` to each knot's own grid probability. The
/// closure receives the grid probability and returns the corrected one, so a
/// fixture reads as the correction it expresses.
macro fun table_from($shape: |u64| -> u64): vector<u64> {
    let mut knots = vector[];
    let mut r = 0;
    while (r < row_count()) {
        let mut j = 0;
        while (j < KNOT_COUNT) {
            knots.push_back($shape(grid_probability(j)));
            j = j + 1;
        };
        r = r + 1;
    };
    knots
}

/// Corrects nothing: every knot maps its grid probability to itself.
fun identity_table(): vector<u64> {
    table_from!(|p| p)
}

/// Every knot pinned to one value. Publishable — non-decreasing, all in range —
/// and the shape that collapses a range quote to zero.
fun flat_table(value: u64): vector<u64> {
    table_from!(|_| value)
}

/// Pushes every probability toward one, by `delta`, saturating at one.
fun raised_table(delta: u64): vector<u64> {
    table_from!(|p| math::float_scaling!().min(p + delta))
}

fun new_config(scenario: &mut Scenario): QuoteCalibrationConfig {
    let mut config = quote_calibration::new(scenario.ctx());
    config.set_enabled(true);
    config
}

fun new_clock(scenario: &mut Scenario): Clock {
    let mut c = clock::create_for_testing(scenario.ctx());
    c.set_for_testing(PUBLISH_AT_MS);
    c
}

/// Publish `knots`, cross a transaction boundary, and resolve the row that
/// applies with `remaining_ms` left on the market.
fun publish_then_resolve(
    scenario: &mut Scenario,
    config: &mut QuoteCalibrationConfig,
    clock: &Clock,
    knots: vector<u64>,
    remaining_ms: u64,
): Option<CalibrationRow> {
    config.publish(test_constants::propbook_underlying_id(), knots, clock, scenario.ctx());
    scenario.next_tx(test_constants::admin());
    config.resolve_row(
        test_constants::propbook_underlying_id(),
        clock.timestamp_ms() + remaining_ms,
        clock,
        scenario.ctx(),
    )
}

// === Publication validation ===

#[test, expected_failure(abort_code = quote_calibration::EInvalidKnotCount)]
fun publish_with_wrong_length_aborts() {
    let mut scenario = test::begin(test_constants::admin());
    let mut config = new_config(&mut scenario);
    let clock = new_clock(&mut scenario);
    let mut short = identity_table();
    short.pop_back();
    config.publish(test_constants::propbook_underlying_id(), short, &clock, scenario.ctx());
    abort 999
}

#[test, expected_failure(abort_code = quote_calibration::EKnotAboveOne)]
fun publish_with_knot_above_one_aborts() {
    let mut scenario = test::begin(test_constants::admin());
    let mut config = new_config(&mut scenario);
    let clock = new_clock(&mut scenario);
    let mut knots = identity_table();
    // Last knot of the first row, one raw unit past certainty.
    *knots.borrow_mut(KNOT_COUNT - 1) = math::float_scaling!() + 1;
    config.publish(test_constants::propbook_underlying_id(), knots, &clock, scenario.ctx());
    abort 999
}

#[test, expected_failure(abort_code = quote_calibration::ENonMonotoneRow)]
fun publish_with_decreasing_row_aborts() {
    let mut scenario = test::begin(test_constants::admin());
    let mut config = new_config(&mut scenario);
    let clock = new_clock(&mut scenario);
    let mut knots = identity_table();
    // Second knot of the first row drops below the first.
    *knots.borrow_mut(1) = grid_probability(0) - 1;
    config.publish(test_constants::propbook_underlying_id(), knots, &clock, scenario.ctx());
    abort 999
}

#[test]
fun publish_accepts_a_correction_larger_than_the_deviation_cap() {
    // Size is policy applied when a quote is priced, not a condition of
    // publishing: a keeper publishes what it measured.
    let mut scenario = test::begin(test_constants::admin());
    let mut config = new_config(&mut scenario);
    let clock = new_clock(&mut scenario);
    let oversized = raised_table(3 * config_constants::default_quote_calibration_max_deviation!());
    let row = publish_then_resolve(&mut scenario, &mut config, &clock, oversized, 1_000);
    assert!(row.is_some());
    destroy(row);
    destroy(config);
    destroy(clock);
    scenario.end();
}

#[test, expected_failure(abort_code = quote_calibration::EPublishedInThisTransaction)]
fun pricing_in_the_publishing_transaction_aborts() {
    let mut scenario = test::begin(test_constants::admin());
    let mut config = new_config(&mut scenario);
    let clock = new_clock(&mut scenario);
    config.publish(
        test_constants::propbook_underlying_id(),
        identity_table(),
        &clock,
        scenario.ctx(),
    );
    // No `next_tx`: same transaction digest, so the correction is refused.
    config.resolve_row(
        test_constants::propbook_underlying_id(),
        clock.timestamp_ms() + 1_000,
        &clock,
        scenario.ctx(),
    );
    abort 999
}

// === When no correction applies ===

#[test]
fun switched_off_yields_no_correction() {
    let mut scenario = test::begin(test_constants::admin());
    let mut config = new_config(&mut scenario);
    let clock = new_clock(&mut scenario);
    config.set_enabled(false);
    let row = publish_then_resolve(
        &mut scenario,
        &mut config,
        &clock,
        raised_table(1_000_000),
        1_000,
    );
    assert!(row.is_none());
    destroy(row);
    destroy(config);
    destroy(clock);
    scenario.end();
}

#[test]
fun unpublished_underlying_yields_no_correction() {
    let mut scenario = test::begin(test_constants::admin());
    let mut config = new_config(&mut scenario);
    let clock = new_clock(&mut scenario);
    config.publish(
        test_constants::propbook_underlying_id(),
        raised_table(1_000_000),
        &clock,
        scenario.ctx(),
    );
    scenario.next_tx(test_constants::admin());
    let other = test_constants::propbook_underlying_id() + 1;
    let row = config.resolve_row(other, clock.timestamp_ms() + 1_000, &clock, scenario.ctx());
    assert!(row.is_none());
    destroy(row);
    destroy(config);
    destroy(clock);
    scenario.end();
}

#[test]
fun a_correction_at_the_staleness_limit_still_applies() {
    let mut scenario = test::begin(test_constants::admin());
    let mut config = new_config(&mut scenario);
    let mut clock = new_clock(&mut scenario);
    config.publish(
        test_constants::propbook_underlying_id(),
        raised_table(1_000_000),
        &clock,
        scenario.ctx(),
    );
    scenario.next_tx(test_constants::admin());
    // Exactly `staleness_ms` old: the check is strictly greater-than.
    clock.set_for_testing(
        PUBLISH_AT_MS + config_constants::default_quote_calibration_staleness_ms!(),
    );
    let row = config.resolve_row(
        test_constants::propbook_underlying_id(),
        clock.timestamp_ms() + 1_000,
        &clock,
        scenario.ctx(),
    );
    assert!(row.is_some());
    destroy(row);
    destroy(config);
    destroy(clock);
    scenario.end();
}

#[test]
fun a_correction_one_millisecond_past_the_limit_does_not() {
    let mut scenario = test::begin(test_constants::admin());
    let mut config = new_config(&mut scenario);
    let mut clock = new_clock(&mut scenario);
    config.publish(
        test_constants::propbook_underlying_id(),
        raised_table(1_000_000),
        &clock,
        scenario.ctx(),
    );
    scenario.next_tx(test_constants::admin());
    clock.set_for_testing(
        PUBLISH_AT_MS + config_constants::default_quote_calibration_staleness_ms!() + 1,
    );
    let row = config.resolve_row(
        test_constants::propbook_underlying_id(),
        clock.timestamp_ms() + 1_000,
        &clock,
        scenario.ctx(),
    );
    assert!(row.is_none());
    destroy(row);
    destroy(config);
    destroy(clock);
    scenario.end();
}

// === Applying a correction ===

#[test]
fun the_identity_correction_leaves_every_probability_untouched() {
    let mut scenario = test::begin(test_constants::admin());
    let mut config = new_config(&mut scenario);
    let clock = new_clock(&mut scenario);
    let row = publish_then_resolve(&mut scenario, &mut config, &clock, identity_table(), 1_000);
    let row = row.destroy_some();

    // Interval edges on both sides of every boundary the index can land on,
    // plus the two pinned endpoints.
    let probes = vector[
        0,
        1,
        KNOT_STEP - 1,
        KNOT_STEP,
        KNOT_STEP + 1,
        500_000_000,
        949_999_999,
        950_000_000,
        999_999_999,
        math::float_scaling!(),
    ];
    probes.do!(|p| assert_eq!(row.apply(p), p));

    destroy(config);
    destroy(clock);
    scenario.end();
}

#[test]
fun endpoints_are_pinned_under_a_correction_that_moves_everything() {
    let mut scenario = test::begin(test_constants::admin());
    let mut config = new_config(&mut scenario);
    let clock = new_clock(&mut scenario);
    let row = publish_then_resolve(
        &mut scenario,
        &mut config,
        &clock,
        flat_table(500_000_000),
        1_000,
    );
    let row = row.destroy_some();

    // m(0) = 0 and m(1) = 1 are implicit and never stored, so they survive any
    // published table. This is what keeps a partition of the strike line summing
    // to one after correction.
    assert_eq!(row.apply(0), 0);
    assert_eq!(row.apply(math::float_scaling!()), math::float_scaling!());

    destroy(config);
    destroy(clock);
    scenario.end();
}

#[test]
fun a_correction_is_truncated_at_the_deviation_cap() {
    let mut scenario = test::begin(test_constants::admin());
    let mut config = new_config(&mut scenario);
    let clock = new_clock(&mut scenario);
    let cap = config_constants::default_quote_calibration_max_deviation!();
    // Every knot pushed a full cap-and-a-half toward one.
    let row = publish_then_resolve(
        &mut scenario,
        &mut config,
        &clock,
        raised_table(cap + cap / 2),
        1_000,
    );
    let row = row.destroy_some();

    // At a knot the published value is p + 1.5*cap; the clamp admits p + cap.
    let at_knot = grid_probability(5);
    assert_eq!(row.apply(at_knot), at_knot + cap);

    destroy(config);
    destroy(clock);
    scenario.end();
}

#[test]
fun a_zero_deviation_cap_admits_only_the_identity() {
    let mut scenario = test::begin(test_constants::admin());
    let mut config = new_config(&mut scenario);
    let clock = new_clock(&mut scenario);
    config.set_max_deviation(0);
    let row = publish_then_resolve(
        &mut scenario,
        &mut config,
        &clock,
        flat_table(500_000_000),
        1_000,
    );
    let row = row.destroy_some();

    let probes = vector[0, KNOT_STEP, 300_000_000, 500_000_000, 700_000_000, 950_000_000];
    probes.do!(|p| assert_eq!(row.apply(p), p));

    destroy(config);
    destroy(clock);
    scenario.end();
}

#[test]
fun a_flat_correction_prices_a_narrow_range_at_zero() {
    // The sharp corner of the design, pinned so it cannot regress silently: a
    // published table flat across a band maps both boundaries of a range to one
    // value, and the range — a difference of two corrected probabilities — is
    // then exactly zero.
    let mut scenario = test::begin(test_constants::admin());
    let mut config = new_config(&mut scenario);
    let clock = new_clock(&mut scenario);
    let row = publish_then_resolve(
        &mut scenario,
        &mut config,
        &clock,
        flat_table(500_000_000),
        1_000,
    );
    let row = row.destroy_some();

    // Raw boundaries 0.58 and 0.42 are a range of 0.16; both sit inside the
    // default cap of the flat value, so both correct to exactly 0.5.
    let higher = row.apply(580_000_000);
    let lower = row.apply(420_000_000);
    assert_eq!(higher, 500_000_000);
    assert_eq!(lower, 500_000_000);
    assert_eq!(higher - lower, 0);

    destroy(config);
    destroy(clock);
    scenario.end();
}

// === Resolving across time ===

#[test]
fun below_the_shortest_key_the_shortest_row_applies_unchanged() {
    let mut scenario = test::begin(test_constants::admin());
    let mut config = new_config(&mut scenario);
    let clock = new_clock(&mut scenario);
    let cap = config_constants::default_quote_calibration_max_deviation!();
    let table = raised_table(cap);
    let keys = TIME_KEYS;

    let at_key = publish_then_resolve(&mut scenario, &mut config, &clock, table, keys[0]);
    let at_key = at_key.destroy_some();
    let below = config.resolve_row(
        test_constants::propbook_underlying_id(),
        clock.timestamp_ms() + keys[0] / 2,
        &clock,
        scenario.ctx(),
    );
    let below = below.destroy_some();

    // Nothing further in to interpolate toward, so the row is the same either way.
    let p = grid_probability(3);
    assert_eq!(below.apply(p), at_key.apply(p));
    assert_eq!(below.apply(p), p + cap);

    destroy(config);
    destroy(clock);
    scenario.end();
}

#[test]
fun between_two_keys_the_rows_blend_by_inverse_time() {
    let mut scenario = test::begin(test_constants::admin());
    let mut config = new_config(&mut scenario);
    let clock = new_clock(&mut scenario);
    // A uniform correction makes every row identical, so the blend weight cannot
    // change the result — which is what isolates the arithmetic below from the
    // shape of the table.
    let cap = config_constants::default_quote_calibration_max_deviation!();
    let row = publish_then_resolve(&mut scenario, &mut config, &clock, raised_table(cap), 1_500);
    let row = row.destroy_some();

    // t = 1500 sits between keys 1000 and 2000. Weight on the low row is
    // k_lo*(k_hi - t) / (t*(k_hi - k_lo)) = 1000*500 / (1500*1000) = 1/3, and a
    // weighted average of two identical rows is that row.
    let p = grid_probability(7);
    assert_eq!(row.apply(p), p + cap);

    destroy(config);
    destroy(clock);
    scenario.end();
}

#[test]
fun past_the_longest_key_the_correction_decays_toward_none() {
    let mut scenario = test::begin(test_constants::admin());
    let mut config = new_config(&mut scenario);
    let clock = new_clock(&mut scenario);
    let keys = TIME_KEYS;
    let longest = keys[keys.length() - 1];
    // 0.05 correction at every knot, well inside the cap so the clamp does not
    // mask the decay.
    let delta = 50_000_000;
    let table = raised_table(delta);
    let p = grid_probability(3);

    let at_longest = publish_then_resolve(&mut scenario, &mut config, &clock, table, longest);
    let at_longest = at_longest.destroy_some();
    assert_eq!(at_longest.apply(p), p + delta);

    // At twice the longest key the weight on the published row is
    // k_max/t = 1/2, so half the correction survives.
    let at_double = config.resolve_row(
        test_constants::propbook_underlying_id(),
        clock.timestamp_ms() + 2 * longest,
        &clock,
        scenario.ctx(),
    );
    assert_eq!(at_double.destroy_some().apply(p), p + delta / 2);

    // At ten times, a tenth.
    let at_ten = config.resolve_row(
        test_constants::propbook_underlying_id(),
        clock.timestamp_ms() + 10 * longest,
        &clock,
        scenario.ctx(),
    );
    assert_eq!(at_ten.destroy_some().apply(p), p + delta / 10);

    destroy(config);
    destroy(clock);
    scenario.end();
}

// === Properties that must hold for every publishable table ===

#[test]
fun every_publishable_table_stays_inside_the_cap_and_non_decreasing() {
    // The bound and monotonicity are what make a wrong correction a bounded
    // error rather than a repricing, and publication deliberately does not check
    // either — the clamp and the row order do. Exercised over the shapes the
    // validation actually admits, including ones no honest keeper would send.
    let mut scenario = test::begin(test_constants::admin());
    let mut config = new_config(&mut scenario);
    let clock = new_clock(&mut scenario);
    let cap = config_constants::default_quote_calibration_max_deviation!();

    let shapes = vector[
        flat_table(0),
        flat_table(math::float_scaling!()),
        flat_table(500_000_000),
        raised_table(math::float_scaling!()),
        table_from!(|p| if (p < 500_000_000) 0 else math::float_scaling!()),
        table_from!(|p| p / 4),
    ];
    let times = vector[1, 500, 1_000, 1_500, 20_000, 900_000, 5_000_000];

    shapes.do!(|shape| {
        config.publish(test_constants::propbook_underlying_id(), shape, &clock, scenario.ctx());
        scenario.next_tx(test_constants::admin());
        times.do!(|t| {
            let row = config.resolve_row(
                test_constants::propbook_underlying_id(),
                clock.timestamp_ms() + t,
                &clock,
                scenario.ctx(),
            );
            let row = row.destroy_some();
            let mut previous = 0;
            let mut p = 0;
            while (p <= math::float_scaling!()) {
                let corrected = row.apply(p);
                let moved = if (corrected >= p) corrected - p else p - corrected;
                assert!(moved <= cap);
                assert!(corrected >= previous);
                previous = corrected;
                p = p + 7_000_000;
            };
            assert_eq!(row.apply(0), 0);
            assert_eq!(row.apply(math::float_scaling!()), math::float_scaling!());
        });
    });

    destroy(config);
    destroy(clock);
    scenario.end();
}
