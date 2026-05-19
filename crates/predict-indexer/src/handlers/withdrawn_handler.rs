use crate::models::predict::Withdrawn;
use deepbook_predict_schema::models::PredictEventWithdrawn;

define_predict_handler! {
    name: WithdrawnHandler,
    processor_name: "predict_withdrawn",
    event_type: Withdrawn,
    db_model: PredictEventWithdrawn,
    table: predict_events_withdrawn,
    map_event: |event, meta| PredictEventWithdrawn {
        tx_digest: meta.digest(),
        event_index: meta.event_index as i64,
        checkpoint: meta.checkpoint(),
        timestamp: meta.checkpoint_timestamp_ms(),
        predict_id: event.predict_id.to_string(),
        withdrawer: event.withdrawer.to_string(),
        quote_asset: event.quote_asset.to_string(),
        amount: event.amount as i64,
        shares_burned: event.shares_burned as i64,
    }
}
