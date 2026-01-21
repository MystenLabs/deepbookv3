use crate::models::deepbook::state::VoteEvent;
use deepbook_schema::models::Votes;

define_handler! {
    name: VotesHandler,
    processor_name: "votes",
    event_type: VoteEvent,
    db_model: Votes,
    table: votes,
    map_event: |event, meta| Votes {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        balance_manager_id: event.balance_manager_id.to_string(),
        epoch: event.epoch as i64,
        from_proposal_id: event.from_proposal_id.map(|id| id.to_string()),
        to_proposal_id: event.to_proposal_id.to_string(),
        stake: event.stake as i64,
    }
}
