use crate::meta::PredictEventMeta;
use crate::models::FeeConfigUpdated as Ev;
use predict_schema::models::FeeConfigUpdated as Row;

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
        protocol_reserve_profit_share: ev.protocol_reserve_profit_share as i64,
        // 1e9-scaled fee curve parameter, bounded.
        withdraw_fee_alpha: ev.withdraw_fee_alpha as i64,
    }
}

crate::define_predict_handler! {
    name: FeeConfigUpdatedHandler,
    processor_name: "fee_config_updated",
    event_type: crate::models::FeeConfigUpdated,
    db_model: predict_schema::models::FeeConfigUpdated,
    table: fee_config_updated,
    map_event: |event, meta| map(&event, &meta)
}
