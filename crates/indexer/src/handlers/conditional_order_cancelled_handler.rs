use bigdecimal::BigDecimal;

use crate::define_handler;
use crate::models::deepbook_margin::tpsl::ConditionalOrderCancelled as ConditionalOrderCancelledEvent;
use deepbook_schema::models::ConditionalOrderCancelled;

define_handler! {
    name: ConditionalOrderCancelledHandler,
    processor_name: "conditional_order_cancelled",
    event_type: ConditionalOrderCancelledEvent,
    db_model: ConditionalOrderCancelled,
    table: conditional_order_cancelled,
    map_event: |event, meta| ConditionalOrderCancelled {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        manager_id: event.manager_id.to_string(),
        conditional_order_id: event.conditional_order_id as i64,
        trigger_below_price: event.conditional_order.condition.trigger_below_price,
        trigger_price: BigDecimal::from(event.conditional_order.condition.trigger_price),
        is_limit_order: event.conditional_order.pending_order.is_limit_order,
        client_order_id: event.conditional_order.pending_order.client_order_id as i64,
        order_type: event.conditional_order.pending_order.order_type as i16,
        self_matching_option: event.conditional_order.pending_order.self_matching_option as i16,
        price: BigDecimal::from(event.conditional_order.pending_order.price),
        quantity: BigDecimal::from(event.conditional_order.pending_order.quantity),
        is_bid: event.conditional_order.pending_order.is_bid,
        pay_with_deep: event.conditional_order.pending_order.pay_with_deep,
        expire_timestamp: event.conditional_order.pending_order.expire_timestamp as i64,
        onchain_timestamp: event.timestamp as i64,
    }
}
