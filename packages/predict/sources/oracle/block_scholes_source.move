// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Raw Block Scholes source state for Predict binary markets.
///
/// This module stores Block Scholes' latest spot/forward pair and SVI surface
/// with both source-data timestamps and on-chain update timestamps. It does
/// not decide whether these values are canonical for pricing.
module deepbook_predict::block_scholes_source;

use deepbook::math;
use deepbook_predict::i64;
use sui::clock::Clock;

const EZeroSpot: u64 = 0;
const EZeroForward: u64 = 1;
const EStalePriceSourceUpdate: u64 = 2;
const EStaleSVISourceUpdate: u64 = 3;
const EInvalidBlockScholesSourceCap: u64 = 4;

/// SVI volatility surface parameters supplied by Block Scholes.
public struct SVIParams has copy, drop, store {
    a: u64,
    b: u64,
    rho: i64::I64,
    m: i64::I64,
    sigma: u64,
}

/// Capability authorized to update one Block Scholes source.
public struct BlockScholesSourceCap has key, store {
    id: UID,
}

/// Latest Block Scholes source state.
public struct BlockScholesSource has copy, drop, store {
    authorized_cap_id: ID,
    spot: u64,
    forward: u64,
    basis: u64,
    price_source_timestamp_ms: u64,
    price_update_timestamp_ms: u64,
    svi: SVIParams,
    svi_source_timestamp_ms: u64,
    svi_update_timestamp_ms: u64,
}

// === Public Functions ===

/// Create a new SVI parameter set.
public fun new_svi_params(a: u64, b: u64, rho: i64::I64, m: i64::I64, sigma: u64): SVIParams {
    SVIParams { a, b, rho, m, sigma }
}

/// Create an empty Block Scholes source bound to an update cap.
public fun new(cap: &BlockScholesSourceCap): BlockScholesSource {
    BlockScholesSource {
        authorized_cap_id: cap.id.to_inner(),
        spot: 0,
        forward: 0,
        basis: 0,
        price_source_timestamp_ms: 0,
        price_update_timestamp_ms: 0,
        svi: SVIParams {
            a: 0,
            b: 0,
            rho: i64::zero(),
            m: i64::zero(),
            sigma: 0,
        },
        svi_source_timestamp_ms: 0,
        svi_update_timestamp_ms: 0,
    }
}

/// Store a Block Scholes spot/forward pair and derive its basis.
public fun update_prices(
    source: &mut BlockScholesSource,
    cap: &BlockScholesSourceCap,
    spot: u64,
    forward: u64,
    source_timestamp_ms: u64,
    clock: &Clock,
) {
    source.assert_authorized_cap(cap);
    assert!(spot > 0, EZeroSpot);
    assert!(forward > 0, EZeroForward);
    assert!(
        source_timestamp_ms > source.price_source_timestamp_ms,
        EStalePriceSourceUpdate,
    );

    source.spot = spot;
    source.forward = forward;
    source.basis = math::div(forward, spot);
    source.price_source_timestamp_ms = source_timestamp_ms;
    source.price_update_timestamp_ms = clock.timestamp_ms();
}

/// Store a Block Scholes SVI surface update.
public fun update_svi(
    source: &mut BlockScholesSource,
    cap: &BlockScholesSourceCap,
    svi: SVIParams,
    source_timestamp_ms: u64,
    clock: &Clock,
) {
    source.assert_authorized_cap(cap);
    assert!(source_timestamp_ms > source.svi_source_timestamp_ms, EStaleSVISourceUpdate);
    source.svi = svi;
    source.svi_source_timestamp_ms = source_timestamp_ms;
    source.svi_update_timestamp_ms = clock.timestamp_ms();
}

/// Return the cap ID authorized for this source.
public fun authorized_cap_id(source: &BlockScholesSource): ID {
    source.authorized_cap_id
}

/// Return the ID of a Block Scholes source cap.
public fun cap_id(cap: &BlockScholesSourceCap): ID {
    cap.id.to_inner()
}

/// Return the latest Block Scholes spot.
public fun spot(source: &BlockScholesSource): u64 {
    source.spot
}

/// Return the latest Block Scholes forward.
public fun forward(source: &BlockScholesSource): u64 {
    source.forward
}

/// Return the latest Block Scholes basis (`forward / spot`).
public fun basis(source: &BlockScholesSource): u64 {
    source.basis
}

/// Return the source-data timestamp for the latest price update.
public fun price_source_timestamp_ms(source: &BlockScholesSource): u64 {
    source.price_source_timestamp_ms
}

/// Return the on-chain timestamp when the latest price update landed.
public fun price_update_timestamp_ms(source: &BlockScholesSource): u64 {
    source.price_update_timestamp_ms
}

/// Return the latest Block Scholes SVI parameters.
public fun svi(source: &BlockScholesSource): SVIParams {
    source.svi
}

/// Return the SVI `a` parameter.
public fun svi_a(svi: &SVIParams): u64 {
    svi.a
}

/// Return the SVI `b` parameter.
public fun svi_b(svi: &SVIParams): u64 {
    svi.b
}

/// Return the signed SVI `rho` parameter.
public fun svi_rho(svi: &SVIParams): i64::I64 {
    svi.rho
}

/// Return the signed SVI `m` parameter.
public fun svi_m(svi: &SVIParams): i64::I64 {
    svi.m
}

/// Return the SVI `sigma` parameter.
public fun svi_sigma(svi: &SVIParams): u64 {
    svi.sigma
}

/// Return the source-data timestamp for the latest SVI update.
public fun svi_source_timestamp_ms(source: &BlockScholesSource): u64 {
    source.svi_source_timestamp_ms
}

/// Return the on-chain timestamp when the latest SVI update landed.
public fun svi_update_timestamp_ms(source: &BlockScholesSource): u64 {
    source.svi_update_timestamp_ms
}

// === Public-Package Functions ===

/// Create a new Block Scholes source update cap.
public(package) fun create_cap(ctx: &mut TxContext): BlockScholesSourceCap {
    BlockScholesSourceCap { id: object::new(ctx) }
}

// === Private Functions ===

/// Abort unless `cap` is authorized to update this source.
fun assert_authorized_cap(source: &BlockScholesSource, cap: &BlockScholesSourceCap) {
    assert!(
        source.authorized_cap_id == cap.id.to_inner(),
        EInvalidBlockScholesSourceCap,
    );
}
