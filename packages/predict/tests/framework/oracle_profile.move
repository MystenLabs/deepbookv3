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

/// The three price inputs: Pyth spot plus the Block Scholes spot/forward pair.
public struct SpotPrices has copy, drop {
    pyth_spot: u64,
    block_scholes_spot: u64,
    block_scholes_forward: u64,
}

/// The signed SVI surface parameters, seeded as one block by `seed_bs_svi`.
/// Signed fields travel as magnitude/sign pairs matching the feed update wire.
public struct SviParams has copy, drop {
    a: u64,
    a_is_negative: bool,
    b: u64,
    sigma: u64,
    rho_magnitude: u64,
    rho_is_negative: bool,
    m_magnitude: u64,
    m_is_negative: bool,
}

public struct SurfaceProfile has copy, drop {
    prices: SpotPrices,
    svi: SviParams,
    source_timestamp_ms: u64,
}

public fun new(prices: SpotPrices, svi: SviParams, source_timestamp_ms: u64): SurfaceProfile {
    SurfaceProfile { prices, svi, source_timestamp_ms }
}

public fun spot_prices(
    pyth_spot: u64,
    block_scholes_spot: u64,
    block_scholes_forward: u64,
): SpotPrices {
    SpotPrices { pyth_spot, block_scholes_spot, block_scholes_forward }
}

public fun svi_params(
    a: u64,
    a_is_negative: bool,
    b: u64,
    sigma: u64,
    rho_magnitude: u64,
    rho_is_negative: bool,
    m_magnitude: u64,
    m_is_negative: bool,
): SviParams {
    SviParams {
        a,
        a_is_negative,
        b,
        sigma,
        rho_magnitude,
        rho_is_negative,
        m_magnitude,
        m_is_negative,
    }
}

public fun smoke(): SurfaceProfile {
    smoke_at(SMOKE_SOURCE_TIMESTAMP_MS)
}

public fun smoke_at(source_timestamp_ms: u64): SurfaceProfile {
    new(
        spot_prices(SMOKE_SPOT, SMOKE_SPOT, SMOKE_SPOT),
        svi_params(
            SMOKE_SVI_A,
            false,
            SMOKE_SVI_B,
            SMOKE_SVI_SIGMA,
            SMOKE_SVI_RHO_MAGNITUDE,
            false,
            SMOKE_SVI_M_MAGNITUDE,
            false,
        ),
        source_timestamp_ms,
    )
}

public fun exact_half(): SurfaceProfile {
    exact_half_at(SMOKE_SOURCE_TIMESTAMP_MS)
}

public fun exact_half_at(source_timestamp_ms: u64): SurfaceProfile {
    new(
        spot_prices(SMOKE_SPOT, SMOKE_SPOT, SMOKE_SPOT),
        svi_params(EXACT_HALF_SVI_A, false, 0, EXACT_HALF_SVI_SIGMA, 0, false, 0, false),
        source_timestamp_ms,
    )
}

public fun pyth_spot(profile: &SurfaceProfile): u64 { profile.prices.pyth_spot }

public fun block_scholes_spot(profile: &SurfaceProfile): u64 { profile.prices.block_scholes_spot }

public fun block_scholes_forward(profile: &SurfaceProfile): u64 {
    profile.prices.block_scholes_forward
}

public fun svi_a(profile: &SurfaceProfile): u64 { profile.svi.a }

public fun svi_a_is_negative(profile: &SurfaceProfile): bool { profile.svi.a_is_negative }

public fun svi_b(profile: &SurfaceProfile): u64 { profile.svi.b }

public fun svi_sigma(profile: &SurfaceProfile): u64 { profile.svi.sigma }

public fun svi_rho_magnitude(profile: &SurfaceProfile): u64 { profile.svi.rho_magnitude }

public fun svi_rho_is_negative(profile: &SurfaceProfile): bool { profile.svi.rho_is_negative }

public fun svi_m_magnitude(profile: &SurfaceProfile): u64 { profile.svi.m_magnitude }

public fun svi_m_is_negative(profile: &SurfaceProfile): bool { profile.svi.m_is_negative }

public fun source_timestamp_ms(profile: &SurfaceProfile): u64 { profile.source_timestamp_ms }
