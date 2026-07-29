// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Pins the Block Scholes series-id layout against literal expected ids.
/// Block Scholes assigns series ids using this same layout, so these literals are a shared
/// interface: a change that keeps them passing is safe, and a change that breaks them is a
/// coordinated break with the provider rather than a local edit.
/// Generator: `tests/helper/reference/generate_sid_vectors.py`.
#[test_only]
module propbook::block_scholes_sid_tests;

use propbook::block_scholes_sid;
use std::unit_test::assert_eq;

const BTC_USD: u32 = 1;
const EXPIRY_MS: u64 = 1_785_888_000_000;
const MAX_UNDERLYING: u32 = 0xffffffff;
const MAX_EXPIRY_MS: u64 = 0xffffffffffffffff;

// Expected ids, from the generator. Read byte-by-byte: version, kind, underlying (4),
// decimals, seventeen unused bytes, expiry (8).
const SPOT_BTC_ID: u256 = 0x0100000000010900000000000000000000000000000000000000000000000000;
const FORWARD_BTC_ID: u256 = 0x0101000000010900000000000000000000000000000000000000019fcf384800;
const SVI_BTC_ID: u256 = 0x0102000000010900000000000000000000000000000000000000019fcf384800;
const FORWARD_BTC_ZERO_EXPIRY_ID: u256 =
    0x0101000000010900000000000000000000000000000000000000000000000000;
const SATURATED_SVI_ID: u256 = 0x0102ffffffff090000000000000000000000000000000000ffffffffffffffff;

/// Bits 199 down to 64, the region no field occupies.
const RESERVED_MASK: u256 = 0x00000000000000ffffffffffffffffffffffffffffffffff0000000000000000;
const EXPIRY_MASK: u256 = 0x000000000000000000000000000000000000000000000000ffffffffffffffff;

#[test]
fun spot_id_matches_the_shared_vector() {
    assert_eq!(block_scholes_sid::spot(BTC_USD), SPOT_BTC_ID);
}

#[test]
fun forward_id_matches_the_shared_vector() {
    assert_eq!(block_scholes_sid::forward(BTC_USD, EXPIRY_MS), FORWARD_BTC_ID);
}

#[test]
fun svi_id_matches_the_shared_vector() {
    assert_eq!(block_scholes_sid::svi(BTC_USD, EXPIRY_MS), SVI_BTC_ID);
}

/// Every field at its maximum still packs into its own region.
#[test]
fun saturated_fields_match_the_shared_vector() {
    assert_eq!(block_scholes_sid::svi(MAX_UNDERLYING, MAX_EXPIRY_MS), SATURATED_SVI_ID);
}

/// Spot's zero expiry must not collide with a forward at expiry zero: kind alone separates them.
#[test]
fun kind_separates_spot_from_a_zero_expiry_forward() {
    assert_eq!(block_scholes_sid::forward(BTC_USD, 0), FORWARD_BTC_ZERO_EXPIRY_ID);
    assert!(block_scholes_sid::spot(BTC_USD) != FORWARD_BTC_ZERO_EXPIRY_ID);
}

#[test]
fun kinds_are_distinct_at_one_expiry() {
    let spot = block_scholes_sid::spot(BTC_USD);
    let forward = block_scholes_sid::forward(BTC_USD, EXPIRY_MS);
    let svi = block_scholes_sid::svi(BTC_USD, EXPIRY_MS);
    assert!(forward != svi);
    assert!(spot != forward);
    assert!(spot != svi);
}

#[test]
fun underlyings_are_distinct() {
    assert!(block_scholes_sid::spot(BTC_USD) != block_scholes_sid::spot(2));
    assert!(
        block_scholes_sid::forward(BTC_USD, EXPIRY_MS) !=
        block_scholes_sid::forward(2, EXPIRY_MS),
    );
}

#[test]
fun expiries_are_distinct() {
    assert!(
        block_scholes_sid::forward(BTC_USD, EXPIRY_MS) !=
        block_scholes_sid::forward(BTC_USD, EXPIRY_MS + 1),
    );
}

/// The unused region stays zero even with every field saturated, so no field can spill into it.
#[test]
fun reserved_bits_are_zero() {
    assert_eq!(block_scholes_sid::spot(BTC_USD) & RESERVED_MASK, 0);
    assert_eq!(block_scholes_sid::forward(BTC_USD, EXPIRY_MS) & RESERVED_MASK, 0);
    assert_eq!(block_scholes_sid::svi(BTC_USD, EXPIRY_MS) & RESERVED_MASK, 0);
    assert_eq!(block_scholes_sid::svi(MAX_UNDERLYING, MAX_EXPIRY_MS) & RESERVED_MASK, 0);
}

/// A full-width expiry lands in the low 64 bits and leaves every other field untouched.
#[test]
fun expiry_occupies_the_low_64_bits() {
    let id = block_scholes_sid::forward(BTC_USD, MAX_EXPIRY_MS);
    assert_eq!(id & EXPIRY_MASK, MAX_EXPIRY_MS as u256);
    assert_eq!(id ^ (MAX_EXPIRY_MS as u256), FORWARD_BTC_ZERO_EXPIRY_ID);
}
