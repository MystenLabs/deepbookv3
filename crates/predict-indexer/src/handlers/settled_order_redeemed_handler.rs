use crate::meta::PredictEventMeta;
use crate::models::SettledOrderRedeemed as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::SettledOrderRedeemed as Row;

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
        predict_manager_id: ev.predict_manager_id.to_string(),
        order_id: ev.order_id.to_string(),
        position_root_id: ev.position_root_id.to_string(),
        owner: ev.owner.to_string(),
        quantity_closed: BigDecimal::from(ev.quantity_closed),
        settlement_price: BigDecimal::from(ev.settlement_price),
        payout_amount: BigDecimal::from(ev.payout_amount),
    }
}

crate::define_predict_handler! {
    name: SettledOrderRedeemedHandler,
    processor_name: "settled_order_redeemed",
    event_type: crate::models::SettledOrderRedeemed,
    db_model: predict_schema::models::SettledOrderRedeemed,
    table: settled_order_redeemed,
    map_event: |event, meta| map(&event, &meta)
}
