use crate::meta::PredictEventMeta;
use crate::models::MarketOracleBoundsUpdated as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::MarketOracleBoundsUpdated as Row;

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
        // 1e9-scaled ratio, <= ~1e9.
        max_spot_deviation: ev.max_spot_deviation as i64,
        // 1e9-scaled ratio, <= ~1e9.
        max_basis_deviation: ev.max_basis_deviation as i64,
        min_basis: BigDecimal::from(ev.min_basis),
        max_basis: BigDecimal::from(ev.max_basis),
    }
}

crate::define_predict_handler! {
    name: MarketOracleBoundsUpdatedHandler,
    processor_name: "market_oracle_bounds_updated",
    event_type: crate::models::MarketOracleBoundsUpdated,
    db_model: predict_schema::models::MarketOracleBoundsUpdated,
    table: market_oracle_bounds_updated,
    map_event: |event, meta| map(&event, &meta)
}
