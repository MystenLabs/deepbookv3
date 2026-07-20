// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Immutable oracle inputs. Profiles construct feed state but contain no expected
/// pricing truth.
#[test_only]
module deepbook_predict::oracle_profile;

const SMOKE_SPOT: u64 = 100_000_000_000;
const SMOKE_SOURCE_TIMESTAMP_MS: u64 = 119_000;
const SMOKE_SVI_A: u64 = 1;
const SMOKE_SVI_B: u64 = 10_000;
const SMOKE_SVI_RHO_MAGNITUDE: u64 = 1_000_000_000;
const SMOKE_SVI_M_MAGNITUDE: u64 = 10_000_000_000;
const SMOKE_SVI_SIGMA: u64 = 1_000_000;
const EXACT_HALF_SVI_A: u64 = 1;
const EXACT_HALF_SVI_SIGMA: u64 = 1_000_000;

public struct SurfaceProfile has copy, drop {
    pyth_spot: u64,
    block_scholes_spot: u64,
    block_scholes_forward: u64,
    svi_a: u64,
    svi_a_is_negative: bool,
    svi_b: u64,
    svi_sigma: u64,
    svi_rho_magnitude: u64,
    svi_rho_is_negative: bool,
    svi_m_magnitude: u64,
    svi_m_is_negative: bool,
    source_timestamp_ms: u64,
}

public fun new(
    pyth_spot: u64,
    block_scholes_spot: u64,
    block_scholes_forward: u64,
    svi_a: u64,
    svi_a_is_negative: bool,
    svi_b: u64,
    svi_sigma: u64,
    svi_rho_magnitude: u64,
    svi_rho_is_negative: bool,
    svi_m_magnitude: u64,
    svi_m_is_negative: bool,
    source_timestamp_ms: u64,
): SurfaceProfile {
    SurfaceProfile {
        pyth_spot,
        block_scholes_spot,
        block_scholes_forward,
        svi_a,
        svi_a_is_negative,
        svi_b,
        svi_sigma,
        svi_rho_magnitude,
        svi_rho_is_negative,
        svi_m_magnitude,
        svi_m_is_negative,
        source_timestamp_ms,
    }
}

public fun smoke(): SurfaceProfile {
    smoke_at(SMOKE_SOURCE_TIMESTAMP_MS)
}

public fun smoke_at(source_timestamp_ms: u64): SurfaceProfile {
    new(
        SMOKE_SPOT,
        SMOKE_SPOT,
        SMOKE_SPOT,
        SMOKE_SVI_A,
        false,
        SMOKE_SVI_B,
        SMOKE_SVI_SIGMA,
        SMOKE_SVI_RHO_MAGNITUDE,
        false,
        SMOKE_SVI_M_MAGNITUDE,
        false,
        source_timestamp_ms,
    )
}

public fun exact_half(): SurfaceProfile {
    exact_half_at(SMOKE_SOURCE_TIMESTAMP_MS)
}

public fun exact_half_at(source_timestamp_ms: u64): SurfaceProfile {
    new(
        SMOKE_SPOT,
        SMOKE_SPOT,
        SMOKE_SPOT,
        EXACT_HALF_SVI_A,
        false,
        0,
        EXACT_HALF_SVI_SIGMA,
        0,
        false,
        0,
        false,
        source_timestamp_ms,
    )
}

public fun pyth_spot(profile: &SurfaceProfile): u64 { profile.pyth_spot }

public fun block_scholes_spot(profile: &SurfaceProfile): u64 { profile.block_scholes_spot }

public fun block_scholes_forward(profile: &SurfaceProfile): u64 { profile.block_scholes_forward }

public fun svi_a(profile: &SurfaceProfile): u64 { profile.svi_a }

public fun svi_a_is_negative(profile: &SurfaceProfile): bool { profile.svi_a_is_negative }

public fun svi_b(profile: &SurfaceProfile): u64 { profile.svi_b }

public fun svi_sigma(profile: &SurfaceProfile): u64 { profile.svi_sigma }

public fun svi_rho_magnitude(profile: &SurfaceProfile): u64 { profile.svi_rho_magnitude }

public fun svi_rho_is_negative(profile: &SurfaceProfile): bool { profile.svi_rho_is_negative }

public fun svi_m_magnitude(profile: &SurfaceProfile): u64 { profile.svi_m_magnitude }

public fun svi_m_is_negative(profile: &SurfaceProfile): bool { profile.svi_m_is_negative }

public fun source_timestamp_ms(profile: &SurfaceProfile): u64 { profile.source_timestamp_ms }
