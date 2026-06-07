use crate::meta::PredictEventMeta;
use crate::models::SupplyExecuted as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::SupplyExecuted as Row;

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
        payment: BigDecimal::from(ev.payment),
        shares_minted: BigDecimal::from(ev.shares_minted),
        pool_value_before: BigDecimal::from(ev.pool_value_before),
        incentive_value: BigDecimal::from(ev.incentive_value),
        total_supply_after: BigDecimal::from(ev.total_supply_after),
        idle_balance_after: BigDecimal::from(ev.idle_balance_after),
    }
}

crate::define_predict_handler! {
    name: SupplyExecutedHandler,
    processor_name: "supply_executed",
    event_type: crate::models::SupplyExecuted,
    db_model: predict_schema::models::SupplyExecuted,
    table: supply_executed,
    map_event: |event, meta| map(&event, &meta)
}
