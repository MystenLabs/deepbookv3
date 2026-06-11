use crate::meta::PredictEventMeta;
use crate::models::ExpiryCashTemplateConfigUpdated as Ev;
use predict_schema::models::ExpiryCashTemplateConfigUpdated as Row;

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
        // 1e9-scaled ratio, <= ~1e9.
        trading_loss_rebate_rate: ev.trading_loss_rebate_rate as i64,
    }
}

crate::define_predict_handler! {
    name: ExpiryCashTemplateConfigUpdatedHandler,
    processor_name: "expiry_cash_template_config_updated",
    event_type: crate::models::ExpiryCashTemplateConfigUpdated,
    db_model: predict_schema::models::ExpiryCashTemplateConfigUpdated,
    table: expiry_cash_template_config_updated,
    map_event: |event, meta| map(&event, &meta)
}
