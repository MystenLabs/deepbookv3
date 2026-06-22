use crate::meta::PredictEventMeta;
use crate::models::ExpiryCashRebalanced as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::ExpiryCashRebalanced as Row;

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
        amount: BigDecimal::from(ev.amount),
        to_expiry: ev.to_expiry,
        target_cash: BigDecimal::from(ev.target_cash),
        expiry_cash_after: BigDecimal::from(ev.expiry_cash_after),
        idle_balance_after: BigDecimal::from(ev.idle_balance_after),
        sent_to_expiry_after: BigDecimal::from(ev.sent_to_expiry_after),
        received_from_expiry_after: BigDecimal::from(ev.received_from_expiry_after),
        protocol_reserve_balance_after: BigDecimal::from(ev.protocol_reserve_balance_after),
        pending_protocol_profit_after: BigDecimal::from(ev.pending_protocol_profit_after),
    }
}

crate::define_predict_handler! {
    name: ExpiryCashRebalancedHandler,
    processor_name: "expiry_cash_rebalanced",
    event_type: crate::models::ExpiryCashRebalanced,
    db_model: predict_schema::models::ExpiryCashRebalanced,
    table: expiry_cash_rebalanced,
    map_event: |event, meta| map(&event, &meta)
}
