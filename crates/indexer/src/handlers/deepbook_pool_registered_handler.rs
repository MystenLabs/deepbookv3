use crate::models::deepbook_margin::margin_registry::DeepbookPoolRegistered;
use deepbook_schema::models::DeepbookPoolRegistered as DeepbookPoolRegisteredModel;

define_handler! {
    name: DeepbookPoolRegisteredHandler,
    processor_name: "deepbook_pool_registered",
    event_type: DeepbookPoolRegistered,
    db_model: DeepbookPoolRegisteredModel,
    table: deepbook_pool_registered,
    map_event: |event, meta| DeepbookPoolRegisteredModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        config_json: Some(serde_json::to_value(&event.config).unwrap()),
        onchain_timestamp: event.timestamp as i64,
    }
}
