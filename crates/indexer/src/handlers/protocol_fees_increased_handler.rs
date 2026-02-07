use crate::models::deepbook_margin::protocol_fees::ProtocolFeesIncreasedEvent;
use deepbook_schema::models::ProtocolFeesIncreasedEvent as ProtocolFeesIncreasedEventModel;

define_handler! {
    name: ProtocolFeesIncreasedHandler,
    processor_name: "protocol_fees_increased",
    event_type: ProtocolFeesIncreasedEvent,
    db_model: ProtocolFeesIncreasedEventModel,
    table: protocol_fees_increased,
    map_event: |event, meta| ProtocolFeesIncreasedEventModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        margin_pool_id: event.margin_pool_id.to_string(),
        total_shares: event.total_shares as i64,
        referral_fees: event.referral_fees as i64,
        maintainer_fees: event.maintainer_fees as i64,
        protocol_fees: event.protocol_fees as i64,
        onchain_timestamp: meta.checkpoint_timestamp_ms(), // No timestamp in event
    }
}
