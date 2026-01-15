use bigdecimal::BigDecimal;

use crate::define_handler;
use crate::models::deepbook_margin::margin_manager::DepositCollateralEvent;
use deepbook_schema::models::DepositCollateral;

define_handler! {
    name: DepositCollateralHandler,
    processor_name: "deposit_collateral",
    event_type: DepositCollateralEvent,
    db_model: DepositCollateral,
    table: deposit_collateral,
    map_event: |event, meta| DepositCollateral {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        margin_manager_id: event.margin_manager_id.to_string(),
        amount: BigDecimal::from(event.amount),
        asset_type: event.asset.name.clone(),
        pyth_decimals: event.pyth_decimals as i16,
        pyth_price: BigDecimal::from(event.pyth_price),
        onchain_timestamp: event.timestamp as i64,
    }
}
