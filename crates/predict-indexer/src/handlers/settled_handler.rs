use crate::models::oracle::OracleSettled;
use deepbook_predict_schema::models::PredictEventOracleSettled;

define_predict_handler! {
    name: SettledHandler,
    processor_name: "predict_oracle_settled",
    event_type: OracleSettled,
    db_model: PredictEventOracleSettled,
    table: predict_events_oracle_settled,
    map_event: |event, meta| PredictEventOracleSettled {
        tx_digest: meta.digest(),
        event_index: meta.event_index as i64,
        checkpoint: meta.checkpoint(),
        timestamp: meta.checkpoint_timestamp_ms(),
        oracle_id: event.oracle_id.to_string(),
        expiry: event.expiry as i64,
        settlement_price: event.settlement_price as i64,
        spot_timestamp_ms: event.spot_timestamp_ms as i64,
    }
}
