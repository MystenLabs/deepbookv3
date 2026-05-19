use crate::models::predict::Supplied;
use deepbook_predict_schema::models::PredictEventSupplied;

define_predict_handler! {
    name: SuppliedHandler,
    processor_name: "predict_supplied",
    event_type: Supplied,
    db_model: PredictEventSupplied,
    table: predict_events_supplied,
    map_event: |event, meta| PredictEventSupplied {
        tx_digest: meta.digest(),
        event_index: meta.event_index as i64,
        checkpoint: meta.checkpoint(),
        timestamp: meta.checkpoint_timestamp_ms(),
        predict_id: event.predict_id.to_string(),
        supplier: event.supplier.to_string(),
        quote_asset: event.quote_asset.to_string(),
        amount: event.amount as i64,
        shares_minted: event.shares_minted as i64,
    }
}
