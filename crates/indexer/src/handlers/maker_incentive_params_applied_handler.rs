use crate::models::maker_incentives::maker_incentives::FundParamsChangeApplied;
use deepbook_schema::models::MakerIncentiveParamsApplied;

define_handler! {
    name: MakerIncentiveParamsAppliedHandler,
    processor_name: "maker_incentive_params_applied",
    event_type: FundParamsChangeApplied,
    db_model: MakerIncentiveParamsApplied,
    table: maker_incentive_params_applied,
    map_event: |event, meta| MakerIncentiveParamsApplied {
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
    }
}
