use crate::meta::PredictEventMeta;
use crate::models::ExpiryCashReceived as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::ExpiryCashReceived as Row;

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
        expiry_market_id: ev.expiry_market_id.to_string(),
        settlement_price: BigDecimal::from(ev.settlement_price),
        amount: BigDecimal::from(ev.amount),
        idle_balance_after: BigDecimal::from(ev.idle_balance_after),
        sent_to_expiry_after: BigDecimal::from(ev.sent_to_expiry_after),
        received_from_expiry_after: BigDecimal::from(ev.received_from_expiry_after),
    }
}

crate::define_predict_handler! {
    name: ExpiryCashReceivedHandler,
    processor_name: "expiry_cash_received",
    event_type: crate::models::ExpiryCashReceived,
    db_model: predict_schema::models::ExpiryCashReceived,
    table: expiry_cash_received,
    map_event: |event, meta| map(&event, &meta)
}
