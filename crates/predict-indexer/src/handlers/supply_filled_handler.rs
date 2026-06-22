use crate::meta::PredictEventMeta;
use crate::models::SupplyFilled as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::SupplyFilled as Row;

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
        // Supply-queue handle.
        request_index: ev.index as i64,
        dusdc_amount: BigDecimal::from(ev.dusdc_amount),
        shares_minted: BigDecimal::from(ev.shares_minted),
    }
}

crate::define_predict_handler! {
    name: SupplyFilledHandler,
    processor_name: "supply_filled",
    event_type: crate::models::SupplyFilled,
    db_model: predict_schema::models::SupplyFilled,
    table: supply_filled,
    map_event: |event, meta| map(&event, &meta)
}
