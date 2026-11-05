// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// `math::bands_ok` and `math::band_mult` on hand-built fee-band tables: flat
/// `[low, high, multiplier]` triples over contract prices at 1e9. Predict's
/// `fee_band_tests` drive the same checks through its admin setter.
#[test_only]
module deepbook_predict_math::fee_band_tests;

use deepbook_predict_math::math;
use std::unit_test::assert_eq;

/// Prices and multipliers at 1e9.
const ZERO_PRICE: u64 = 0;
const FORTY_CENTS: u64 = 400_000_000;
const FIFTY_CENTS: u64 = 500_000_000;
const JUST_UNDER_SIXTY_CENTS: u64 = 599_999_999;
const SIXTY_CENTS: u64 = 600_000_000;
const ONE_DOLLAR: u64 = 1_000_000_000;
const JUST_OVER_ONE_DOLLAR: u64 = 1_000_000_001;
const JUST_UNDER_ONE_X: u64 = 999_999_999;
const ONE_X: u64 = 1_000_000_000;
const TWO_X: u64 = 2_000_000_000;
const THREE_X: u64 = 3_000_000_000;
const TEN_X: u64 = 10_000_000_000;
const JUST_OVER_TEN_X: u64 = 10_000_000_001;

/// `[k/8, (k+1)/8)` for k = 0..7 covers $0 to $1 in eight touching bands.
const EIGHTH: u64 = 125_000_000;
const MAX_BANDS: u64 = 8;

/// The eight touching bands of `$1`, each at `multiplier`.
fun eighths(multiplier: u64): vector<u64> {
    let mut bands = vector[];
    let mut k = 0;
    while (k < MAX_BANDS) {
        bands.append(vector[k * EIGHTH, (k + 1) * EIGHTH, multiplier]);
        k = k + 1;
    };
    bands
}

#[test]
fun an_empty_table_is_valid() {
    assert_eq!(math::bands_ok(&vector[]), true);
}

/// Eight bands spanning $0 to $1 at the 1x and 10x edges are all accepted.
#[test]
fun the_boundary_tables_are_valid() {
    assert_eq!(math::bands_ok(&eighths(ONE_X)), true);
    assert_eq!(math::bands_ok(&eighths(TEN_X)), true);
    assert_eq!(math::bands_ok(&vector[ZERO_PRICE, ONE_DOLLAR, TWO_X]), true);
}

#[test]
fun each_malformed_table_is_rejected() {
    // A partial triple.
    assert_eq!(math::bands_ok(&vector[FIFTY_CENTS, SIXTY_CENTS]), false);
    // Nine bands: the eight eighths plus one more.
    let mut nine = eighths(TWO_X);
    nine.append(vector[ZERO_PRICE, EIGHTH, TWO_X]);
    assert_eq!(math::bands_ok(&nine), false);
    // An empty band, `low == high`.
    assert_eq!(math::bands_ok(&vector[FIFTY_CENTS, FIFTY_CENTS, TWO_X]), false);
    // A high above $1.
    assert_eq!(math::bands_ok(&vector[FIFTY_CENTS, JUST_OVER_ONE_DOLLAR, TWO_X]), false);
    // A multiplier below 1x, and one above 10x.
    assert_eq!(math::bands_ok(&vector[FIFTY_CENTS, SIXTY_CENTS, JUST_UNDER_ONE_X]), false);
    assert_eq!(math::bands_ok(&vector[FIFTY_CENTS, SIXTY_CENTS, JUST_OVER_TEN_X]), false);
    // Overlapping bands: the second starts below the first's high.
    assert_eq!(
        math::bands_ok(&vector[FORTY_CENTS, SIXTY_CENTS, TWO_X, FIFTY_CENTS, ONE_DOLLAR, THREE_X]),
        false,
    );
    // Unsorted bands.
    assert_eq!(
        math::bands_ok(&vector[FIFTY_CENTS, SIXTY_CENTS, TWO_X, ZERO_PRICE, FORTY_CENTS, THREE_X]),
        false,
    );
}

/// `[50c, 60c)` at 2x: `low` is in the band, `high` is not, and a price outside
/// every band, or any price under an empty table, gets 1x.
#[test]
fun a_band_holds_its_low_and_not_its_high() {
    let bands = vector[FIFTY_CENTS, SIXTY_CENTS, TWO_X];
    assert_eq!(math::band_mult(&bands, FIFTY_CENTS), TWO_X);
    assert_eq!(math::band_mult(&bands, JUST_UNDER_SIXTY_CENTS), TWO_X);
    assert_eq!(math::band_mult(&bands, SIXTY_CENTS), ONE_X);
    assert_eq!(math::band_mult(&bands, FORTY_CENTS), ONE_X);
    assert_eq!(math::band_mult(&vector[], FIFTY_CENTS), ONE_X);
}

/// Touching bands `[40c, 50c)` at 2x and `[50c, 60c)` at 3x give the shared edge to
/// the upper band.
#[test]
fun touching_bands_give_the_shared_edge_to_the_upper_band() {
    let bands = vector[FORTY_CENTS, FIFTY_CENTS, TWO_X, FIFTY_CENTS, SIXTY_CENTS, THREE_X];
    assert_eq!(math::band_mult(&bands, FORTY_CENTS), TWO_X);
    assert_eq!(math::band_mult(&bands, FIFTY_CENTS), THREE_X);
    assert_eq!(math::band_mult(&bands, SIXTY_CENTS), ONE_X);
}
