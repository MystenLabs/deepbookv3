use crate::models::deepbook_margin::margin_registry::CurrentPriceUpdated;
use deepbook_schema::models::CurrentPriceUpdated as CurrentPriceUpdatedModel;

define_handler! {
    name: CurrentPriceUpdatedHandler,
    processor_name: "current_price_updated",
    event_type: CurrentPriceUpdated,
    db_model: CurrentPriceUpdatedModel,
    table: current_price_updated,
    map_event: |event, meta| CurrentPriceUpdatedModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        price: event.price as i64,
        onchain_timestamp: event.timestamp as i64,
    }
}
