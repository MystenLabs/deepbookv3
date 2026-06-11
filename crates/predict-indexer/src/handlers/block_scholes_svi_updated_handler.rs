use crate::meta::PredictEventMeta;
use crate::models::{BlockScholesSVIUpdated as Ev, I64};
use bigdecimal::BigDecimal;
use predict_schema::models::BlockScholesSVIUpdated as Row;

/// Collapse an `I64` magnitude/sign into a single signed `BigDecimal`.
fn signed(v: &I64) -> BigDecimal {
    let m = BigDecimal::from(v.magnitude);
    if v.is_negative {
        -m
    } else {
        m
    }
}

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
        market_oracle_id: ev.market_oracle_id.to_string(),
        a: BigDecimal::from(ev.a),
        b: BigDecimal::from(ev.b),
        rho: signed(&ev.rho),
        m: signed(&ev.m),
        sigma: BigDecimal::from(ev.sigma),
        // Unix ms timestamp.
        source_timestamp_ms: ev.source_timestamp_ms as i64,
        // Unix ms timestamp.
        update_timestamp_ms: ev.update_timestamp_ms as i64,
    }
}

crate::define_predict_handler! {
    name: BlockScholesSVIUpdatedHandler,
    processor_name: "block_scholes_svi_updated",
    event_type: crate::models::BlockScholesSVIUpdated,
    db_model: predict_schema::models::BlockScholesSVIUpdated,
    table: block_scholes_svi_updated,
    map_event: |event, meta| map(&event, &meta)
}
