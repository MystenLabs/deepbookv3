use crate::models::deepbook::deep_price::PriceAdded;
use deepbook_schema::models::PoolPrice;

define_handler! {
    name: PoolPriceHandler,
    processor_name: "pool_price",
    event_type: PriceAdded,
    db_model: PoolPrice,
    table: pool_prices,
    map_event: |event, meta| PoolPrice {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        target_pool: event.target_pool.to_string(),
        conversion_rate: event.conversion_rate as i64,
        reference_pool: event.reference_pool.to_string(),
    }
}
