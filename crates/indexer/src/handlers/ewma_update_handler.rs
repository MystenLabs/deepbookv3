use crate::models::deepbook::ewma::EWMAUpdate;
use deepbook_schema::models::EwmaUpdate;

define_handler! {
    name: EwmaUpdateHandler,
    processor_name: "ewma_updates",
    event_type: EWMAUpdate,
    db_model: EwmaUpdate,
    table: ewma_updates,
    map_event: |event, meta| EwmaUpdate {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        gas_price: event.gas_price as i64,
        mean: event.mean as i64,
        variance: event.variance as i64,
        onchain_timestamp: event.timestamp as i64,
    }
}
