// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for the canonical strike-range codec: the tick→raw-strike
/// conversion with its open-ended sentinels and the settlement prefix threshold.
/// Every expected value is hand-derived from the documented formula, independently
/// of the codec.
#[test_only]
module deepbook_predict::range_codec_tests;

use deepbook_predict::{constants, range_codec};
use std::unit_test::assert_eq;

/// `default_tick_size` used by the conversion tests (1e9 raw per tick).
const TICK_SIZE: u64 = 1_000_000_000;
/// `pos_inf_tick` = 2^30 - 1, the open upper-bound sentinel and max finite tick.
const POS_INF_TICK: u64 = 1_073_741_823;

// === strikes_from_ticks (tick -> raw, with sentinels) ===

#[test]
fun strikes_from_ticks_finite_pair_scales_by_tick_size() {
    // (100, 200] -> (100e9, 200e9].
    let (lower, higher) = range_codec::strikes_from_ticks(100, 200, TICK_SIZE);
    assert_eq!(lower, 100_000_000_000);
    assert_eq!(higher, 200_000_000_000);
}

#[test]
fun strikes_from_ticks_maps_lower_zero_to_neg_inf() {
    let (lower, higher) = range_codec::strikes_from_ticks(0, 200, TICK_SIZE);
    assert_eq!(lower, constants::neg_inf!());
    assert_eq!(higher, 200_000_000_000);
}

#[test]
fun strikes_from_ticks_maps_higher_sentinel_to_pos_inf() {
    let (lower, higher) = range_codec::strikes_from_ticks(100, POS_INF_TICK, TICK_SIZE);
    assert_eq!(lower, 100_000_000_000);
    assert_eq!(higher, constants::pos_inf!());
}

// === prefix_limit_tick (settlement prefix threshold = ceil(settlement / tick_size)) ===

#[test]
fun prefix_limit_tick_is_ceil_of_settlement_over_tick_size() {
    // Exact multiple: a settlement at a tick boundary maps to that tick.
    assert_eq!(range_codec::prefix_limit_tick(150_000_000_000, TICK_SIZE), 150);
    // One raw unit above a boundary rounds up to the next tick.
    assert_eq!(range_codec::prefix_limit_tick(150_000_000_001, TICK_SIZE), 151);
    // A tiny positive settlement still rounds up to tick 1.
    assert_eq!(range_codec::prefix_limit_tick(1, TICK_SIZE), 1);
    // Zero settlement is tick 0 (no finite boundary is strictly below it).
    assert_eq!(range_codec::prefix_limit_tick(0, TICK_SIZE), 0);
}

#[test]
fun prefix_limit_tick_can_exceed_the_encodable_tick_domain() {
    // A settlement above the maximum finite strike yields a comparison bound past
    // pos_inf_tick; it is a plain u64, never validated as a domain tick.
    let settlement = (POS_INF_TICK + 5) * TICK_SIZE;
    assert_eq!(range_codec::prefix_limit_tick(settlement, TICK_SIZE), POS_INF_TICK + 5);
}

// === settlement_in_range (the half-open (lower, higher] winner test) ===

#[test]
fun settlement_in_range_finite_boundaries_are_half_open() {
    // Range (100, 200] in ticks = (100e9, 200e9] raw. Hand-derived from the
    // half-open payoff: a settlement AT the lower boundary loses (open end), AT
    // the higher boundary wins (closed end).
    assert!(!range_codec::settlement_in_range(100, 200, 99_999_999_999, TICK_SIZE));
    assert!(!range_codec::settlement_in_range(100, 200, 100_000_000_000, TICK_SIZE));
    assert!(range_codec::settlement_in_range(100, 200, 100_000_000_001, TICK_SIZE));
    assert!(range_codec::settlement_in_range(100, 200, 199_999_999_999, TICK_SIZE));
    assert!(range_codec::settlement_in_range(100, 200, 200_000_000_000, TICK_SIZE));
    assert!(!range_codec::settlement_in_range(100, 200, 200_000_000_001, TICK_SIZE));
}

#[test]
fun settlement_in_range_neg_inf_lower_admits_any_positive_settlement() {
    // (neg_inf, 200]: lower tick 0 is the open negative-infinity end.
    assert!(range_codec::settlement_in_range(0, 200, 1, TICK_SIZE));
    assert!(range_codec::settlement_in_range(0, 200, 200_000_000_000, TICK_SIZE));
    assert!(!range_codec::settlement_in_range(0, 200, 200_000_000_001, TICK_SIZE));
    // Zero settlement is below every range, including a neg-inf lower end.
    assert!(!range_codec::settlement_in_range(0, 200, 0, TICK_SIZE));
}

#[test]
fun settlement_in_range_pos_inf_higher_admits_any_settlement_above_lower() {
    // (100, pos_inf): the open upper end wins for every settlement above lower,
    // including one whose prefix limit exceeds the encodable tick domain.
    assert!(!range_codec::settlement_in_range(100, POS_INF_TICK, 100_000_000_000, TICK_SIZE));
    assert!(range_codec::settlement_in_range(100, POS_INF_TICK, 100_000_000_001, TICK_SIZE));
    assert!(
        range_codec::settlement_in_range(
            100,
            POS_INF_TICK,
            std::u64::max_value!(),
            TICK_SIZE,
        ),
    );
}

#[test]
fun settlement_beyond_ladder_loses_against_finite_higher() {
    // A settlement whose prefix limit exceeds pos_inf_tick is above every finite
    // higher boundary: not in range.
    let settlement = (POS_INF_TICK + 5) * TICK_SIZE;
    assert!(!range_codec::settlement_in_range(100, POS_INF_TICK - 1, settlement, TICK_SIZE));
}
