use crate::models::deepbook_margin::margin_pool::MarginPoolConfigUpdated;
use deepbook_schema::models::MarginPoolConfigUpdated as MarginPoolConfigUpdatedModel;

define_handler! {
    name: MarginPoolConfigUpdatedHandler,
    processor_name: "margin_pool_config_updated",
    event_type: MarginPoolConfigUpdated,
    db_model: MarginPoolConfigUpdatedModel,
    table: margin_pool_config_updated,
    map_event: |event, meta| MarginPoolConfigUpdatedModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        margin_pool_id: event.margin_pool_id.to_string(),
        pool_cap_id: event.pool_cap_id.to_string(),
        config_json: serde_json::to_value(&event.margin_pool_config).unwrap(),
        onchain_timestamp: event.timestamp as i64,
    }
}
