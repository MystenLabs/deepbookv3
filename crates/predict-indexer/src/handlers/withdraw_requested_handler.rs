use crate::meta::PredictEventMeta;
use crate::models::WithdrawRequested as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::WithdrawRequested as Row;

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
        // Monotone withdraw-queue handle, bounded.
        request_index: ev.index as i64,
        amount: BigDecimal::from(ev.amount),
    }
}

crate::define_predict_handler! {
    name: WithdrawRequestedHandler,
    processor_name: "withdraw_requested",
    event_type: crate::models::WithdrawRequested,
    db_model: predict_schema::models::WithdrawRequested,
    table: withdraw_requested,
    map_event: |event, meta| map(&event, &meta)
}
