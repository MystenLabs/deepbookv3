// Copyright (c) Mysten Labs, Inc.
// SPDX-License-Identifier: Apache-2.0

/// Generic Propbook oracle observation events. Oracle lanes emit source-native
/// observation envelopes, so event consumers can filter by the generic event
/// type instantiation:
///
/// - `ObservationRecorded<oracle_lane::OracleObservation<pyth_feed::PythSourcePayload>>`
/// - `OfficialSettlementRecorded<oracle_lane::OracleObservation<block_scholes_feed::BlockScholesSourcePayload>>`
module propbook::oracle_events;

use sui::event;

/// Emitted when a feed accepts a source-native observation into its live oracle
/// state.
public struct ObservationRecorded<Observation: copy + drop> has copy, drop {
    propbook_oracle_id: ID,
    observation: Observation,
}

/// Emitted when a feed records source-native official settlement data keyed by
/// exact `resolution_timestamp_ms`.
public struct OfficialSettlementRecorded<Observation: copy + drop> has copy, drop {
    propbook_oracle_id: ID,
    resolution_timestamp_ms: u64,
    observation: Observation,
}

// === Public-Package Functions ===

public(package) fun emit_observation_recorded<Observation: copy + drop>(
    propbook_oracle_id: ID,
    observation: Observation,
) {
    event::emit(ObservationRecorded<Observation> {
        propbook_oracle_id,
        observation,
    });
}

public(package) fun emit_official_settlement_recorded<Observation: copy + drop>(
    propbook_oracle_id: ID,
    resolution_timestamp_ms: u64,
    observation: Observation,
) {
    event::emit(OfficialSettlementRecorded<Observation> {
        propbook_oracle_id,
        resolution_timestamp_ms,
        observation,
    });
}
