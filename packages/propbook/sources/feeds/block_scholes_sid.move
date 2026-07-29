// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Derives the Block Scholes series id identifying one feed slot.
/// A signed update carries its own series id, so deriving the expected id from the slot's own
/// identity — rather than reading routing fields out of the payload — is what stops a valid update
/// for one series being applied to another: a mismatch finds no slot instead of the wrong one.
/// Block Scholes reproduces this layout when assigning series ids, so a change here is a
/// coordinated break; `tests/block_scholes/block_scholes_sid_tests.move` holds the shared vectors.
module propbook::block_scholes_sid;

use propbook::constants;

/// Returns the layout version every derived id carries. Advancing it re-derives every slot rather
/// than reinterpreting stored ids under a new layout.
macro fun version(): u8 {
    1
}

macro fun kind_spot(): u8 {
    0
}

macro fun kind_forward(): u8 {
    1
}

macro fun kind_svi(): u8 {
    2
}

/// Returns the bit offsets of each field: version and kind occupy the top two bytes, then the
/// underlying, then the value scale. The expiry occupies the low 64 bits, so bits 199 down to 64
/// are unused and stay zero.
macro fun version_shift(): u8 {
    248
}

macro fun kind_shift(): u8 {
    240
}

macro fun underlying_shift(): u8 {
    208
}

macro fun decimals_shift(): u8 {
    200
}

macro fun underlying_mask(): u256 {
    0xffffffff
}

// === Public Functions ===

/// Returns the series id of the spot feed for `propbook_underlying_id`.
/// Spot is not expiry-scoped, so its expiry field is zero rather than caller-supplied.
public fun spot(propbook_underlying_id: u32): u256 {
    encode(kind_spot!(), propbook_underlying_id, 0)
}

/// Returns the series id of the forward feed for `propbook_underlying_id` at `expiry_ms`.
public fun forward(propbook_underlying_id: u32, expiry_ms: u64): u256 {
    encode(kind_forward!(), propbook_underlying_id, expiry_ms)
}

/// Returns the series id of the SVI feed for `propbook_underlying_id` at `expiry_ms`.
public fun svi(propbook_underlying_id: u32, expiry_ms: u64): u256 {
    encode(kind_svi!(), propbook_underlying_id, expiry_ms)
}

/// Returns the underlying a series id was assigned to.
/// Reads derive whole ids rather than decoding them; this exists so a store holding one
/// underlying's series can recognize an id that belongs to another and leave it alone.
public fun underlying(sid: u256): u32 {
    ((sid >> underlying_shift!()) & underlying_mask!()) as u32
}

// === Private Functions ===

/// Packs one series' identity into its id. The scale comes from `constants` rather than a
/// parameter: it describes how every stored value is read, so changing it is a package change, and
/// carrying it in the id makes a provider-side scale change surface as an unfound slot instead of a
/// value read at the wrong magnitude.
fun encode(kind: u8, propbook_underlying_id: u32, expiry_ms: u64): u256 {
    ((version!() as u256) << version_shift!()) |
    ((kind as u256) << kind_shift!()) |
    ((propbook_underlying_id as u256) << underlying_shift!()) |
    ((constants::float_scaling_decimals!() as u256) << decimals_shift!()) |
    (expiry_ms as u256)
}
