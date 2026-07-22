// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Stores one advancing latest observation and an independent insert-only exact-timestamp history for a Propbook feed.
/// `source_timestamp_ms` is the canonical ordering, freshness, and exact-history key; source adapters may retain richer native timestamps inside the payload.
/// Latest updates ignore invalid or non-advancing timestamps, while exact inserts ignore invalid or previously occupied keys without changing the latest value.
module propbook::oracle_lane;

use sui::{event, table::{Self, Table}};

/// A source value paired with its source publication time and on-chain recording time.
/// Raw and normalized projections preserve this envelope so consumers can apply one freshness policy.
public struct OracleRead<Value: copy + drop + store> has copy, drop, store {
    /// Source publication time in Unix milliseconds and the key used for exact reads.
    source_timestamp_ms: u64,
    /// Sui clock time in Unix milliseconds when the update transaction executed.
    update_timestamp_ms: u64,
    value: Value,
}

/// Latest and exact-timestamp storage for one feed stream.
public struct OracleLane<Payload: copy + drop + store> has store {
    /// Most recent valid source observation submitted through `update`.
    latest: Option<OracleRead<Payload>>,
    /// First accepted observation at each exact source timestamp; entries are never overwritten.
    exact_reads: Table<u64, OracleRead<Payload>>,
}

/// Emitted when a feed accepts a source-native observation into its live oracle
/// state.
public struct ObservationRecorded<Observation: copy + drop> has copy, drop {
    propbook_oracle_id: ID,
    observation: Observation,
}

/// Emitted when a feed inserts source-native data keyed by exact source
/// timestamp.
public struct ObservationInserted<Observation: copy + drop> has copy, drop {
    propbook_oracle_id: ID,
    observation: Observation,
}

// === Read Functions ===

// External inspection and feed adapters use these accessors without depending on the envelope's field layout.

public fun read_source_timestamp_ms<Value: copy + drop + store>(read: &OracleRead<Value>): u64 {
    read.source_timestamp_ms
}

public fun read_update_timestamp_ms<Value: copy + drop + store>(read: &OracleRead<Value>): u64 {
    read.update_timestamp_ms
}

public fun read_value<Value: copy + drop + store>(read: &OracleRead<Value>): Value {
    read.value
}

// === Public-Package Read Functions ===

public(package) fun latest_read<Payload: copy + drop + store>(
    lane: &OracleLane<Payload>,
): Option<OracleRead<Payload>> {
    lane.latest
}

public(package) fun read_at<Payload: copy + drop + store>(
    lane: &OracleLane<Payload>,
    timestamp_ms: u64,
): Option<OracleRead<Payload>> {
    if (!lane.exact_reads.contains(timestamp_ms)) {
        option::none()
    } else {
        option::some(*lane.exact_reads.borrow(timestamp_ms))
    }
}

public(package) fun read_has_valid_timestamp<Value: copy + drop + store>(
    read: &OracleRead<Value>,
): bool {
    read.source_timestamp_ms > 0 && read.source_timestamp_ms <= read.update_timestamp_ms
}

// === Public-Package Constructor Functions ===

public(package) fun new<Payload: copy + drop + store>(ctx: &mut TxContext): OracleLane<Payload> {
    OracleLane {
        latest: option::none(),
        exact_reads: table::new(ctx),
    }
}

public(package) fun new_read<Value: copy + drop + store>(
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
    value: Value,
): OracleRead<Value> {
    OracleRead { source_timestamp_ms, update_timestamp_ms, value }
}

// === Public-Package Write Functions ===

/// Replaces the latest observation only when the timestamps are valid and the source time strictly advances.
/// Invalid, duplicate, and stale observations are ignored without aborting.
public(package) fun update<Payload: copy + drop + store>(
    lane: &mut OracleLane<Payload>,
    read: OracleRead<Payload>,
    propbook_oracle_id: ID,
) {
    if (!read.read_has_valid_timestamp()) return;
    if (lane.latest.is_some()) {
        if (read.source_timestamp_ms <= lane.latest.borrow().source_timestamp_ms) return;
    };

    lane.latest = option::some(read);
    event::emit(ObservationRecorded<OracleRead<Payload>> {
        propbook_oracle_id,
        observation: read,
    });
}

/// Inserts an observation at its exact source timestamp without changing `latest`.
/// Invalid timestamps and occupied exact keys are ignored without aborting.
public(package) fun insert_at<Payload: copy + drop + store>(
    lane: &mut OracleLane<Payload>,
    read: OracleRead<Payload>,
    propbook_oracle_id: ID,
) {
    if (!read.read_has_valid_timestamp()) return;
    if (lane.exact_reads.contains(read.source_timestamp_ms)) return;

    lane.exact_reads.add(read.source_timestamp_ms, read);
    event::emit(ObservationInserted<OracleRead<Payload>> {
        propbook_oracle_id,
        observation: read,
    });
}
