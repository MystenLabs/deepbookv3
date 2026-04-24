use crate::models::maker_incentives::maker_incentives::EpochResultsSubmitted;
use deepbook_schema::models::MakerIncentiveEpochResultsSubmitted;

define_handler! {
    name: MakerIncentiveEpochResultsSubmittedHandler,
    processor_name: "maker_incentive_epoch_results_submitted",
    event_type: EpochResultsSubmitted,
    db_model: MakerIncentiveEpochResultsSubmitted,
    table: maker_incentive_epoch_results_submitted,
    map_event: |event, meta| MakerIncentiveEpochResultsSubmitted {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        fund_id: event.fund_id.to_string(),
        epoch_start_ms: event.epoch_start_ms as i64,
        epoch_end_ms: event.epoch_end_ms as i64,
        total_allocation: event.total_allocation as i64,
        num_makers: event.num_makers as i64,
    }
}
