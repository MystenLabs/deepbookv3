use crate::models::deepbook::state::RebateEventV2;
use deepbook_schema::models::RebatesV2;

define_handler! {
    name: RebatesV2Handler,
    processor_name: "rebates_v2",
    event_type: RebateEventV2,
    db_model: RebatesV2,
    table: rebates_v2,
    map_event: |event, meta| RebatesV2 {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        balance_manager_id: event.balance_manager_id.to_string(),
        epoch: event.epoch as i64,
        claim_base: event.claim_amount.base as i64,
        claim_quote: event.claim_amount.quote as i64,
        claim_deep: event.claim_amount.deep as i64,
    }
}
