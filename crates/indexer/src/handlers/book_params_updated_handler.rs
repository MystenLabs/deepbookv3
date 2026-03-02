use crate::models::deepbook::pool::BookParamsUpdated;
use deepbook_schema::models::BookParamsUpdated as BookParamsUpdatedModel;

define_handler! {
    name: BookParamsUpdatedHandler,
    processor_name: "book_params_updated",
    event_type: BookParamsUpdated<crate::models::sui::sui::SUI, crate::models::sui::sui::SUI>,
    db_model: BookParamsUpdatedModel,
    table: book_params_updated,
    map_event: |event, meta| BookParamsUpdatedModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        tick_size: event.tick_size as i64,
        lot_size: event.lot_size as i64,
        min_size: event.min_size as i64,
        onchain_timestamp: event.timestamp as i64,
    }
}
