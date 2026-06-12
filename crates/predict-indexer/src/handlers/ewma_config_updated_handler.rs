use crate::meta::PredictEventMeta;
use crate::models::EwmaConfigUpdated as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::EwmaConfigUpdated as Row;

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
        // 1e9-scaled smoothing factor, <= ~1e9.
        alpha: ev.alpha as i64,
        // 1e9-scaled threshold, bounded.
        z_score_threshold: ev.z_score_threshold as i64,
        penalty_rate: BigDecimal::from(ev.penalty_rate),
        enabled: ev.enabled,
    }
}

crate::define_predict_handler! {
    name: EwmaConfigUpdatedHandler,
    processor_name: "ewma_config_updated",
    event_type: crate::models::EwmaConfigUpdated,
    db_model: predict_schema::models::EwmaConfigUpdated,
    table: ewma_config_updated,
    map_event: |event, meta| map(&event, &meta)
}
