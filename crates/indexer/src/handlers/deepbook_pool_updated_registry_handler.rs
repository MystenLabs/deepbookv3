use crate::models::deepbook_margin::margin_registry::DeepbookPoolUpdated;
use deepbook_schema::models::DeepbookPoolUpdatedRegistry;

define_handler! {
    name: DeepbookPoolUpdatedRegistryHandler,
    processor_name: "deepbook_pool_updated_registry",
    event_type: DeepbookPoolUpdated,
    db_model: DeepbookPoolUpdatedRegistry,
    table: deepbook_pool_updated_registry,
    map_event: |event, meta| DeepbookPoolUpdatedRegistry {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        enabled: event.enabled,
        onchain_timestamp: event.timestamp as i64,
    }
}
