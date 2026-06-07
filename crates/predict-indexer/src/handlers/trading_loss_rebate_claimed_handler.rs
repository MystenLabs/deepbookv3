use crate::meta::PredictEventMeta;
use crate::models::TradingLossRebateClaimed as Ev;
use bigdecimal::BigDecimal;
use predict_schema::models::TradingLossRebateClaimed as Row;

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
        trading_fees_paid: BigDecimal::from(ev.trading_fees_paid),
        gross_profit: BigDecimal::from(ev.gross_profit),
        eligible_rebate: BigDecimal::from(ev.eligible_rebate),
        rebate_amount: BigDecimal::from(ev.rebate_amount),
    }
}

crate::define_predict_handler! {
    name: TradingLossRebateClaimedHandler,
    processor_name: "trading_loss_rebate_claimed",
    event_type: crate::models::TradingLossRebateClaimed,
    db_model: predict_schema::models::TradingLossRebateClaimed,
    table: trading_loss_rebate_claimed,
    map_event: |event, meta| map(&event, &meta)
}
