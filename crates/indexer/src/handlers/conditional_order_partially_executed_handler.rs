use bigdecimal::BigDecimal;

use crate::models::deepbook_margin::tpsl::ConditionalOrderPartiallyExecuted as ConditionalOrderPartiallyExecutedEvent;
use deepbook_schema::models::ConditionalOrderEvent;

define_handler! {
    name: ConditionalOrderPartiallyExecutedHandler,
    processor_name: "conditional_order_partially_executed",
    event_type: ConditionalOrderPartiallyExecutedEvent,
    db_model: ConditionalOrderEvent,
    table: conditional_order_events,
    map_event: |event, meta| ConditionalOrderEvent {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        event_type: "partially_executed".to_string(),
        manager_id: event.manager_id.to_string(),
        pool_id: Some(event.pool_id.to_string()),
        conditional_order_id: event.conditional_order_id as i64,
        trigger_below_price: event.conditional_order.condition.trigger_below_price,
        trigger_price: BigDecimal::from(event.conditional_order.condition.trigger_price),
        is_limit_order: event.conditional_order.pending_order.is_limit_order,
        client_order_id: event.conditional_order.pending_order.client_order_id as i64,
        order_type: event.conditional_order.pending_order.order_type.unwrap_or(0) as i16,
        self_matching_option: event.conditional_order.pending_order.self_matching_option as i16,
        price: BigDecimal::from(event.conditional_order.pending_order.price.unwrap_or(0)),
        quantity: BigDecimal::from(event.conditional_order.pending_order.quantity),
        is_bid: event.conditional_order.pending_order.is_bid,
        pay_with_deep: event.conditional_order.pending_order.pay_with_deep,
        expire_timestamp: event.conditional_order.pending_order.expire_timestamp.unwrap_or(0) as i64,
        onchain_timestamp: event.timestamp as i64,
    }
}

#[cfg(test)]
mod tests {
    use crate::models::deepbook_margin::tpsl::ConditionalOrderPartiallyExecuted;
    use crate::traits::MoveStruct;
    use crate::DeepbookEnv;
    use move_core_types::language_storage::StructTag;
    use std::str::FromStr;

    // Testnet margin v17's on-chain type_origin_table assigns this new event to
    // the upgrade package, rather than to the original margin package address.
    #[test]
    fn matches_testnet_partial_order_event_origin() {
        let event = StructTag::from_str(
            "0x0ad965f35189c7eca57d4718c8f5bf1b7f9f7eb4ced6d5b7aa6496a16d71e8d2::tpsl::ConditionalOrderPartiallyExecuted",
        )
        .unwrap();
        assert!(ConditionalOrderPartiallyExecuted::matches_event_type(
            &event,
            DeepbookEnv::Testnet,
        ));
        assert!(!ConditionalOrderPartiallyExecuted::matches_event_type(
            &event,
            DeepbookEnv::Mainnet,
        ));
    }
}
