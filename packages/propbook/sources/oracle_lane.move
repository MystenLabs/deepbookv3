// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Generic Propbook oracle lane. A lane is one advancing source stream with:
/// - one latest source observation,
/// - first-observed minute history,
/// - exact-timestamp official settlement history, and
/// - the normal observation / official settlement events.
///
/// `source_timestamp_ms` is Propbook's canonical freshness key. Source modules
/// may keep richer native timestamps inside `Payload`, but lane ordering,
/// history bucketing, and future-source checks are all millisecond-denominated.
module propbook::oracle_lane;

use propbook::{observation_history::{Self, ObservationHistory}, oracle_events};

const EFutureSourceUpdate: u64 = 0;
const EStaleSourceUpdate: u64 = 1;

/// Source payload plus the canonical Propbook timestamps for one observation.
public struct OracleObservation<Payload: copy + drop + store> has copy, drop, store {
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
    payload: Payload,
}

/// One advancing oracle lane.
public struct OracleLane<Payload: copy + drop + store> has store {
    latest: OracleObservation<Payload>,
    history: ObservationHistory<OracleObservation<Payload>>,
}

// === Read Functions ===

public fun latest<Payload: copy + drop + store>(
    lane: &OracleLane<Payload>,
): OracleObservation<Payload> {
    lane.latest
}

public fun has_latest<Payload: copy + drop + store>(lane: &OracleLane<Payload>): bool {
    lane.latest.source_timestamp_ms > 0
}

public fun source_timestamp_ms<Payload: copy + drop + store>(
    observation: &OracleObservation<Payload>,
): u64 {
    observation.source_timestamp_ms
}

public fun update_timestamp_ms<Payload: copy + drop + store>(
    observation: &OracleObservation<Payload>,
): u64 {
    observation.update_timestamp_ms
}

public fun freshness_timestamp_ms<Payload: copy + drop + store>(lane: &OracleLane<Payload>): u64 {
    lane.latest.source_timestamp_ms.min(lane.latest.update_timestamp_ms)
}

public fun payload<Payload: copy + drop + store>(
    observation: &OracleObservation<Payload>,
): Payload {
    observation.payload
}

public fun observation_at_minute<Payload: copy + drop + store>(
    lane: &OracleLane<Payload>,
    minute_ms: u64,
): OracleObservation<Payload> {
    lane.history.observation_at_minute(minute_ms)
}

public fun has_observation<Payload: copy + drop + store>(
    lane: &OracleLane<Payload>,
    minute_ms: u64,
): bool {
    lane.history.has_observation(minute_ms)
}

public fun official_observation_at_resolution<Payload: copy + drop + store>(
    lane: &OracleLane<Payload>,
    resolution_timestamp_ms: u64,
): OracleObservation<Payload> {
    lane.history.official_observation_at_resolution(resolution_timestamp_ms)
}

public fun has_official_settlement<Payload: copy + drop + store>(
    lane: &OracleLane<Payload>,
    resolution_timestamp_ms: u64,
): bool {
    lane.history.has_official_settlement(resolution_timestamp_ms)
}

// === Public-Package Functions ===

public(package) fun new<Payload: copy + drop + store>(
    empty_payload: Payload,
    ctx: &mut TxContext,
): OracleLane<Payload> {
    OracleLane {
        latest: new_observation(empty_payload, 0, 0),
        history: observation_history::new(ctx),
    }
}

public(package) fun new_observation<Payload: copy + drop + store>(
    payload: Payload,
    source_timestamp_ms: u64,
    update_timestamp_ms: u64,
): OracleObservation<Payload> {
    OracleObservation { source_timestamp_ms, update_timestamp_ms, payload }
}

public(package) fun record_observation_if_fresh<Payload: copy + drop + store>(
    lane: &mut OracleLane<Payload>,
    propbook_oracle_id: ID,
    observation: OracleObservation<Payload>,
) {
    assert!(
        observation.source_timestamp_ms <= observation.update_timestamp_ms,
        EFutureSourceUpdate,
    );
    assert!(observation.source_timestamp_ms > lane.latest.source_timestamp_ms, EStaleSourceUpdate);

    lane.latest = observation;
    lane.history.record_first_observed(observation.source_timestamp_ms, observation);
    oracle_events::emit_observation_recorded(propbook_oracle_id, observation);
}

public(package) fun record_official_settlement<Payload: copy + drop + store>(
    lane: &mut OracleLane<Payload>,
    propbook_oracle_id: ID,
    observation: OracleObservation<Payload>,
) {
    assert!(
        observation.source_timestamp_ms <= observation.update_timestamp_ms,
        EFutureSourceUpdate,
    );
    lane.history.record_official_settlement(observation.source_timestamp_ms, observation);
    oracle_events::emit_official_settlement_recorded(
        propbook_oracle_id,
        observation.source_timestamp_ms,
        observation,
    );
}
