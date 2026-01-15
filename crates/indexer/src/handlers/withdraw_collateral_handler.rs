use bigdecimal::BigDecimal;

use crate::define_handler;
use crate::models::deepbook_margin::margin_manager::WithdrawCollateralEvent;
use deepbook_schema::models::WithdrawCollateral;

define_handler! {
    name: WithdrawCollateralHandler,
    processor_name: "withdraw_collateral",
    event_type: WithdrawCollateralEvent,
    db_model: WithdrawCollateral,
    table: withdraw_collateral,
    map_event: |event, meta| WithdrawCollateral {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        margin_manager_id: event.margin_manager_id.to_string(),
        amount: BigDecimal::from(event.amount),
        asset_type: event.asset.name.clone(),
        withdraw_base_asset: event.withdraw_base_asset,
        base_pyth_decimals: event.base_pyth_decimals as i16,
        base_pyth_price: BigDecimal::from(event.base_pyth_price),
        quote_pyth_decimals: event.quote_pyth_decimals as i16,
        quote_pyth_price: BigDecimal::from(event.quote_pyth_price),
        remaining_base_asset: BigDecimal::from(event.remaining_base_asset),
        remaining_quote_asset: BigDecimal::from(event.remaining_quote_asset),
        remaining_base_debt: BigDecimal::from(event.remaining_base_debt),
        remaining_quote_debt: BigDecimal::from(event.remaining_quote_debt),
        onchain_timestamp: event.timestamp as i64,
    }
}
