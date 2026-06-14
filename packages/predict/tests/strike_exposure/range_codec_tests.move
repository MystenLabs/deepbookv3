// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unit coverage for the canonical strike-range codec: the packed `range_key`
/// round-trip, the tick→raw-strike conversion with its open-ended sentinels, and
/// the settlement prefix threshold. Every expected value is hand-derived from the
/// documented bit layout / formula, independently of the codec.
#[test_only]
module deepbook_predict::range_codec_tests;

use deepbook_predict::{constants, range_codec};
use std::unit_test::assert_eq;

/// `default_tick_size` used by the conversion tests (1e9 raw per tick).
const TICK_SIZE: u64 = 1_000_000_000;
/// `pos_inf_tick` = 2^24 − 1, the open upper-bound sentinel and max finite tick.
const POS_INF_TICK: u64 = 16_777_215;

// === pack / unpack round-trip ===

#[test]
fun pack_unpack_round_trips() {
    // 1 | (2 << 24) = 1 + 33_554_432 = 33_554_433 (low 24 bits = lower, next 24 = higher).
    assert_eq!(range_codec::pack(1, 2), 33_554_433);
    let (lo, hi) = range_codec::unpack(33_554_433);
    assert_eq!(lo, 1);
    assert_eq!(hi, 2);

    // A larger finite pair: 100 | (200 << 24) = 100 + 3_355_443_200 = 3_355_443_300.
    assert_eq!(range_codec::pack(100, 200), 3_355_443_300);
    let (lo2, hi2) = range_codec::unpack(3_355_443_300);
    assert_eq!(lo2, 100);
    assert_eq!(hi2, 200);
}

#[test]
fun pack_unpack_sentinels_round_trip() {
    // (neg_inf lower = tick 0, pos_inf higher = pos_inf_tick): 0 | (pos_inf_tick << 24).
    let key = range_codec::pack(0, POS_INF_TICK);
    let (lo, hi) = range_codec::unpack(key);
    assert_eq!(lo, 0);
    assert_eq!(hi, POS_INF_TICK);
}

#[test, expected_failure(abort_code = range_codec::EInvalidRangeKey)]
fun unpack_with_reserved_high_bits_aborts() {
    // Bit 48 (= 2 * tick_bits) set is outside the two packed u24 fields.
    range_codec::unpack(1 << 48);
    abort 999
}

#[test, expected_failure(abort_code = range_codec::EInvalidTick)]
fun pack_lower_tick_above_domain_aborts() {
    // pos_inf_tick + 1 = 2^24 does not fit the 24-bit tick field.
    range_codec::pack(POS_INF_TICK + 1, 5);
    abort 999
}

#[test, expected_failure(abort_code = range_codec::EInvalidTick)]
fun pack_higher_tick_above_domain_aborts() {
    range_codec::pack(5, POS_INF_TICK + 1);
    abort 999
}

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
