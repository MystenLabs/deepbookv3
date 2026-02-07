use crate::models::deepbook_margin::margin_pool::MarginPoolCreated;
use deepbook_schema::models::MarginPoolCreated as MarginPoolCreatedModel;

define_handler! {
    name: MarginPoolCreatedHandler,
    processor_name: "margin_pool_created",
    event_type: MarginPoolCreated,
    db_model: MarginPoolCreatedModel,
    table: margin_pool_created,
    map_event: |event, meta| MarginPoolCreatedModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        margin_pool_id: event.margin_pool_id.to_string(),
        maintainer_cap_id: event.maintainer_cap_id.to_string(),
        asset_type: event.asset_type.to_string(),
        config_json: serde_json::to_value(&event.config).unwrap(),
        onchain_timestamp: event.timestamp as i64,
    }
}
