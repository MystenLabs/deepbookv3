// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Unbounded observation history. Stores:
/// - the first accepted on-chain observation this feed sees for that source
///   minute, keyed by rounded UTC minute, and
/// - optional official settlement observations keyed by exact resolution
///   timestamp.
///
/// Deliberately generic and feed-agnostic: each oracle lane chooses its own
/// observation type and passes the timestamp used for each write.
/// First-observed bucketing uses source (real-world price) time rather than
/// on-chain landing time. Official settlement storage uses the exact resolution
/// timestamp derived from the source update.
module propbook::observation_history;

use propbook::constants;
use sui::table::{Self, Table};

const EObservationNotFound: u64 = 0;
const EOfficialSettlementAlreadyExists: u64 = 1;

/// First-observed buckets are keyed by `(source_timestamp_ms / 60_000) * 60_000`.
/// Official settlement entries are keyed by exact `resolution_timestamp_ms`.
/// The tables are intentionally unbounded: their entries are off-object dynamic
/// fields, so growth keeps `add`/`borrow` O(1) and never bloats the owning feed
/// object; only the cumulative storage deposit grows. A permissionless
/// `prune_before(timestamp)` can be added later if needed.
public struct ObservationHistory<phantom Observation: copy + drop + store> has store {
    first_observed_minutes: Table<u64, Observation>,
    official_settlements: Table<u64, Observation>,
}

/// First-observed update recorded for `minute_ms`'s bucket. Aborts
/// `EObservationNotFound` if the minute was never recorded (mirrors `Table::borrow`);
/// use `has_observation` to check first. `minute_ms` is rounded the same way
/// `record_first_observed` rounds, so an unrounded query timestamp still hits
/// its bucket.
public fun observation_at_minute<Observation: copy + drop + store>(
    self: &ObservationHistory<Observation>,
    minute_ms: u64,
): Observation {
    let bucket = round_to_minute(minute_ms);
    assert!(self.first_observed_minutes.contains(bucket), EObservationNotFound);
    *self.first_observed_minutes.borrow(bucket)
}

/// Whether this feed has a first-observed update for `minute_ms`'s bucket.
public fun has_observation<Observation: copy + drop + store>(
    self: &ObservationHistory<Observation>,
    minute_ms: u64,
): bool {
    self.first_observed_minutes.contains(round_to_minute(minute_ms))
}

/// Official settlement observation recorded for exact `resolution_timestamp_ms`.
/// Aborts `EObservationNotFound` if the official settlement timestamp was never
/// recorded.
public fun official_observation_at_resolution<Observation: copy + drop + store>(
    self: &ObservationHistory<Observation>,
    resolution_timestamp_ms: u64,
): Observation {
    assert!(self.official_settlements.contains(resolution_timestamp_ms), EObservationNotFound);
    *self.official_settlements.borrow(resolution_timestamp_ms)
}

/// Whether this feed has an official settlement observation for exact
/// `resolution_timestamp_ms`.
public fun has_official_settlement<Observation: copy + drop + store>(
    self: &ObservationHistory<Observation>,
    resolution_timestamp_ms: u64,
): bool {
    self.official_settlements.contains(resolution_timestamp_ms)
}

// === Public-Package Functions ===

public(package) fun new<Observation: copy + drop + store>(
    ctx: &mut TxContext,
): ObservationHistory<Observation> {
    ObservationHistory {
        first_observed_minutes: table::new(ctx),
        official_settlements: table::new(ctx),
    }
}

/// Record `observation` into its rounded source-minute bucket if the bucket is
/// empty. A present bucket is final and untouched: the first accepted on-chain
/// transaction wins for that source minute, and later updates in the same bucket
/// do not backfill or replace it.
public(package) fun record_first_observed<Observation: copy + drop + store>(
    self: &mut ObservationHistory<Observation>,
    source_timestamp_ms: u64,
    observation: Observation,
) {
    let bucket = round_to_minute(source_timestamp_ms);
    if (!self.first_observed_minutes.contains(bucket)) {
        self.first_observed_minutes.add(bucket, observation)
    };
}

/// Record an official settlement observation at exact `resolution_timestamp_ms`.
/// Official settlement timestamps are write-once: corrections must be a future
/// explicit governance flow, not an accidental overwrite in the normal
/// settlement path.
public(package) fun record_official_settlement<Observation: copy + drop + store>(
    self: &mut ObservationHistory<Observation>,
    resolution_timestamp_ms: u64,
    observation: Observation,
) {
    assert!(
        !self.official_settlements.contains(resolution_timestamp_ms),
        EOfficialSettlementAlreadyExists,
    );
    self.official_settlements.add(resolution_timestamp_ms, observation);
}

// === Private Functions ===

fun round_to_minute(timestamp_ms: u64): u64 {
    (timestamp_ms / constants::minute_ms!()) * constants::minute_ms!()
}
