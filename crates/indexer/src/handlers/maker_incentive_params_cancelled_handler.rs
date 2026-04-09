use crate::models::maker_incentives::maker_incentives::FundParamsChangeCancelled;
use deepbook_schema::models::MakerIncentiveParamsCancelled;

define_handler! {
    name: MakerIncentiveParamsCancelledHandler,
    processor_name: "maker_incentive_params_cancelled",
    event_type: FundParamsChangeCancelled,
    db_model: MakerIncentiveParamsCancelled,
    table: maker_incentive_params_cancelled,
    map_event: |event, meta| MakerIncentiveParamsCancelled {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        fund_id: event.fund_id.to_string(),
    }
}
