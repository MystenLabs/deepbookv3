// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stored quote-calibration policy and the published correction tables Predict
/// applies to a quoted probability.
///
/// A quote is a pure function of the vendor surface and the market's remaining
/// time, so nothing in the pricing path can move it toward the frequencies
/// markets actually realize. This module owns the state that can: per Propbook
/// underlying, a table of corrected probabilities published by a permissioned
/// keeper, plus the policy bounding what such a table may do.
///
/// The table is a map from a quoted probability to a corrected one, sampled on
/// two fixed grids — nine times to expiry by nineteen probability knots, stored
/// row-major. Both grids are upgrade-required constants, so the shape a keeper
/// fits against cannot move underneath it. The endpoints `m(0) = 0` and
/// `m(1) = 1` are implicit and never stored.
///
/// Two rules make the correction safe rather than merely small. Every knot is
/// validated at publish time to sit within `max_deviation` of the probability it
/// corrects, and every row is validated non-decreasing. Both survive every later
/// step, because resolving a market's row and applying it are weighted averages
/// of validated values: a corrected probability is therefore within
/// `max_deviation` of its input at every probability and every remaining time,
/// not only at grid points, and a corrected surface is never less monotone than
/// the surface it came from.
///
/// Resolution across time is one rule: linear interpolation in inverse time to
/// expiry, against a virtual identity row at infinite time. Beyond the longest
/// key that decays the correction smoothly toward none rather than clamping it,
/// and it needs no second constant. This module owns the tables, their
/// validation, and their evaluation; it owns no entrypoint and no authority.
module deepbook_predict::quote_calibration;

use deepbook_predict::config_constants;
use fixed_math::math;
use sui::{clock::Clock, table::{Self, Table}};

const EInvalidKnotCount: u64 = 0;
const EKnotAboveOne: u64 = 1;
const ENonMonotoneRow: u64 = 2;
const EKnotOutsideDeviation: u64 = 3;
/// A quote may not be priced by the transaction that published the correction it
/// would use. Named for the table's provenance rather than the sender: the point
/// is that publishing and pricing must not be atomic, not who submitted either.
const EPublishedInThisTransaction: u64 = 4;

/// Times to expiry the published rows are measured at, ascending, in
/// milliseconds. Upgrade-required: a keeper fits its rows to these coordinates,
/// so changing the set is a package upgrade rather than an admin transaction.
const TIME_KEYS_MS: vector<u64> = vector[
    1_000,
    2_000,
    5_000,
    10_000,
    20_000,
    45_000,
    90_000,
    180_000,
    300_000,
];

/// Probability knots are regular, so the grid is a step rather than a table:
/// knot `j` corrects the probability `(j + 1) * step`, giving 5% through 95%.
macro fun knot_step(): u64 { 50_000_000 }

macro fun knot_count(): u64 { 19 }

/// Admin-tunable calibration policy plus the latest published table per
/// underlying.
public struct QuoteCalibrationConfig has store {
    /// Whether a published correction is applied at all. While false every quote
    /// is the uncorrected formula output, whatever tables are stored.
    enabled: bool,
    /// How old a published table may be before quotes fall back to the
    /// uncorrected formula output, in milliseconds of wall clock.
    staleness_ms: u64,
    /// Furthest any published knot may sit from the probability it corrects, in
    /// FLOAT_SCALING. This is the bound on a wrong table, not a target.
    max_deviation: u64,
    /// Latest published correction per Propbook underlying. An underlying with
    /// no entry is uncorrected.
    tables: Table<u32, CalibrationTable>,
}

/// One underlying's published correction.
public struct CalibrationTable has store {
    /// Corrected probabilities at every grid point in FLOAT_SCALING, row-major:
    /// entry `r * knot_count + j` is the correction at time key `r` and knot `j`.
    knots: vector<u64>,
    /// Clock time of the transaction that published this table.
    updated_at_ms: u64,
    /// Digest of the transaction that published it. Pricing aborts rather than
    /// quoting in that same transaction, mirroring the oracle-provenance rule:
    /// falling back to the uncorrected price instead would hand the publisher a
    /// private, atomic way to quote outside the correction, which is the one
    /// thing none of the other bounds here would catch.
    writer_digest: vector<u8>,
}

/// One market's correction for the duration of one transaction: the published
/// rows resolved to that market's remaining time. Carried on the transaction-local
/// pricer so every strike in a market prices under exactly one correction.
public struct CalibrationRow has copy, drop {
    knots: vector<u64>,
}

// === Public-Package Functions ===

public(package) fun enabled(config: &QuoteCalibrationConfig): bool {
    config.enabled
}

public(package) fun staleness_ms(config: &QuoteCalibrationConfig): u64 {
    config.staleness_ms
}

public(package) fun max_deviation(config: &QuoteCalibrationConfig): u64 {
    config.max_deviation
}

/// Number of entries a published table must carry, for the publishing
/// entrypoint's own event and argument shaping.
public(package) fun published_knot_count(): u64 {
    let keys = TIME_KEYS_MS;
    keys.length() * knot_count!()
}

public(package) fun new(ctx: &mut TxContext): QuoteCalibrationConfig {
    QuoteCalibrationConfig {
        enabled: config_constants::default_quote_calibration_enabled!(),
        staleness_ms: config_constants::default_quote_calibration_staleness_ms!(),
        max_deviation: config_constants::default_quote_calibration_max_deviation!(),
        tables: table::new(ctx),
    }
}

public(package) fun set_enabled(config: &mut QuoteCalibrationConfig, enabled: bool) {
    config.enabled = enabled;
}

public(package) fun set_staleness_ms(config: &mut QuoteCalibrationConfig, value: u64) {
    config_constants::assert_quote_calibration_staleness_ms(value);
    config.staleness_ms = value;
}

public(package) fun set_max_deviation(config: &mut QuoteCalibrationConfig, value: u64) {
    config_constants::assert_quote_calibration_max_deviation(value);
    config.max_deviation = value;
}

/// Validate a published table and store it as one underlying's current
/// correction, replacing any earlier one.
///
/// Validation is the whole safety argument, so it happens here rather than at the
/// entrypoint: a table that passes cannot move any quoted probability further
/// than `max_deviation`, and cannot make a corrected surface less monotone than
/// the surface it corrects.
public(package) fun publish(
    config: &mut QuoteCalibrationConfig,
    propbook_underlying_id: u32,
    knots: vector<u64>,
    clock: &Clock,
    ctx: &TxContext,
) {
    config.assert_publishable(&knots);

    let table_entry = CalibrationTable {
        knots,
        updated_at_ms: clock.timestamp_ms(),
        writer_digest: *ctx.digest(),
    };
    if (config.tables.contains(propbook_underlying_id)) {
        let previous = config.tables.remove(propbook_underlying_id);
        let CalibrationTable { .. } = previous;
    };
    config.tables.add(propbook_underlying_id, table_entry);
}

/// Resolve one market's correction, or `none` when the protocol must quote
/// uncorrected: the switch is off, the underlying has no published table, or the
/// table has aged past `staleness_ms`. Those three are protocol-wide states that
/// apply to every trader alike.
///
/// A table published by this very transaction is not one of them — it aborts. The
/// publisher does not need atomicity to use a table it published, since the next
/// transaction will do, so refusing costs it nothing legitimate; but allowing the
/// uncorrected fallback here would give the publisher alone a per-transaction way
/// to quote outside the correction, without ever publishing a table that the
/// deviation, monotonicity, or staleness bounds would reject.
///
/// Precondition: `clock.timestamp_ms() < expiry_ms`; live-pricing callers enforce
/// pre-expiry liveness before this derives remaining time by exact subtraction.
public(package) fun resolve_row(
    config: &QuoteCalibrationConfig,
    propbook_underlying_id: u32,
    expiry_ms: u64,
    clock: &Clock,
    ctx: &TxContext,
): Option<CalibrationRow> {
    if (!config.enabled) return option::none();
    if (!config.tables.contains(propbook_underlying_id)) return option::none();

    let published = &config.tables[propbook_underlying_id];
    assert!(published.writer_digest != *ctx.digest(), EPublishedInThisTransaction);

    let now = clock.timestamp_ms();
    if (published.updated_at_ms > now) return option::none();
    if (now - published.updated_at_ms > config.staleness_ms) return option::none();

    option::some(published.interpolate_in_time(expiry_ms - now))
}

/// Map one raw probability through this market's correction.
///
/// The knot grid is regular, so the bracketing interval is an index rather than a
/// search. The implicit endpoints `m(0) = 0` and `m(1) = 1` supply the outermost
/// interval on each side, which is what keeps a partition of the strike line
/// summing to one after correction.
public(package) fun apply(row: &CalibrationRow, probability: u64): u64 {
    if (probability >= math::float_scaling!()) return math::float_scaling!();

    let interval = probability / knot_step!();
    let lower = if (interval == 0) 0 else row.knots[interval - 1];
    let upper = if (interval == knot_count!()) {
        math::float_scaling!()
    } else {
        row.knots[interval]
    };
    let offset = probability - interval * knot_step!();
    // Rows are non-decreasing and both endpoints are pinned, so `upper >= lower`.
    lower + math::mul_div_down(upper - lower, offset, knot_step!())
}

// === Private Functions ===

/// Abort unless `knots` is a table this configuration would accept.
fun assert_publishable(config: &QuoteCalibrationConfig, knots: &vector<u64>) {
    assert!(knots.length() == published_knot_count(), EInvalidKnotCount);

    let keys = TIME_KEYS_MS;
    let rows = keys.length();
    let mut row = 0;
    while (row < rows) {
        let base = row * knot_count!();
        let mut previous = 0;
        let mut j = 0;
        while (j < knot_count!()) {
            let knot = knots[base + j];
            assert!(knot <= math::float_scaling!(), EKnotAboveOne);
            // Non-decreasing against the previous knot, and for the first knot
            // against the implicit `m(0) = 0`, so the whole map including its
            // endpoints is non-decreasing.
            assert!(knot >= previous, ENonMonotoneRow);
            assert!(within_deviation(knot, grid_probability(j), config.max_deviation),
                EKnotOutsideDeviation);
            previous = knot;
            j = j + 1;
        };
        row = row + 1;
    };
}

/// The probability knot `j` corrects.
fun grid_probability(j: u64): u64 {
    (j + 1) * knot_step!()
}

fun within_deviation(knot: u64, grid: u64, max_deviation: u64): bool {
    let distance = if (knot >= grid) knot - grid else grid - knot;
    distance <= max_deviation
}

/// Blend the published rows into the single row that applies at `remaining_ms`.
///
/// One rule covers every remaining time: interpolate linearly in inverse time
/// against a virtual identity row at infinite time to expiry. Inside the grid the
/// weight on the lower key's row is `k_lo * (k_hi - t) / (t * (k_hi - k_lo))`,
/// which is that interpolation written without forming a reciprocal. Beyond the
/// longest key the same expression with `k_hi` at infinity collapses to
/// `k_max / t`, so a market further out than the grid reaches decays smoothly
/// toward no correction instead of clamping. Below the shortest key that row
/// applies unchanged; there is nothing further in to interpolate toward.
fun interpolate_in_time(published: &CalibrationTable, remaining_ms: u64): CalibrationRow {
    let keys = TIME_KEYS_MS;
    let last = keys.length() - 1;

    if (remaining_ms <= keys[0]) return published.row(0);
    if (remaining_ms >= keys[last]) {
        // Blend the longest key's row toward identity, whose knots are the grid
        // probabilities themselves.
        let weight = math::mul_div_down(keys[last], math::float_scaling!(), remaining_ms);
        return published.blend_row_with_identity(last, weight)
    };

    let mut lower = 0;
    while (keys[lower + 1] <= remaining_ms) {
        lower = lower + 1;
    };
    let low_key = keys[lower];
    let high_key = keys[lower + 1];
    // u128 throughout: the numerator reaches `k_lo * (k_hi - t) * 1e9`, which
    // leaves u64 well before the longest key.
    let weight =
        ((low_key as u128) * ((high_key - remaining_ms) as u128) * (math::float_scaling!() as u128)
            / ((remaining_ms as u128) * ((high_key - low_key) as u128))) as u64;
    published.blend_rows(lower, lower + 1, weight)
}

/// One published row, copied out as this transaction's correction.
fun row(published: &CalibrationTable, index: u64): CalibrationRow {
    let base = index * knot_count!();
    let mut knots = vector[];
    let mut j = 0;
    while (j < knot_count!()) {
        knots.push_back(published.knots[base + j]);
        j = j + 1;
    };
    CalibrationRow { knots }
}

/// Weighted average of two published rows, `weight` on the first.
fun blend_rows(
    published: &CalibrationTable,
    low_index: u64,
    high_index: u64,
    weight: u64,
): CalibrationRow {
    let low_base = low_index * knot_count!();
    let high_base = high_index * knot_count!();
    let mut knots = vector[];
    let mut j = 0;
    while (j < knot_count!()) {
        knots.push_back(
            weighted(published.knots[low_base + j], published.knots[high_base + j], weight),
        );
        j = j + 1;
    };
    CalibrationRow { knots }
}

/// Weighted average of one published row and the identity row, `weight` on the
/// published one.
fun blend_row_with_identity(
    published: &CalibrationTable,
    index: u64,
    weight: u64,
): CalibrationRow {
    let base = index * knot_count!();
    let mut knots = vector[];
    let mut j = 0;
    while (j < knot_count!()) {
        knots.push_back(weighted(published.knots[base + j], grid_probability(j), weight));
        j = j + 1;
    };
    CalibrationRow { knots }
}

/// `weight * first + (1 - weight) * second`, rounded down.
///
/// Rounding down is monotone, so a weighted average of non-decreasing rows stays
/// non-decreasing, and it can only move the result toward the identity by less
/// than one raw unit — neither the deviation bound nor the monotonicity argument
/// depends on the rounding direction.
fun weighted(first: u64, second: u64, weight: u64): u64 {
    let scale = math::float_scaling!() as u128;
    (((first as u128) * (weight as u128) + (second as u128) * (scale - (weight as u128))) / scale)
        as u64
}
