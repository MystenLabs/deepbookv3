use crate::models::maker_incentives::maker_incentives::FundCreated;
use deepbook_schema::models::MakerIncentiveFundCreated;

define_handler! {
    name: MakerIncentiveFundCreatedHandler,
    processor_name: "maker_incentive_fund_created",
    event_type: FundCreated,
    db_model: MakerIncentiveFundCreated,
    table: maker_incentive_fund_created,
    map_event: |event, meta| MakerIncentiveFundCreated {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        fund_id: event.fund_id.to_string(),
        reward_per_epoch: event.reward_per_epoch as i64,
        creator: event.creator.to_string(),
        created_at_ms: event.created_at_ms as i64,
    }
}
