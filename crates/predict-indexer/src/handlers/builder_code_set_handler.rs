use crate::meta::PredictEventMeta;
use crate::models::BuilderCodeSet as Ev;
use predict_schema::models::BuilderCodeSet as Row;

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
        predict_manager_id: ev.predict_manager_id.to_string(),
        owner: ev.owner.to_string(),
        builder_code_id: ev.builder_code_id.map(|id| id.to_string()),
    }
}

crate::define_predict_handler! {
    name: BuilderCodeSetHandler,
    processor_name: "builder_code_set",
    event_type: crate::models::BuilderCodeSet,
    db_model: predict_schema::models::BuilderCodeSet,
    table: builder_code_set,
    map_event: |event, meta| map(&event, &meta)
}
