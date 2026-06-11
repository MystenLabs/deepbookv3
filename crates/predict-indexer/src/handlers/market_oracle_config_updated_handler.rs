use crate::meta::PredictEventMeta;
use crate::models::MarketOracleConfigUpdated as Ev;
use predict_schema::models::MarketOracleConfigUpdated as Row;

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
        // Staleness window in ms, bounded.
        settlement_freshness_ms: ev.settlement_freshness_ms as i64,
    }
}

crate::define_predict_handler! {
    name: MarketOracleConfigUpdatedHandler,
    processor_name: "market_oracle_config_updated",
    event_type: crate::models::MarketOracleConfigUpdated,
    db_model: predict_schema::models::MarketOracleConfigUpdated,
    table: market_oracle_config_updated,
    map_event: |event, meta| map(&event, &meta)
}
