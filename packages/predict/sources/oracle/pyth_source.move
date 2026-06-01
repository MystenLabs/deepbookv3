// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Raw Pyth Lazer spot source state.
///
/// This module is intentionally limited to source ingestion and timestamp
/// bookkeeping. It does not decide whether Pyth is authoritative, derive a
/// forward, apply circuit breakers, or settle a market.
module deepbook_predict::pyth_source;

use deepbook_predict::{
    admin::AdminCap,
    config_constants,
    config_events,
    constants,
    lazer_helper,
    oracle_events,
    protocol_config::ProtocolConfig
};
use pyth_lazer::update::Update as LazerUpdate;
use sui::{clock::Clock, vec_set::VecSet};

const EStaleSourceUpdate: u64 = 0;
const EZeroSpot: u64 = 1;
const EFutureSourceUpdate: u64 = 2;
const EPackageVersionDisabled: u64 = 3;

/// Latest normalized spot observed from one Pyth Lazer feed.
public struct PythSource has key {
    id: UID,
    feed_id: u32,
    spot: u64,
    /// Pyth publisher timestamp from the latest accepted update, in milliseconds.
    source_timestamp_ms: u64,
    /// On-chain timestamp when the latest accepted update landed.
    update_timestamp_ms: u64,
    /// Mirror of `ProtocolConfig.allowed_versions`; synced permissionlessly.
    allowed_versions: VecSet<u64>,
    /// Final window (ms before expiry) over which the trade fee ramps up for this
    /// asset's markets; 0 disables the ramp. Per-asset so more volatile assets can
    /// use a larger ramp. Applied in `pricing::expiry_fee_multiplier`.
    expiry_fee_window_ms: u64,
    /// Fee multiplier reached at expiry, in FLOAT_SCALING. 1x disables the ramp;
    /// larger values suit more volatile assets.
    expiry_fee_max_multiplier: u64,
}

/// Decode and store a verified Pyth Lazer spot update.
///
/// Aborts during valuation, rejects stale/future source timestamps, and stores
/// both the publisher timestamp and on-chain landing timestamp.
public fun update_from_lazer(
    source: &mut PythSource,
    config: &ProtocolConfig,
    update: LazerUpdate,
    clock: &Clock,
) {
    source.assert_version_allowed();
    config.assert_not_valuation_in_progress();
    let (spot, source_timestamp_us) = lazer_helper::extract_spot(&update, source.feed_id);
    let source_timestamp_ms = us_to_ms_ceil(source_timestamp_us);
    let update_timestamp_ms = clock.timestamp_ms();

    assert!(spot > 0, EZeroSpot);
    assert!(source_timestamp_ms > source.source_timestamp_ms, EStaleSourceUpdate);
    assert!(source_timestamp_ms <= update_timestamp_ms, EFutureSourceUpdate);

    source.spot = spot;
    source.source_timestamp_ms = source_timestamp_ms;
    source.update_timestamp_ms = update_timestamp_ms;
    oracle_events::emit_pyth_source_updated(
        source.id(),
        source.feed_id,
        spot,
        source_timestamp_ms,
        update_timestamp_ms,
    );
}

/// Return the Pyth source object ID.
public fun id(source: &PythSource): ID {
    source.id.to_inner()
}

/// Return the configured Pyth Lazer feed id.
public fun feed_id(source: &PythSource): u32 {
    source.feed_id
}

/// Return the latest normalized spot in Predict's 1e9 price scaling.
public fun spot(source: &PythSource): u64 {
    source.spot
}

/// Return Pyth's source timestamp from the latest accepted update, in milliseconds.
public fun source_timestamp_ms(source: &PythSource): u64 {
    source.source_timestamp_ms
}

/// Return the on-chain timestamp when the latest update landed.
public fun update_timestamp_ms(source: &PythSource): u64 {
    source.update_timestamp_ms
}

/// Return this source's mirrored set of allowed package versions.
public fun allowed_versions(source: &PythSource): VecSet<u64> {
    source.allowed_versions
}

/// Return the trade-fee ramp window (ms before expiry) for this asset's markets.
public fun expiry_fee_window_ms(source: &PythSource): u64 {
    source.expiry_fee_window_ms
}

/// Return the trade-fee multiplier reached at expiry for this asset's markets.
public fun expiry_fee_max_multiplier(source: &PythSource): u64 {
    source.expiry_fee_max_multiplier
}

/// Set the trade-fee ramp parameters for this asset's markets. Window 0 or
/// multiplier 1x disables the ramp.
public fun set_expiry_fee_params(
    source: &mut PythSource,
    _admin_cap: &AdminCap,
    window_ms: u64,
    max_multiplier: u64,
) {
    config_constants::assert_expiry_fee_window_ms(window_ms);
    config_constants::assert_expiry_fee_max_multiplier(max_multiplier);
    source.expiry_fee_window_ms = window_ms;
    source.expiry_fee_max_multiplier = max_multiplier;
    config_events::emit_pyth_source_expiry_fee_params_updated(
        source.id(),
        source.feed_id,
        window_ms,
        max_multiplier,
    );
}

// === Public-Package Functions ===

/// Overwrite this source's mirrored `allowed_versions`. The only authorized
/// caller is `registry::sync_pyth_source_allowed_versions`, which reads the
/// source of truth from `Registry`.
public(package) fun set_allowed_versions(source: &mut PythSource, allowed_versions: VecSet<u64>) {
    source.allowed_versions = allowed_versions;
}

/// Return the timestamp that pricing can use for freshness checks.
public(package) fun freshness_timestamp_ms(source: &PythSource): u64 {
    source.source_timestamp_ms.min(source.update_timestamp_ms)
}

/// Create and share a Pyth source bound to a Lazer feed id with the per-asset
/// expiry-fee ramp configured up front.
public(package) fun create_and_share(
    feed_id: u32,
    allowed_versions: VecSet<u64>,
    expiry_fee_window_ms: u64,
    expiry_fee_max_multiplier: u64,
    ctx: &mut TxContext,
): ID {
    config_constants::assert_expiry_fee_window_ms(expiry_fee_window_ms);
    config_constants::assert_expiry_fee_max_multiplier(expiry_fee_max_multiplier);
    let source = PythSource {
        id: object::new(ctx),
        feed_id,
        spot: 0,
        source_timestamp_ms: 0,
        update_timestamp_ms: 0,
        allowed_versions,
        expiry_fee_window_ms,
        expiry_fee_max_multiplier,
    };
    let id = source.id();
    transfer::share_object(source);
    id
}

/// Abort if the running package version is not allowed for this source.
public(package) fun assert_version_allowed(source: &PythSource) {
    assert!(
        source.allowed_versions.contains(&constants::current_version!()),
        EPackageVersionDisabled,
    );
}

fun us_to_ms_ceil(timestamp_us: u64): u64 {
    let ms = timestamp_us / 1000;
    if (timestamp_us % 1000 == 0) ms else ms + 1
}

// === Test-Only Functions ===

#[test_only]
public fun new_for_testing(ctx: &mut TxContext): PythSource {
    PythSource {
        id: object::new(ctx),
        feed_id: 0,
        spot: 0,
        source_timestamp_ms: 0,
        update_timestamp_ms: 0,
        allowed_versions: sui::vec_set::singleton(constants::current_version!()),
        expiry_fee_window_ms: deepbook_predict::test_constants::default_expiry_fee_window_ms!(),
        expiry_fee_max_multiplier: deepbook_predict::test_constants::default_expiry_fee_max_multiplier!(),
    }
}

/// Drive spot and timestamps directly without going through `update_from_lazer`
/// (which needs a `pyth_lazer::Update` that has no Move-side test constructor).
/// Used by oracle settlement tests that need a "Pyth has fresh post-expiry data"
/// state.
#[test_only]
public fun set_state_for_testing(
    source: &mut PythSource,
    spot: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
) {
    source.spot = spot;
    source.source_timestamp_ms = source_timestamp_ms;
    source.update_timestamp_ms = update_timestamp_ms;
}
