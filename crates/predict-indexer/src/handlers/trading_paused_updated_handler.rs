use crate::meta::PredictEventMeta;
use crate::models::TradingPausedUpdated as Ev;
use predict_schema::models::TradingPausedUpdated as Row;

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
        paused: ev.paused,
    }
}

crate::define_predict_handler! {
    name: TradingPausedUpdatedHandler,
    processor_name: "trading_paused_updated",
    event_type: crate::models::TradingPausedUpdated,
    db_model: predict_schema::models::TradingPausedUpdated,
    table: trading_paused_updated,
    map_event: |event, meta| map(&event, &meta)
}
