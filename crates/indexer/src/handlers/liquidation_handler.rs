use crate::define_handler;
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
    }
}
