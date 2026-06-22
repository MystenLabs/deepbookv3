use crate::meta::PredictEventMeta;
use crate::models::StrikeExposureTemplateConfigUpdated as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::StrikeExposureTemplateConfigUpdated as Row;

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
        // 1e9-scaled index, bounded.
        terminal_floor_index: ev.terminal_floor_index as i64,
        // 1e9-scaled ratio, <= ~1e9.
        liquidation_ltv: ev.liquidation_ltv as i64,
        // 1e9-scaled ratio, bounded.
        backing_buffer_lambda: ev.backing_buffer_lambda as i64,
        base_fee: BigDecimal::from(ev.base_fee),
        min_fee: BigDecimal::from(ev.min_fee),
        min_ask_price: BigDecimal::from(ev.min_ask_price),
        max_ask_price: BigDecimal::from(ev.max_ask_price),
        // Window in ms, bounded.
        expiry_fee_window_ms: ev.expiry_fee_window_ms as i64,
        // 1e9-scaled multiplier, bounded.
        expiry_fee_max_multiplier: ev.expiry_fee_max_multiplier as i64,
    }
}

crate::define_predict_handler! {
    name: StrikeExposureTemplateConfigUpdatedHandler,
    processor_name: "strike_exposure_template_config_updated",
    event_type: crate::models::StrikeExposureTemplateConfigUpdated,
    db_model: predict_schema::models::StrikeExposureTemplateConfigUpdated,
    table: strike_exposure_template_config_updated,
    map_event: |event, meta| map(&event, &meta)
}
