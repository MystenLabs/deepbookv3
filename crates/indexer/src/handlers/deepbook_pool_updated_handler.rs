use crate::models::deepbook_margin::margin_pool::DeepbookPoolUpdated;
use deepbook_schema::models::DeepbookPoolUpdated as DeepbookPoolUpdatedModel;

define_handler! {
    name: DeepbookPoolUpdatedHandler,
    processor_name: "deepbook_pool_updated",
    event_type: DeepbookPoolUpdated,
    db_model: DeepbookPoolUpdatedModel,
    table: deepbook_pool_updated,
    map_event: |event, meta| DeepbookPoolUpdatedModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        margin_pool_id: event.margin_pool_id.to_string(),
        deepbook_pool_id: event.deepbook_pool_id.to_string(),
        pool_cap_id: event.pool_cap_id.to_string(),
        enabled: event.enabled,
        onchain_timestamp: event.timestamp as i64,
    }
}
