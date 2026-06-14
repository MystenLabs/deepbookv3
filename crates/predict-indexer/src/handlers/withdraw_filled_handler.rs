use crate::meta::PredictEventMeta;
use crate::models::WithdrawFilled as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::WithdrawFilled as Row;

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
        // Withdraw-queue handle.
        request_index: ev.index as i64,
        shares_burned: BigDecimal::from(ev.shares_burned),
        dusdc_amount: BigDecimal::from(ev.dusdc_amount),
    }
}

crate::define_predict_handler! {
    name: WithdrawFilledHandler,
    processor_name: "withdraw_filled",
    event_type: crate::models::WithdrawFilled,
    db_model: predict_schema::models::WithdrawFilled,
    table: withdraw_filled,
    map_event: |event, meta| map(&event, &meta)
}
