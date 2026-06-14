// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Generic Propbook oracle lane. A lane is one advancing source stream with:
/// - one latest source observation,
/// - insert-only exact timestamp history, and
/// - the normal latest / exact insertion events.
///
/// `source_timestamp_ms` is Propbook's canonical freshness key. Source modules
/// may keep richer native timestamps inside `Payload`, but lane ordering,
/// exact-history keys, and future-source checks are all millisecond-denominated;
/// lane writes that are future, zero, stale, or duplicate are no-ops.
module propbook::oracle_lane;

use std::option::{Self, Option};
use sui::{event, table::{Self, Table}};

/// Timestamped oracle read. Raw and normalized reads use the same timestamp
/// envelope, so consumers can apply one freshness policy regardless of which
/// projection they read.
public struct OracleRead<Value: copy + drop + store> has copy, drop, store {
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
    value: Value,
}

/// One advancing oracle lane.
public struct OracleLane<Payload: copy + drop + store> has store {
    latest: Option<OracleRead<Payload>>,
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

public(package) fun update<Payload: copy + drop + store>(
    lane: &mut OracleLane<Payload>,
    propbook_oracle_id: ID,
    read: OracleRead<Payload>,
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

public(package) fun insert_at<Payload: copy + drop + store>(
    lane: &mut OracleLane<Payload>,
    propbook_oracle_id: ID,
    read: OracleRead<Payload>,
) {
    if (!read.read_has_valid_timestamp()) return;
    if (lane.exact_reads.contains(read.source_timestamp_ms)) return;

    lane.exact_reads.add(read.source_timestamp_ms, read);
    event::emit(ObservationInserted<OracleRead<Payload>> {
        propbook_oracle_id,
        observation: read,
    });
}
