use crate::meta::OracleEventMeta;
use crate::models::OracleSourceRegistered as Ev;
use predict_schema::models::OracleSourceRegistered as Row;

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
        // u8 oracle kind (0 = Pyth, 1 = Block Scholes).
        oracle_kind: ev.oracle_kind as i16,
        // u32 source-local id, fits in i64.
        source_id: ev.source_id as i64,
        propbook_oracle_id: ev.propbook_oracle_id.to_string(),
    }
}

crate::define_oracle_handler! {
    name: OracleSourceRegisteredHandler,
    processor_name: "oracle_source_registered",
    event_type: crate::models::OracleSourceRegistered,
    db_model: predict_schema::models::OracleSourceRegistered,
    table: oracle_source_registered,
    map_event: |event, meta| map(&event, &meta)
}
