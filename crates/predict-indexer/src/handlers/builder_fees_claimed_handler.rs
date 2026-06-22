use crate::meta::PredictEventMeta;
use crate::models::BuilderFeesClaimed as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::BuilderFeesClaimed as Row;

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
        builder_code_id: ev.builder_code_id.to_string(),
        owner: ev.owner.to_string(),
        amount: BigDecimal::from(ev.amount),
    }
}

crate::define_predict_handler! {
    name: BuilderFeesClaimedHandler,
    processor_name: "builder_fees_claimed",
    event_type: crate::models::BuilderFeesClaimed,
    db_model: predict_schema::models::BuilderFeesClaimed,
    table: builder_fees_claimed,
    map_event: |event, meta| map(&event, &meta)
}
