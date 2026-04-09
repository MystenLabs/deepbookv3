use crate::models::maker_incentives::maker_incentives::TreasuryWithdrawn;
use deepbook_schema::models::MakerIncentiveTreasuryWithdrawn;

define_handler! {
    name: MakerIncentiveTreasuryWithdrawnHandler,
    processor_name: "maker_incentive_treasury_withdrawn",
    event_type: TreasuryWithdrawn,
    db_model: MakerIncentiveTreasuryWithdrawn,
    table: maker_incentive_treasury_withdrawn,
    map_event: |event, meta| MakerIncentiveTreasuryWithdrawn {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        fund_id: event.fund_id.to_string(),
        owner: event.owner.to_string(),
        amount: event.amount as i64,
        treasury_after: event.treasury_after as i64,
        locked_after: event.locked_after as i64,
        withdrawable_after: event.withdrawable_after as i64,
        reward_per_epoch: event.reward_per_epoch as i64,
    }
}
