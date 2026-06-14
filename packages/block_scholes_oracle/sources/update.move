// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// STUB Block Scholes signed-data payload. Stands in for the future BS verifier —
/// mirroring how `pyth_lazer` mints a verified `Update` — but performs NO
/// validation. Pure primitives, no dependencies; the real verifier will validate
/// signatures before producing an `Update`. One `Update` carries one expiry's
/// snapshot; a multi-expiry push is several Updates.
///
/// WARNING: while this package is a stub, `Update` values are forgeable. Any
/// downstream permissionless flow that treats an `Update` as verified source
/// data is not production-safe until the real verifier lands.
module block_scholes_oracle::update;

/// A verified BS snapshot for one source id at one expiry. SVI `rho`/`m` are
/// signed, carried as magnitude + sign primitives so this package stays
/// dependency-free.
public struct Update has copy, drop {
    source_id: u32,
    expiry_ms: u64,
    /// Publisher snapshot timestamp, in milliseconds.
    published_at_ms: u64,
    /// Underlying spot and the expiry's forward, 1e9-scaled.
    spot: u64,
    forward: u64,
    svi_a: u64,
    svi_b: u64,
    svi_sigma: u64,
    svi_rho_magnitude: u64,
    svi_rho_is_negative: bool,
    svi_m_magnitude: u64,
    svi_m_is_negative: bool,
}

// STUB: the production verifier validates BS signatures; this does not.
public fun new_update(
    source_id: u32,
    expiry_ms: u64,
    published_at_ms: u64,
    spot: u64,
    forward: u64,
    svi_a: u64,
    svi_b: u64,
    svi_sigma: u64,
    svi_rho_magnitude: u64,
    svi_rho_is_negative: bool,
    svi_m_magnitude: u64,
    svi_m_is_negative: bool,
): Update {
    Update {
        source_id,
        expiry_ms,
        published_at_ms,
        spot,
        forward,
        svi_a,
        svi_b,
        svi_sigma,
        svi_rho_magnitude,
        svi_rho_is_negative,
        svi_m_magnitude,
        svi_m_is_negative,
    }
}

// === Getters ===

public fun source_id(update: &Update): u32 {
    update.source_id
}

public fun expiry_ms(update: &Update): u64 {
    update.expiry_ms
}

public fun published_at_ms(update: &Update): u64 {
    update.published_at_ms
}

public fun spot(update: &Update): u64 {
    update.spot
}

public fun forward(update: &Update): u64 {
    update.forward
}

public fun svi_a(update: &Update): u64 {
    update.svi_a
}

public fun svi_b(update: &Update): u64 {
    update.svi_b
}

public fun svi_sigma(update: &Update): u64 {
    update.svi_sigma
}

public fun svi_rho_magnitude(update: &Update): u64 {
    update.svi_rho_magnitude
}

public fun svi_rho_is_negative(update: &Update): bool {
    update.svi_rho_is_negative
}

public fun svi_m_magnitude(update: &Update): u64 {
    update.svi_m_magnitude
}

public fun svi_m_is_negative(update: &Update): bool {
    update.svi_m_is_negative
}
