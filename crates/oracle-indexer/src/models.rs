//! Decode structs for Propbook oracle on-chain events.
//!
//! Each struct mirrors the field layout of the corresponding Move struct under
//! `packages/propbook/sources/`. BCS decoding is positional, so field order must
//! be kept in exact sync with the Move source.
//!
//! The observation events are cross-package generics
//! (`oracle_lane::ObservationRecorded<OracleRead<Payload>>`). BCS serializes the
//! fully-monomorphized value positionally, so we define one flattened concrete
//! decode struct per payload (`RawSpot` / `RawSurface`) and pick which to decode
//! by inspecting `ev.type_.type_params` in the handler.

use crate::traits::MoveStruct;
use serde::{Deserialize, Serialize};
use sui_types::base_types::ObjectID;

// === oracle_lane observation events (generic over OracleRead<Payload>) ===

/// `fixed_math::i64::I64 { magnitude, is_negative }` (signed magnitude+sign).
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct I64 {
    pub magnitude: u64,
    pub is_negative: bool,
}

/// `pyth_feed::RawSpot`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RawSpot {
    pub pyth_source_id: u32,
    pub price_magnitude: u64,
    pub price_is_negative: bool,
    pub exponent_magnitude: u16,
    pub exponent_is_negative: bool,
    pub source_timestamp_us: u64,
}

/// `block_scholes_feed::SVIParams`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SVIParams {
    pub a: u64,
    pub b: u64,
    pub rho: I64,
    pub m: I64,
    pub sigma: u64,
}

/// `block_scholes_feed::RawSurface`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RawSurface {
    pub bs_source_id: u32,
    pub expiry_ms: u64,
    pub spot: u64,
    pub forward: u64,
    pub svi: SVIParams,
}

/// `oracle_lane::OracleRead<RawSpot>`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OracleReadRawSpot {
    pub source_timestamp_ms: u64,
    pub update_timestamp_ms: u64,
    pub value: RawSpot,
}

/// `oracle_lane::OracleRead<RawSurface>`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OracleReadRawSurface {
    pub source_timestamp_ms: u64,
    pub update_timestamp_ms: u64,
    pub value: RawSurface,
}

/// `ObservationRecorded<OracleRead<RawSpot>>` / `ObservationInserted<...>` —
/// the same struct shape decodes both event names; the handler picks the
/// `is_exact` flag by event name.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct PythObservationEvent {
    pub propbook_oracle_id: ObjectID,
    pub observation: OracleReadRawSpot,
}

/// `ObservationRecorded<OracleRead<RawSurface>>` / `ObservationInserted<...>`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlockScholesObservationEvent {
    pub propbook_oracle_id: ObjectID,
    pub observation: OracleReadRawSurface,
}

/// Head-only name marker for the live (advancing) observation event
/// (`oracle_lane::ObservationRecorded<...>`, emitted by `update()`). Both
/// payload variants (RawSpot / RawSurface) share this `(module, name)`; the
/// payload split happens in the handler by inspecting `ev.type_.type_params`.
/// Serialize is satisfied by the empty struct so it can implement `MoveStruct`,
/// but it is never decoded — only `matches_event_type` is used.
#[derive(Serialize)]
pub struct ObservationRecorded;

impl MoveStruct for ObservationRecorded {
    const MODULE: &'static str = "oracle_lane";
    const NAME: &'static str = "ObservationRecorded";
}

/// Head-only name marker for the exact-ms history observation event
/// (`oracle_lane::ObservationInserted<...>`, emitted by `insert_at()`).
#[derive(Serialize)]
pub struct ObservationInserted;

impl MoveStruct for ObservationInserted {
    const MODULE: &'static str = "oracle_lane";
    const NAME: &'static str = "ObservationInserted";
}

// === registry events ===

/// `registry::OracleSourceRegistered`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OracleSourceRegistered {
    pub oracle_kind: u8,
    pub source_id: u32,
    pub propbook_oracle_id: ObjectID,
}

impl MoveStruct for OracleSourceRegistered {
    const MODULE: &'static str = "registry";
    const NAME: &'static str = "OracleSourceRegistered";
}

/// `registry::OracleBound`.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct OracleBound {
    pub propbook_underlying_id: u32,
    pub oracle_kind: u8,
    pub source_id: u32,
    pub propbook_oracle_id: ObjectID,
    pub value_kind: u8,
}

impl MoveStruct for OracleBound {
    const MODULE: &'static str = "registry";
    const NAME: &'static str = "OracleBound";
}
