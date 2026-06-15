use crate::meta::OracleEventMeta;
use crate::models::OracleBound as Ev;
use predict_schema::models::OracleBound as Row;

pub fn map(ev: &Ev, meta: &OracleEventMeta) -> Row {
    Row {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        // u32 underlying id, fits in i64.
        propbook_underlying_id: ev.propbook_underlying_id as i64,
        // u8 oracle kind (0 = Pyth, 1 = Block Scholes).
        oracle_kind: ev.oracle_kind as i16,
        // u32 source-local id, fits in i64.
        source_id: ev.source_id as i64,
        propbook_oracle_id: ev.propbook_oracle_id.to_string(),
        // u8 value kind (0 = spot, 1 = vol_surface).
        value_kind: ev.value_kind as i16,
    }
}

crate::define_oracle_handler! {
    name: OracleBoundHandler,
    processor_name: "oracle_bound",
    event_type: crate::models::OracleBound,
    db_model: predict_schema::models::OracleBound,
    table: oracle_bound,
    map_event: |event, meta| map(&event, &meta)
}
