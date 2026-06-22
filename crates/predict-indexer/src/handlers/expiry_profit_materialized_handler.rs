use crate::meta::PredictEventMeta;
use crate::models::ExpiryProfitMaterialized as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::ExpiryProfitMaterialized as Row;

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
        lp_profit: BigDecimal::from(ev.lp_profit),
        protocol_profit: BigDecimal::from(ev.protocol_profit),
        idle_balance_after: BigDecimal::from(ev.idle_balance_after),
        protocol_reserve_balance_after: BigDecimal::from(ev.protocol_reserve_balance_after),
        profit_basis_after: BigDecimal::from(ev.profit_basis_after),
        pending_protocol_profit_after: BigDecimal::from(ev.pending_protocol_profit_after),
    }
}

crate::define_predict_handler! {
    name: ExpiryProfitMaterializedHandler,
    processor_name: "expiry_profit_materialized",
    event_type: crate::models::ExpiryProfitMaterialized,
    db_model: predict_schema::models::ExpiryProfitMaterialized,
    table: expiry_profit_materialized,
    map_event: |event, meta| map(&event, &meta)
}
