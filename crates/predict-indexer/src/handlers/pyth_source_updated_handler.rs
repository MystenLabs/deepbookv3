use crate::meta::PredictEventMeta;
use crate::models::PythSourceUpdated as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::PythSourceUpdated as Row;

pub fn map(ev: &Ev, meta: &PredictEventMeta) -> Row {
    Row {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pyth_source_id: ev.pyth_source_id.to_string(),
        // u32 feed id, fits in i64.
        feed_id: ev.feed_id as i64,
        spot: BigDecimal::from(ev.spot),
        // Unix ms timestamp.
        source_timestamp_ms: ev.source_timestamp_ms as i64,
        // Unix ms timestamp.
        update_timestamp_ms: ev.update_timestamp_ms as i64,
    }
}

crate::define_predict_handler! {
    name: PythSourceUpdatedHandler,
    processor_name: "pyth_source_updated",
    event_type: crate::models::PythSourceUpdated,
    db_model: predict_schema::models::PythSourceUpdated,
    table: pyth_source_updated,
    map_event: |event, meta| map(&event, &meta)
}
