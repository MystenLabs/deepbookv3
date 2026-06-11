use crate::meta::PredictEventMeta;
use crate::models::BuilderCodeCreated as Ev;
use predict_schema::models::BuilderCodeCreated as Row;

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
        builder_code_id: ev.builder_code_id.to_string(),
        owner: ev.owner.to_string(),
        builder_code_index: bigdecimal::BigDecimal::from(ev.builder_code_index),
    }
}

crate::define_predict_handler! {
    name: BuilderCodeCreatedHandler,
    processor_name: "builder_code_created",
    event_type: crate::models::BuilderCodeCreated,
    db_model: predict_schema::models::BuilderCodeCreated,
    table: builder_code_created,
    map_event: |event, meta| map(&event, &meta)
}
