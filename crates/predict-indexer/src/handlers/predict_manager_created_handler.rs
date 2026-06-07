use crate::meta::PredictEventMeta;
use crate::models::PredictManagerCreated as Ev;
use predict_schema::models::PredictManagerCreated as Row;

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
        balance_manager_id: ev.balance_manager_id.to_string(),
        owner: ev.owner.to_string(),
    }
}

crate::define_predict_handler! {
    name: PredictManagerCreatedHandler,
    processor_name: "predict_manager_created",
    event_type: crate::models::PredictManagerCreated,
    db_model: predict_schema::models::PredictManagerCreated,
    table: predict_manager_created,
    map_event: |event, meta| map(&event, &meta)
}
