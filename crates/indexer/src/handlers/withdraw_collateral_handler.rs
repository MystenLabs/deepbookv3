use bigdecimal::BigDecimal;

use crate::models::deepbook_margin::margin_manager::WithdrawCollateralEvent;
use deepbook_schema::models::CollateralEvent;

define_handler! {
    name: WithdrawCollateralHandler,
    processor_name: "withdraw_collateral",
    event_type: WithdrawCollateralEvent,
    db_model: CollateralEvent,
    table: collateral_events,
    map_event: |event, meta| CollateralEvent {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        event_type: "withdraw".to_string(),
        margin_manager_id: event.margin_manager_id.to_string(),
        amount: BigDecimal::from(event.amount),
        asset_type: event.asset.name.clone(),
        pyth_decimals: event.base_pyth_decimals as i16,
        pyth_price: BigDecimal::from(event.base_pyth_price),
        withdraw_base_asset: Some(event.withdraw_base_asset),
        base_pyth_decimals: Some(event.base_pyth_decimals as i16),
        base_pyth_price: Some(BigDecimal::from(event.base_pyth_price)),
        quote_pyth_decimals: Some(event.quote_pyth_decimals as i16),
        quote_pyth_price: Some(BigDecimal::from(event.quote_pyth_price)),
        remaining_base_asset: Some(BigDecimal::from(event.remaining_base_asset)),
        remaining_quote_asset: Some(BigDecimal::from(event.remaining_quote_asset)),
        remaining_base_debt: Some(BigDecimal::from(event.remaining_base_debt)),
        remaining_quote_debt: Some(BigDecimal::from(event.remaining_quote_debt)),
        onchain_timestamp: event.timestamp as i64,
    }
}
