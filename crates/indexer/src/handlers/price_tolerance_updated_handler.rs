use crate::models::deepbook_margin::margin_registry::PriceToleranceUpdated;
use deepbook_schema::models::PriceToleranceUpdated as PriceToleranceUpdatedModel;

define_handler! {
    name: PriceToleranceUpdatedHandler,
    processor_name: "price_tolerance_updated",
    event_type: PriceToleranceUpdated,
    db_model: PriceToleranceUpdatedModel,
    table: price_tolerance_updated,
    map_event: |event, meta| PriceToleranceUpdatedModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        tolerance: event.tolerance as i64,
        onchain_timestamp: event.timestamp as i64,
    }
}
