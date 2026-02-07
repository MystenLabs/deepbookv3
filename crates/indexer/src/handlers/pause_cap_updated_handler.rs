use crate::models::deepbook_margin::margin_registry::PauseCapUpdated;
use deepbook_schema::models::PauseCapUpdated as PauseCapUpdatedModel;

define_handler! {
    name: PauseCapUpdatedHandler,
    processor_name: "pause_cap_updated",
    event_type: PauseCapUpdated,
    db_model: PauseCapUpdatedModel,
    table: pause_cap_updated,
    map_event: |event, meta| PauseCapUpdatedModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pause_cap_id: event.pause_cap_id.to_string(),
        allowed: event.allowed,
        onchain_timestamp: event.timestamp as i64,
    }
}
