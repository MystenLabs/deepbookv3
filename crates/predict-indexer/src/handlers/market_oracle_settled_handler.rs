use crate::meta::PredictEventMeta;
use crate::models::MarketOracleSettled as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::MarketOracleSettled as Row;

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
        market_oracle_id: ev.market_oracle_id.to_string(),
        // Unix ms timestamp.
        expiry: ev.expiry as i64,
        settlement_price: BigDecimal::from(ev.settlement_price),
        // u8 spot source: 1=Pyth, 2=Block Scholes fallback.
        spot_source: ev.spot_source as i16,
        // Unix ms timestamp.
        source_timestamp_ms: ev.source_timestamp_ms as i64,
        // Unix ms timestamp.
        update_timestamp_ms: ev.update_timestamp_ms as i64,
    }
}

crate::define_predict_handler! {
    name: MarketOracleSettledHandler,
    processor_name: "market_oracle_settled",
    event_type: crate::models::MarketOracleSettled,
    db_model: predict_schema::models::MarketOracleSettled,
    table: market_oracle_settled,
    map_event: |event, meta| map(&event, &meta)
}
