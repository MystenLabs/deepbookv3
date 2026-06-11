use crate::meta::PredictEventMeta;
use crate::models::PredictWithdrawCapMinted as Ev;
use predict_schema::models::PredictWithdrawCapMinted as Row;

pub fn map(ev: &Ev, meta: &PredictEventMeta) -> Row {
    Row {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        tx_index: meta.tx_index(),
        event_index: meta.event_index(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        predict_manager_id: ev.predict_manager_id.to_string(),
        cap_id: ev.cap_id.to_string(),
    }
}

crate::define_predict_handler! {
    name: PredictWithdrawCapMintedHandler,
    processor_name: "predict_withdraw_cap_minted",
    event_type: crate::models::PredictWithdrawCapMinted,
    db_model: predict_schema::models::PredictWithdrawCapMinted,
    table: predict_withdraw_cap_minted,
    map_event: |event, meta| map(&event, &meta)
}
