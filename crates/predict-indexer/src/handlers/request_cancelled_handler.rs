use crate::meta::PredictEventMeta;
use crate::models::RequestCancelled as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::RequestCancelled as Row;

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
        pool_vault_id: ev.pool_vault_id.to_string(),
        predict_manager_id: ev.predict_manager_id.to_string(),
        recipient: ev.recipient.to_string(),
        // Queue handle, unique within (vault, is_supply).
        request_index: ev.index as i64,
        amount: BigDecimal::from(ev.amount),
        is_supply: ev.is_supply,
    }
}

crate::define_predict_handler! {
    name: RequestCancelledHandler,
    processor_name: "request_cancelled",
    event_type: crate::models::RequestCancelled,
    db_model: predict_schema::models::RequestCancelled,
    table: request_cancelled,
    map_event: |event, meta| map(&event, &meta)
}
