// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Events emitted by `block_scholes_feed`: feed creation and per-expiry surface
/// (spot + forward + SVI) updates. The surface event carries both the publisher
/// snapshot timestamp and the on-chain landing timestamp because they are genuinely
/// different values used for freshness. Spot is per-expiry, so it rides on the
/// surface event rather than a separate global-spot event.
module propbook::block_scholes_feed_events;

use fixed_math::i64::I64;
use sui::event;

/// Emitted when a new BS feed is created and shared.
public struct BlockScholesFeedCreated has copy, drop {
    block_scholes_feed_id: ID,
    underlying: u32,
}

/// Emitted for each expiry surface (spot + forward + SVI) written by an accepted
/// update.
public struct BlockScholesSurfaceUpdated has copy, drop {
    block_scholes_feed_id: ID,
    expiry_ms: u64,
    spot: u64,
    forward: u64,
    svi_a: u64,
    svi_b: u64,
    svi_rho: I64,
    svi_m: I64,
    svi_sigma: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
}

// === Public-Package Functions ===

public(package) fun emit_block_scholes_feed_created(underlying: u32, block_scholes_feed_id: ID) {
    event::emit(BlockScholesFeedCreated { block_scholes_feed_id, underlying });
}

public(package) fun emit_block_scholes_surface_updated(
    block_scholes_feed_id: ID,
    expiry_ms: u64,
    spot: u64,
    forward: u64,
    svi_a: u64,
    svi_b: u64,
    svi_rho: I64,
    svi_m: I64,
    svi_sigma: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
) {
    event::emit(BlockScholesSurfaceUpdated {
        block_scholes_feed_id,
        expiry_ms,
        spot,
        forward,
        svi_a,
        svi_b,
        svi_rho,
        svi_m,
        svi_sigma,
        source_timestamp_ms,
        update_timestamp_ms,
    });
}
