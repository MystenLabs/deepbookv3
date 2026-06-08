// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Raw Pyth Lazer spot source state.
///
/// This module is intentionally limited to source ingestion, timestamp
/// bookkeeping, and reading its raw spot (including a plain units conversion of
/// that spot via `value_in_dusdc`). It does not decide whether Pyth is
/// authoritative, derive a forward, apply circuit breakers, or settle a market;
/// callers own feed binding and freshness (see `pricing::assert_pyth_spot_fresh`).
module deepbook_predict::pyth_source;

use deepbook_predict::{constants, oracle_events, protocol_config::ProtocolConfig};
use predict_math::math;
use pyth_lazer::{i16::I16 as LazerI16, i64::I64 as LazerI64, update::Update as LazerUpdate};
use sui::{clock::Clock, vec_set::VecSet};

const EStaleSourceUpdate: u64 = 0;
const EZeroSpot: u64 = 1;
const EFutureSourceUpdate: u64 = 2;
const EPackageVersionDisabled: u64 = 3;
const ELazerFeedNotFound: u64 = 4;
const ELazerPriceUnavailable: u64 = 5;
const ELazerNegativePrice: u64 = 6;

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
    let (spot, source_timestamp_us) = extract_spot(&update, source.feed_id);
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

// === Public-Package Functions ===

/// Return the timestamp that pricing can use for freshness checks.
public(package) fun freshness_timestamp_ms(source: &PythSource): u64 {
    source.source_timestamp_ms.min(source.update_timestamp_ms)
}

/// DUSDC-denominated value (DUSDC decimals) of `amount` raw units of an asset
/// with `asset_decimals`, priced at this source's normalized 1e9-scaled spot,
/// rounding up:
///   ceil(amount * spot / 10^(asset_decimals + float_scaling_decimals - dusdc_decimals))
/// Aborts on a zero spot (a zero oracle price cannot value the asset). Feed
/// binding and freshness are the caller's responsibility (assert `feed_id()` and
/// `pricing::assert_pyth_spot_fresh`), exactly as the market pricing path does.
public(package) fun value_in_dusdc(source: &PythSource, amount: u64, asset_decimals: u8): u64 {
    let spot = source.spot;
    assert!(spot > 0, EZeroSpot);
    // asset_decimals + 9 - 6 >= 3 for any decimals, so no underflow.
    let exponent =
        (asset_decimals as u64) + constants::float_scaling_decimals!() - (constants::dusdc_decimals!() as u64);
    // Valid asset-decimals/price inputs keep the DUSDC value within u64; the VM abort is the out-of-domain backstop.
    ceil_div((amount as u128) * (spot as u128), pow10(exponent)) as u64
}

/// Overwrite this source's mirrored `allowed_versions`. The only authorized
/// caller is `registry::sync_pyth_source_allowed_versions`, which reads the
/// source of truth from `Registry`.
public(package) fun set_allowed_versions(source: &mut PythSource, allowed_versions: VecSet<u64>) {
    source.allowed_versions = allowed_versions;
}

/// Create and share a Pyth source bound to a Lazer feed id.
public(package) fun create_and_share(
    feed_id: u32,
    allowed_versions: VecSet<u64>,
    ctx: &mut TxContext,
): ID {
    let source = PythSource {
        id: object::new(ctx),
        feed_id,
        spot: 0,
        source_timestamp_ms: 0,
        update_timestamp_ms: 0,
        allowed_versions,
    };
    let id = source.id();
    transfer::share_object(source);
    id
}

/// Abort if the running package version is not allowed for this source.
fun assert_version_allowed(source: &PythSource) {
    assert!(
        source.allowed_versions.contains(&constants::current_version!()),
        EPackageVersionDisabled,
    );
}

fun us_to_ms_ceil(timestamp_us: u64): u64 {
    let ms = timestamp_us / 1000;
    if (timestamp_us % 1000 == 0) ms else ms + 1
}

fun pow10(exponent: u64): u128 {
    10u128.pow(exponent as u8)
}

fun ceil_div(numerator: u128, denominator: u128): u128 {
    (numerator + denominator - 1) / denominator
}

// === Lazer decode (folded in from the former lazer_helper module) ===

/// Decode `feed_id`'s spot out of a verified Lazer `Update`. Returns
/// `(spot_1e9, lazer_published_at_us)`. Aborts if the feed is missing,
/// the price/exponent is unavailable, or the price is negative.
fun extract_spot(update: &LazerUpdate, feed_id: u32): (u64, u64) {
    let lazer_published_at_us = update.timestamp();
    let feeds = update.feeds_ref();
    let idx_opt = feeds.find_index!(|f| f.feed_id() == feed_id);
    assert!(idx_opt.is_some(), ELazerFeedNotFound);
    let feed = &feeds[idx_opt.destroy_some()];

    // Both Option layers must be Some: the field must exist in the update,
    // and the value must be present (Lazer returns None if there are not
    // enough publishers).
    let price_outer = feed.price();
    assert!(price_outer.is_some(), ELazerPriceUnavailable);
    let price_inner = price_outer.borrow();
    assert!(price_inner.is_some(), ELazerPriceUnavailable);
    let price = *price_inner.borrow();

    let exp_outer = feed.exponent();
    assert!(exp_outer.is_some(), ELazerPriceUnavailable);
    let exponent = *exp_outer.borrow();

    (normalize_pyth_price(price, exponent), lazer_published_at_us)
}

/// Convert a Pyth Lazer `(price, exponent)` pair to the predict package's
/// 1e9-scaled u64. Target scaling is `price_1e9 = magnitude * 10^(exponent + 9)`.
/// Aborts on negative price (crypto spot is always positive). Shift bounds are
/// enforced inside `math::pow10` (real feeds use exponents in [-12, -4]).
fun normalize_pyth_price(price: LazerI64, exponent: LazerI16): u64 {
    assert!(!price.get_is_negative(), ELazerNegativePrice);
    let magnitude = price.get_magnitude_if_positive();

    let exp_is_neg = exponent.get_is_negative();
    let exp_mag = if (exp_is_neg) {
        exponent.get_magnitude_if_negative() as u64
    } else {
        exponent.get_magnitude_if_positive() as u64
    };

    let target = constants::float_scaling_decimals!();

    if (exp_is_neg) {
        if (exp_mag <= target) {
            scale_up(magnitude, target - exp_mag)
        } else {
            magnitude / math::pow10(exp_mag - target)
        }
    } else {
        scale_up(magnitude, target + exp_mag)
    }
}

fun scale_up(magnitude: u64, shift: u64): u64 {
    let factor = math::pow10(shift);
    magnitude * factor
}

// === Test-Only Functions ===

// `new_for_testing` removed: tests create the real source via
// `registry::create_pyth_source` before `supply`, so no zero-valued placeholder
// PythSource is needed.

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
