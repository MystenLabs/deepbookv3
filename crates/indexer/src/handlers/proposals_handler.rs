use crate::models::deepbook::state::ProposalEvent;
use deepbook_schema::models::Proposals;

define_handler! {
    name: ProposalsHandler,
    processor_name: "proposals",
    event_type: ProposalEvent,
    db_model: Proposals,
    table: proposals,
    map_event: |event, meta| Proposals {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        balance_manager_id: event.balance_manager_id.to_string(),
        epoch: event.epoch as i64,
        taker_fee: event.taker_fee as i64,
        maker_fee: event.maker_fee as i64,
        stake_required: event.stake_required as i64,
    }
}
