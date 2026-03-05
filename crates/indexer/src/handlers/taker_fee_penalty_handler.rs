use crate::models::deepbook::state::TakerFeePenaltyApplied;
use deepbook_schema::models::TakerFeePenaltyApplied as TakerFeePenaltyAppliedModel;

define_handler! {
    name: TakerFeePenaltyHandler,
    processor_name: "taker_fee_penalty_applied",
    event_type: TakerFeePenaltyApplied,
    db_model: TakerFeePenaltyAppliedModel,
    table: taker_fee_penalty_applied,
    map_event: |event, meta| TakerFeePenaltyAppliedModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        balance_manager_id: event.balance_manager_id.to_string(),
        order_id: event.order_id.to_string(),
        taker_fee_without_penalty: event.taker_fee_without_penalty as i64,
        taker_fee: event.taker_fee as i64,
    }
}
