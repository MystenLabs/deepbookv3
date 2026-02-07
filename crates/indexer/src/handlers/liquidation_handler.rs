use bigdecimal::BigDecimal;

use crate::models::deepbook_margin::margin_manager::LiquidationEvent;
use deepbook_schema::models::Liquidation;

define_handler! {
    name: LiquidationHandler,
    processor_name: "liquidation",
    event_type: LiquidationEvent,
    db_model: Liquidation,
    table: liquidation,
    map_event: |event, meta| Liquidation {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        margin_manager_id: event.margin_manager_id.to_string(),
        margin_pool_id: event.margin_pool_id.to_string(),
        liquidation_amount: event.liquidation_amount as i64,
        pool_reward: event.pool_reward as i64,
        pool_default: event.pool_default as i64,
        risk_ratio: event.risk_ratio as i64,
        onchain_timestamp: event.timestamp as i64,
        remaining_base_asset: BigDecimal::from(event.remaining_base_asset),
        remaining_quote_asset: BigDecimal::from(event.remaining_quote_asset),
        remaining_base_debt: BigDecimal::from(event.remaining_base_debt),
        remaining_quote_debt: BigDecimal::from(event.remaining_quote_debt),
        base_pyth_price: event.base_pyth_price as i64,
        base_pyth_decimals: event.base_pyth_decimals as i16,
        quote_pyth_price: event.quote_pyth_price as i64,
        quote_pyth_decimals: event.quote_pyth_decimals as i16,
    }
}
