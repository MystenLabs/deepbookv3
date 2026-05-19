use crate::models::predict::PositionRedeemed;
use deepbook_predict_schema::models::PredictEventRedeemed;

define_predict_handler! {
    name: RedeemedHandler,
    processor_name: "predict_redeemed",
    event_type: PositionRedeemed,
    db_model: PredictEventRedeemed,
    table: predict_events_redeemed,
    map_event: |event, meta| PredictEventRedeemed {
        tx_digest: meta.digest(),
        event_index: meta.event_index as i64,
        checkpoint: meta.checkpoint(),
        timestamp: meta.checkpoint_timestamp_ms(),
        predict_id: event.predict_id.to_string(),
        manager_id: event.manager_id.to_string(),
        owner: event.owner.to_string(),
        executor: event.executor.to_string(),
        quote_asset: event.quote_asset.to_string(),
        oracle_id: event.oracle_id.to_string(),
        expiry: event.expiry as i64,
        strike: event.strike as i64,
        is_up: event.is_up,
        quantity: event.quantity as i64,
        payout: event.payout as i64,
        fee_amount: event.fee_amount as i64,
        is_settled: event.is_settled,
    }
}
