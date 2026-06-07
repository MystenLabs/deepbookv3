use crate::meta::PredictEventMeta;
use crate::models::BlockScholesPricesUpdated as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::BlockScholesPricesUpdated as Row;

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
        spot: BigDecimal::from(ev.spot),
        forward: BigDecimal::from(ev.forward),
        basis: BigDecimal::from(ev.basis),
        // Unix ms timestamp.
        source_timestamp_ms: ev.source_timestamp_ms as i64,
        // Unix ms timestamp.
        update_timestamp_ms: ev.update_timestamp_ms as i64,
    }
}

crate::define_predict_handler! {
    name: BlockScholesPricesUpdatedHandler,
    processor_name: "block_scholes_prices_updated",
    event_type: crate::models::BlockScholesPricesUpdated,
    db_model: predict_schema::models::BlockScholesPricesUpdated,
    table: block_scholes_prices_updated,
    map_event: |event, meta| map(&event, &meta)
}
