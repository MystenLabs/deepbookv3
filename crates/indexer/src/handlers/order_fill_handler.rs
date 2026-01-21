use crate::models::deepbook::order_info::OrderFilled;
use deepbook_schema::models::OrderFill;

define_handler! {
    name: OrderFillHandler,
    processor_name: "order_fill",
    event_type: OrderFilled,
    db_model: OrderFill,
    table: order_fills,
    map_event: |event, meta| OrderFill {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        maker_order_id: event.maker_order_id.to_string(),
        taker_order_id: event.taker_order_id.to_string(),
        maker_client_order_id: event.maker_client_order_id as i64,
        taker_client_order_id: event.taker_client_order_id as i64,
        price: event.price as i64,
        taker_is_bid: event.taker_is_bid,
        taker_fee: event.taker_fee as i64,
        taker_fee_is_deep: event.taker_fee_is_deep,
        maker_fee: event.maker_fee as i64,
        maker_fee_is_deep: event.maker_fee_is_deep,
        base_quantity: event.base_quantity as i64,
        quote_quantity: event.quote_quantity as i64,
        maker_balance_manager_id: event.maker_balance_manager_id.to_string(),
        taker_balance_manager_id: event.taker_balance_manager_id.to_string(),
        onchain_timestamp: event.timestamp as i64,
    }
}
