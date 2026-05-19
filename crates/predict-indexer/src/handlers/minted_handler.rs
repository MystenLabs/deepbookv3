use crate::models::predict::PositionMinted;
use deepbook_predict_schema::models::PredictEventMinted;

define_predict_handler! {
    name: MintedHandler,
    processor_name: "predict_minted",
    event_type: PositionMinted,
    db_model: PredictEventMinted,
    table: predict_events_minted,
    map_event: |event, meta| PredictEventMinted {
        tx_digest: meta.digest(),
        event_index: meta.event_index as i64,
        checkpoint: meta.checkpoint(),
        timestamp: meta.checkpoint_timestamp_ms(),
        predict_id: event.predict_id.to_string(),
        manager_id: event.manager_id.to_string(),
        trader: event.trader.to_string(),
        quote_asset: event.quote_asset.to_string(),
        oracle_id: event.oracle_id.to_string(),
        expiry: event.expiry as i64,
        strike: event.strike as i64,
        is_up: event.is_up,
        quantity: event.quantity as i64,
        cost: event.cost as i64,
        fee_amount: event.fee_amount as i64,
    }
}
