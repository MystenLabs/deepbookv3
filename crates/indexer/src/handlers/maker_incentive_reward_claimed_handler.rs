use crate::models::maker_incentives::maker_incentives::RewardClaimed;
use deepbook_schema::models::MakerIncentiveRewardClaimed;

define_handler! {
    name: MakerIncentiveRewardClaimedHandler,
    processor_name: "maker_incentive_reward_claimed",
    event_type: RewardClaimed,
    db_model: MakerIncentiveRewardClaimed,
    table: maker_incentive_reward_claimed,
    map_event: |event, meta| MakerIncentiveRewardClaimed {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        fund_id: event.fund_id.to_string(),
        epoch_start_ms: event.epoch_start_ms as i64,
        balance_manager_id: event.balance_manager_id.to_string(),
        amount: event.amount as i64,
    }
}
