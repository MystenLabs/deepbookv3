use crate::models::maker_incentives::maker_incentives::FundParamsChangeScheduled;
use deepbook_schema::models::MakerIncentiveParamsScheduled;

define_handler! {
    name: MakerIncentiveParamsScheduledHandler,
    processor_name: "maker_incentive_params_scheduled",
    event_type: FundParamsChangeScheduled,
    db_model: MakerIncentiveParamsScheduled,
    table: maker_incentive_params_scheduled,
    map_event: |event, meta| MakerIncentiveParamsScheduled {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        fund_id: event.fund_id.to_string(),
        reward_per_epoch: event.reward_per_epoch as i64,
        alpha_bps: event.alpha_bps as i64,
        quality_p: event.quality_p as i64,
        effective_at_ms: event.effective_at_ms as i64,
        scheduled_at_ms: event.scheduled_at_ms as i64,
    }
}
