use crate::meta::PredictEventMeta;
use crate::models::MarketSettled as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::MarketSettled as Row;

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
        // u32 Propbook underlying id, fits in i64.
        propbook_underlying_id: ev.propbook_underlying_id as i64,
        // Unix ms timestamp.
        expiry: ev.expiry as i64,
        settlement_price: BigDecimal::from(ev.settlement_price),
        // On-chain landing time, unix ms.
        settled_at_ms: ev.settled_at_ms as i64,
    }
}

crate::define_predict_handler! {
    name: MarketSettledHandler,
    processor_name: "market_settled",
    event_type: crate::models::MarketSettled,
    db_model: predict_schema::models::MarketSettled,
    table: market_settled,
    map_event: |event, meta| map(&event, &meta)
}
