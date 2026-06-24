// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// STUB Block Scholes signed-data payloads. Stands in for the future BS verifier
/// but performs NO validation. Pure primitives, no dependencies; the real
/// verifier will validate signatures before producing these update values.
///
/// WARNING: while this package is a stub, update values are forgeable. Any
/// downstream permissionless flow that treats an update as verified source data
/// is not production-safe until the real verifier lands.
module block_scholes_oracle::update;

/// A verified BS spot update for one source id.
public struct SpotUpdate has copy, drop {
    source_id: u32,
    /// Publisher snapshot timestamp, in milliseconds.
    published_at_ms: u64,
    /// Underlying spot, 1e9-scaled.
    spot: u64,
}

/// A verified BS forward update for one source id and expiry.
public struct ForwardUpdate has copy, drop {
    source_id: u32,
    expiry_ms: u64,
    /// Publisher snapshot timestamp, in milliseconds.
    published_at_ms: u64,
    /// Expiry forward, 1e9-scaled.
    forward: u64,
}

/// A verified BS SVI update for one source id and expiry. SVI `rho`/`m` are
/// signed, carried as magnitude + sign primitives so this package stays
/// dependency-free.
public struct SVIUpdate has copy, drop {
    source_id: u32,
    expiry_ms: u64,
    /// Publisher snapshot timestamp, in milliseconds.
    published_at_ms: u64,
    svi_a: u64,
    svi_b: u64,
    svi_sigma: u64,
    svi_rho_magnitude: u64,
    svi_rho_is_negative: bool,
    svi_m_magnitude: u64,
    svi_m_is_negative: bool,
}

// STUB: the production verifier validates BS signatures; this does not.
public fun new_spot_update(source_id: u32, published_at_ms: u64, spot: u64): SpotUpdate {
    SpotUpdate { source_id, published_at_ms, spot }
}

// STUB: the production verifier validates BS signatures; this does not.
public fun new_forward_update(
    source_id: u32,
    expiry_ms: u64,
    published_at_ms: u64,
    forward: u64,
): ForwardUpdate {
    ForwardUpdate { source_id, expiry_ms, published_at_ms, forward }
}

// STUB: the production verifier validates BS signatures; this does not.
public fun new_svi_update(
    source_id: u32,
    expiry_ms: u64,
    published_at_ms: u64,
    svi_a: u64,
    svi_b: u64,
    svi_sigma: u64,
    svi_rho_magnitude: u64,
    svi_rho_is_negative: bool,
    svi_m_magnitude: u64,
    svi_m_is_negative: bool,
): SVIUpdate {
    SVIUpdate {
        source_id,
        expiry_ms,
        published_at_ms,
        svi_a,
        svi_b,
        svi_sigma,
        svi_rho_magnitude,
        svi_rho_is_negative,
        svi_m_magnitude,
        svi_m_is_negative,
    }
}

// === Spot Getters ===

public fun spot_source_id(update: &SpotUpdate): u32 {
    update.source_id
}

public fun spot_published_at_ms(update: &SpotUpdate): u64 {
    update.published_at_ms
}

public fun spot(update: &SpotUpdate): u64 {
    update.spot
}

// === Forward Getters ===

public fun forward_source_id(update: &ForwardUpdate): u32 {
    update.source_id
}

public fun forward_expiry_ms(update: &ForwardUpdate): u64 {
    update.expiry_ms
}

public fun forward_published_at_ms(update: &ForwardUpdate): u64 {
    update.published_at_ms
}

public fun forward(update: &ForwardUpdate): u64 {
    update.forward
}

// === SVI Getters ===

public fun svi_source_id(update: &SVIUpdate): u32 {
    update.source_id
}

public fun svi_expiry_ms(update: &SVIUpdate): u64 {
    update.expiry_ms
}

public fun svi_published_at_ms(update: &SVIUpdate): u64 {
    update.published_at_ms
}

public fun svi_a(update: &SVIUpdate): u64 {
    update.svi_a
}

public fun svi_b(update: &SVIUpdate): u64 {
    update.svi_b
}

public fun svi_sigma(update: &SVIUpdate): u64 {
    update.svi_sigma
}

public fun svi_rho_magnitude(update: &SVIUpdate): u64 {
    update.svi_rho_magnitude
}

public fun svi_rho_is_negative(update: &SVIUpdate): bool {
    update.svi_rho_is_negative
}

public fun svi_m_magnitude(update: &SVIUpdate): u64 {
    update.svi_m_magnitude
}

public fun svi_m_is_negative(update: &SVIUpdate): bool {
    update.svi_m_is_negative
}
