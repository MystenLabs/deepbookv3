use crate::meta::PredictEventMeta;
use crate::models::ExpiryMarketMintPausedUpdated as Ev;
use predict_schema::models::ExpiryMarketMintPausedUpdated as Row;

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
        expiry_market_id: ev.expiry_market_id.to_string(),
        paused: ev.paused,
    }
}

crate::define_predict_handler! {
    name: ExpiryMarketMintPausedUpdatedHandler,
    processor_name: "expiry_market_mint_paused_updated",
    event_type: crate::models::ExpiryMarketMintPausedUpdated,
    db_model: predict_schema::models::ExpiryMarketMintPausedUpdated,
    table: expiry_market_mint_paused_updated,
    map_event: |event, meta| map(&event, &meta)
}
