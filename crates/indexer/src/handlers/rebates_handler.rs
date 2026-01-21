use crate::models::deepbook::state::RebateEvent;
use deepbook_schema::models::Rebates;

define_handler! {
    name: RebatesHandler,
    processor_name: "rebates",
    event_type: RebateEvent,
    db_model: Rebates,
    table: rebates,
    map_event: |event, meta| Rebates {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        balance_manager_id: event.balance_manager_id.to_string(),
        epoch: event.epoch as i64,
        claim_amount: event.claim_amount as i64,
    }
}
