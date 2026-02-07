use crate::models::deepbook_margin::margin_registry::DeepbookPoolConfigUpdated;
use deepbook_schema::models::DeepbookPoolConfigUpdated as DeepbookPoolConfigUpdatedModel;

define_handler! {
    name: DeepbookPoolConfigUpdatedHandler,
    processor_name: "deepbook_pool_config_updated",
    event_type: DeepbookPoolConfigUpdated,
    db_model: DeepbookPoolConfigUpdatedModel,
    table: deepbook_pool_config_updated,
    map_event: |event, meta| DeepbookPoolConfigUpdatedModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        config_json: serde_json::to_value(&event.config).unwrap(),
        onchain_timestamp: event.timestamp as i64,
    }
}
