use crate::meta::PredictEventMeta;
use crate::models::RiskConfigUpdated as Ev;
use predict_schema::models::RiskConfigUpdated as Row;

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
        // Candidate-count budget, bounded.
        trade_liquidation_budget: ev.trade_liquidation_budget as i64,
        // 1e9-scaled reserve share of profit, bounded.
        protocol_reserve_profit_share: ev.protocol_reserve_profit_share as i64,
    }
}

crate::define_predict_handler! {
    name: RiskConfigUpdatedHandler,
    processor_name: "risk_config_updated",
    event_type: crate::models::RiskConfigUpdated,
    db_model: predict_schema::models::RiskConfigUpdated,
    table: risk_config_updated,
    map_event: |event, meta| map(&event, &meta)
}
