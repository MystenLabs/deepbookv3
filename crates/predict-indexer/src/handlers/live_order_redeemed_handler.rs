use crate::meta::PredictEventMeta;
use crate::models::LiveOrderRedeemed as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::LiveOrderRedeemed as Row;

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
        remaining_quantity: BigDecimal::from(ev.remaining_quantity),
        replacement_order_id: ev.replacement_order_id.map(|v| v.to_string()),
        redeem_amount: BigDecimal::from(ev.redeem_amount),
        trading_fee: BigDecimal::from(ev.trading_fee),
        builder_fee: BigDecimal::from(ev.builder_fee),
        penalty_fee: BigDecimal::from(ev.penalty_fee),
        builder_code_id: ev.builder_code_id.map(|id| id.to_string()),
    }
}

crate::define_predict_handler! {
    name: LiveOrderRedeemedHandler,
    processor_name: "live_order_redeemed",
    event_type: crate::models::LiveOrderRedeemed,
    db_model: predict_schema::models::LiveOrderRedeemed,
    table: live_order_redeemed,
    map_event: |event, meta| map(&event, &meta)
}
