use crate::meta::PredictEventMeta;
use crate::models::ExpiryMaxFundingUpdated as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::ExpiryMaxFundingUpdated as Row;

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
        max_expiry_funding: BigDecimal::from(ev.max_expiry_funding),
        net_funding: BigDecimal::from(ev.net_funding),
    }
}

crate::define_predict_handler! {
    name: ExpiryMaxFundingUpdatedHandler,
    processor_name: "expiry_max_funding_updated",
    event_type: crate::models::ExpiryMaxFundingUpdated,
    db_model: predict_schema::models::ExpiryMaxFundingUpdated,
    table: expiry_max_funding_updated,
    map_event: |event, meta| map(&event, &meta)
}
