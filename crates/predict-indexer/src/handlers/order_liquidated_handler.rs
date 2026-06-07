use crate::meta::PredictEventMeta;
use crate::models::OrderLiquidated as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::OrderLiquidated as Row;

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
        order_id: ev.order_id.to_string(),
        quantity: BigDecimal::from(ev.quantity),
        gross_value: BigDecimal::from(ev.gross_value),
        floor_amount: BigDecimal::from(ev.floor_amount),
        liquidation_ltv: ev.liquidation_ltv as i64,
    }
}

crate::define_predict_handler! {
    name: OrderLiquidatedHandler,
    processor_name: "order_liquidated",
    event_type: crate::models::OrderLiquidated,
    db_model: predict_schema::models::OrderLiquidated,
    table: order_liquidated,
    map_event: |event, meta| map(&event, &meta)
}
