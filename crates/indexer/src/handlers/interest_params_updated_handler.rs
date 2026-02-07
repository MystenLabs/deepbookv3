use crate::models::deepbook_margin::margin_pool::InterestParamsUpdated;
use deepbook_schema::models::InterestParamsUpdated as InterestParamsUpdatedModel;

define_handler! {
    name: InterestParamsUpdatedHandler,
    processor_name: "interest_params_updated",
    event_type: InterestParamsUpdated,
    db_model: InterestParamsUpdatedModel,
    table: interest_params_updated,
    map_event: |event, meta| InterestParamsUpdatedModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        margin_pool_id: event.margin_pool_id.to_string(),
        pool_cap_id: event.pool_cap_id.to_string(),
        config_json: serde_json::to_value(&event.interest_config).unwrap(),
        onchain_timestamp: event.timestamp as i64,
    }
}
