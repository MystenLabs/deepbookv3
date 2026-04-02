use crate::models::deepbook_margin::margin_registry::MaxPriceAgeUpdated;
use deepbook_schema::models::MaxPriceAgeUpdated as MaxPriceAgeUpdatedModel;

define_handler! {
    name: MaxPriceAgeUpdatedHandler,
    processor_name: "max_price_age_updated",
    event_type: MaxPriceAgeUpdated,
    db_model: MaxPriceAgeUpdatedModel,
    table: max_price_age_updated,
    map_event: |event, meta| MaxPriceAgeUpdatedModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        max_age_ms: event.max_age_ms as i64,
        onchain_timestamp: event.timestamp as i64,
    }
}
