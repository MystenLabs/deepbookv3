use crate::models::deepbook_margin::margin_manager::MarginManagerCreatedEvent;
use deepbook_schema::models::MarginManagerCreated;

define_handler! {
    name: MarginManagerCreatedHandler,
    processor_name: "margin_manager_created",
    event_type: MarginManagerCreatedEvent,
    db_model: MarginManagerCreated,
    table: margin_manager_created,
    map_event: |event, meta| MarginManagerCreated {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        margin_manager_id: event.margin_manager_id.to_string(),
        balance_manager_id: event.balance_manager_id.to_string(),
        deepbook_pool_id: Some(event.deepbook_pool_id.to_string()),
        owner: event.owner.to_string(),
        onchain_timestamp: event.timestamp as i64,
    }
}
