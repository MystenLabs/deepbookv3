use crate::schema::{
    block_scholes_observation, oracle_bound, oracle_source_registered, oracle_spot_1m,
    pyth_observation,
};
use bigdecimal::BigDecimal;
use diesel::{Identifiable, Insertable, Queryable, Selectable};
use serde::Serialize;
use sui_field_count::FieldCount;

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = pyth_observation, primary_key(event_digest))]
pub struct PythObservation {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub propbook_oracle_id: String,
    pub pyth_source_id: i64,
    pub price_magnitude: BigDecimal,
    pub price_is_negative: bool,
    pub exponent_magnitude: i32,
    pub exponent_is_negative: bool,
    pub source_timestamp_us: BigDecimal,
    pub normalized_spot: Option<BigDecimal>,
    pub source_timestamp_ms: i64,
    pub update_timestamp_ms: i64,
    pub is_exact: bool,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = block_scholes_observation, primary_key(event_digest))]
pub struct BlockScholesObservation {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub propbook_oracle_id: String,
    pub bs_source_id: i64,
    pub expiry_ms: i64,
    pub spot: BigDecimal,
    pub forward: BigDecimal,
    pub svi_a: BigDecimal,
    pub svi_b: BigDecimal,
    pub svi_rho: BigDecimal,
    pub svi_m: BigDecimal,
    pub svi_sigma: BigDecimal,
    pub normalized_spot: Option<BigDecimal>,
    pub normalized_forward: Option<BigDecimal>,
    pub source_timestamp_ms: i64,
    pub update_timestamp_ms: i64,
    pub is_exact: bool,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = oracle_source_registered, primary_key(event_digest))]
pub struct OracleSourceRegistered {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub oracle_kind: i16,
    pub source_id: i64,
    pub propbook_oracle_id: String,
}

#[derive(Queryable, Selectable, Insertable, Identifiable, Debug, FieldCount, Serialize)]
#[diesel(table_name = oracle_bound, primary_key(event_digest))]
pub struct OracleBound {
    pub event_digest: String,
    pub digest: String,
    pub sender: String,
    pub checkpoint: i64,
    pub tx_index: i64,
    pub event_index: i64,
    pub checkpoint_timestamp_ms: i64,
    pub package: String,
    pub propbook_underlying_id: i64,
    pub oracle_kind: i16,
    pub source_id: i64,
    pub propbook_oracle_id: String,
    pub value_kind: i16,
}

#[derive(Queryable, Selectable, Debug, Serialize)]
#[diesel(table_name = oracle_spot_1m)]
pub struct OracleSpot1m {
    pub propbook_oracle_id: String,
    pub expiry_ms: i64,
    pub bucket_ms: i64,
    pub open: BigDecimal,
    pub high: BigDecimal,
    pub low: BigDecimal,
    pub close: BigDecimal,
    pub forward: BigDecimal,
    pub update_count: i64,
}
