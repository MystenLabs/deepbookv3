use crate::meta::PredictEventMeta;
use crate::models::MarketCreated as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::MarketCreated as Row;

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
        expiry_market_id: ev.expiry_market_id.to_string(),
        pool_vault_id: ev.pool_vault_id.to_string(),
        // u32 Propbook underlying id, fits in i64.
        propbook_underlying_id: ev.propbook_underlying_id as i64,
        // Unix ms timestamp.
        expiry: ev.expiry as i64,
        tick_size: BigDecimal::from(ev.tick_size),
    }
}

crate::define_predict_handler! {
    name: MarketCreatedHandler,
    processor_name: "market_created",
    event_type: crate::models::MarketCreated,
    db_model: predict_schema::models::MarketCreated,
    table: market_created,
    map_event: |event, meta| map(&event, &meta)
}
