use crate::meta::PredictEventMeta;
use crate::models::DeepUnstaked as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::DeepUnstaked as Row;

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
        amount: BigDecimal::from(ev.amount),
    }
}

crate::define_predict_handler! {
    name: DeepUnstakedHandler,
    processor_name: "deep_unstaked",
    event_type: crate::models::DeepUnstaked,
    db_model: predict_schema::models::DeepUnstaked,
    table: deep_unstaked,
    map_event: |event, meta| map(&event, &meta)
}
