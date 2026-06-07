use crate::meta::PredictEventMeta;
use crate::models::WithdrawExecuted as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::WithdrawExecuted as Row;

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
        shares_burned: BigDecimal::from(ev.shares_burned),
        payout: BigDecimal::from(ev.payout),
        pool_value_before: BigDecimal::from(ev.pool_value_before),
        total_supply_after: BigDecimal::from(ev.total_supply_after),
        idle_balance_after: BigDecimal::from(ev.idle_balance_after),
    }
}

crate::define_predict_handler! {
    name: WithdrawExecutedHandler,
    processor_name: "withdraw_executed",
    event_type: crate::models::WithdrawExecuted,
    db_model: predict_schema::models::WithdrawExecuted,
    table: withdraw_executed,
    map_event: |event, meta| map(&event, &meta)
}
