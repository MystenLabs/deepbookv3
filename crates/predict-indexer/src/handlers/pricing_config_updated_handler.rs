use crate::meta::PredictEventMeta;
use crate::models::PricingConfigUpdated as Ev;
use predict_schema::models::PricingConfigUpdated as Row;

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
        protocol_config_id: ev.protocol_config_id.to_string(),
        // Staleness window in ms, bounded.
        pyth_spot_freshness_ms: ev.pyth_spot_freshness_ms as i64,
        // Staleness window in ms, bounded.
        block_scholes_surface_freshness_ms: ev.block_scholes_surface_freshness_ms as i64,
    }
}

crate::define_predict_handler! {
    name: PricingConfigUpdatedHandler,
    processor_name: "pricing_config_updated",
    event_type: crate::models::PricingConfigUpdated,
    db_model: predict_schema::models::PricingConfigUpdated,
    table: pricing_config_updated,
    map_event: |event, meta| map(&event, &meta)
}
