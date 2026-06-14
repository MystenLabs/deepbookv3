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
/// `pos_inf_tick` = 2^24 − 1, the open upper-bound sentinel and max finite tick.
const POS_INF_TICK: u64 = 16_777_215;

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
