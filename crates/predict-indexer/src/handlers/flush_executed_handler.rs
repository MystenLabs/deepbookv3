use crate::meta::PredictEventMeta;
use crate::models::FlushExecuted as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::FlushExecuted as Row;

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
        // Sui epoch, bounded.
        epoch: ev.epoch as i64,
        pool_value: BigDecimal::from(ev.pool_value),
        total_supply: BigDecimal::from(ev.total_supply),
        active_market_nav: BigDecimal::from(ev.active_market_nav),
        // Active-set count, bounded.
        market_count: ev.market_count as i64,
        idle_balance_before: BigDecimal::from(ev.idle_balance_before),
        // Fill counts, bounded by max_requests_per_flush.
        supplies_filled: ev.supplies_filled as i64,
        withdrawals_filled: ev.withdrawals_filled as i64,
        requests_processed: ev.requests_processed as i64,
        idle_balance_after: BigDecimal::from(ev.idle_balance_after),
    }
}

crate::define_predict_handler! {
    name: FlushExecutedHandler,
    processor_name: "flush_executed",
    event_type: crate::models::FlushExecuted,
    db_model: predict_schema::models::FlushExecuted,
    table: flush_executed,
    map_event: |event, meta| map(&event, &meta)
}
