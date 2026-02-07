use crate::models::deepbook_margin::margin_registry::MaintainerCapUpdated;
use deepbook_schema::models::MaintainerCapUpdated as MaintainerCapUpdatedModel;

define_handler! {
    name: MaintainerCapUpdatedHandler,
    processor_name: "maintainer_cap_updated",
    event_type: MaintainerCapUpdated,
    db_model: MaintainerCapUpdatedModel,
    table: maintainer_cap_updated,
    map_event: |event, meta| MaintainerCapUpdatedModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        maintainer_cap_id: event.maintainer_cap_id.to_string(),
        allowed: event.allowed,
        onchain_timestamp: event.timestamp as i64,
    }
}
