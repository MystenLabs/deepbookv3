use bigdecimal::BigDecimal;

use crate::models::deepbook_margin::margin_manager::DepositCollateralEvent;
use deepbook_schema::models::CollateralEvent;

define_handler! {
    name: DepositCollateralHandler,
    processor_name: "deposit_collateral",
    event_type: DepositCollateralEvent,
    db_model: CollateralEvent,
    table: collateral_events,
    map_event: |event, meta| CollateralEvent {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        event_type: "deposit".to_string(),
        margin_manager_id: event.margin_manager_id.to_string(),
        amount: BigDecimal::from(event.amount),
        asset_type: event.asset.name.clone(),
        pyth_decimals: event.pyth_decimals as i16,
        pyth_price: BigDecimal::from(event.pyth_price),
        withdraw_base_asset: None,
        base_pyth_decimals: None,
        base_pyth_price: None,
        quote_pyth_decimals: None,
        quote_pyth_price: None,
        remaining_base_asset: None,
        remaining_quote_asset: None,
        remaining_base_debt: None,
        remaining_quote_debt: None,
        onchain_timestamp: event.timestamp as i64,
    }
}
