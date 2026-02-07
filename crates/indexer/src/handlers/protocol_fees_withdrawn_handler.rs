use crate::models::deepbook_margin::margin_pool::ProtocolFeesWithdrawn;
use deepbook_schema::models::ProtocolFeesWithdrawn as ProtocolFeesWithdrawnModel;

define_handler! {
    name: ProtocolFeesWithdrawnHandler,
    processor_name: "protocol_fees_withdrawn",
    event_type: ProtocolFeesWithdrawn,
    db_model: ProtocolFeesWithdrawnModel,
    table: protocol_fees_withdrawn,
    map_event: |event, meta| ProtocolFeesWithdrawnModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        margin_pool_id: event.margin_pool_id.to_string(),
        protocol_fees: event.protocol_fees as i64,
        onchain_timestamp: event.timestamp as i64,
    }
}
