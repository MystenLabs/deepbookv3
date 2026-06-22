use crate::meta::PredictEventMeta;
use crate::models::StakeConfigUpdated as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::StakeConfigUpdated as Row;

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
        lower_benefit_power: BigDecimal::from(ev.lower_benefit_power),
        upper_benefit_power: BigDecimal::from(ev.upper_benefit_power),
    }
}

crate::define_predict_handler! {
    name: StakeConfigUpdatedHandler,
    processor_name: "stake_config_updated",
    event_type: crate::models::StakeConfigUpdated,
    db_model: predict_schema::models::StakeConfigUpdated,
    table: stake_config_updated,
    map_event: |event, meta| map(&event, &meta)
}
