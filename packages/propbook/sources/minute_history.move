// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unbounded minute-bucket price history: records the *first* tick whose
/// publisher (source) timestamp falls in each rounded UTC minute.
///
/// Deliberately generic and feed-agnostic — it stores a spot plus the two
/// timestamps only and references nothing feed-specific, so copying it into
/// another feed package only requires repointing the `constants` import.
/// Bucketing on source (real-world price) time rather than on-chain landing time
/// is intentional: a future settlement reads the price at a specific real-world
/// minute.
module propbook::minute_history;

use propbook::constants;
use sui::table::{Self, Table};

const EMinuteNotFound: u64 = 0;

/// One accepted tick: its spot plus the publisher and on-chain landing times.
public struct DataPoint has copy, drop, store {
    /// Spot in 1e9 price scaling.
    spot: u64,
    /// Publisher timestamp, in milliseconds.
    source_timestamp_ms: u64,
    /// On-chain landing timestamp.
    update_timestamp_ms: u64,
}

/// First-wins minute buckets keyed by `(source_ts / 60_000) * 60_000`. The table
/// is intentionally unbounded: its entries are off-object dynamic fields, so
/// growth keeps `add`/`borrow` O(1) and never bloats the owning `PythFeed`; only
/// the cumulative storage deposit grows, borne by the permissionless updaters. A
/// permissionless `prune_before(minute)` can be added later if needed.
public struct MinuteHistory has store {
    buckets: Table<u64, DataPoint>,
}

/// Spot of this data point, in 1e9 price scaling.
public fun spot(point: &DataPoint): u64 {
    point.spot
}

/// Publisher timestamp of this data point, in milliseconds.
public fun source_timestamp_ms(point: &DataPoint): u64 {
    point.source_timestamp_ms
}

/// On-chain landing timestamp of this data point.
public fun update_timestamp_ms(point: &DataPoint): u64 {
    point.update_timestamp_ms
}

/// Data point recorded for `minute_ms`'s bucket. Aborts `EMinuteNotFound` if the
/// minute was never recorded (mirrors `Table::borrow`); use `has_minute` to check
/// first. `minute_ms` is rounded the same way `record` rounds, so an unrounded
/// query timestamp still hits its bucket.
public fun price_at_minute(self: &MinuteHistory, minute_ms: u64): DataPoint {
    let bucket = round_to_minute(minute_ms);
    assert!(self.buckets.contains(bucket), EMinuteNotFound);
    *self.buckets.borrow(bucket)
}

/// Whether a tick was recorded for `minute_ms`'s bucket.
public fun has_minute(self: &MinuteHistory, minute_ms: u64): bool {
    self.buckets.contains(round_to_minute(minute_ms))
}

// === Public-Package Functions ===

public(package) fun new(ctx: &mut TxContext): MinuteHistory {
    MinuteHistory { buckets: table::new(ctx) }
}

public(package) fun new_data_point(
    spot: u64,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
): DataPoint {
    DataPoint { spot, source_timestamp_ms, update_timestamp_ms }
}

/// Record `point` into its rounded minute bucket. First-wins: a minute already
/// present is a no-op, so re-pushes within one minute are idempotent.
public(package) fun record(self: &mut MinuteHistory, point: DataPoint) {
    let bucket = round_to_minute(point.source_timestamp_ms);
    if (!self.buckets.contains(bucket)) self.buckets.add(bucket, point);
}

// === Private Functions ===

fun round_to_minute(timestamp_ms: u64): u64 {
    (timestamp_ms / constants::minute_ms!()) * constants::minute_ms!()
}
