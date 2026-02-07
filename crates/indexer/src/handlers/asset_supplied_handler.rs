use crate::models::deepbook_margin::margin_pool::AssetSupplied;
use deepbook_schema::models::AssetSupplied as AssetSuppliedModel;

define_handler! {
    name: AssetSuppliedHandler,
    processor_name: "asset_supplied",
    event_type: AssetSupplied,
    db_model: AssetSuppliedModel,
    table: asset_supplied,
    map_event: |event, meta| AssetSuppliedModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        margin_pool_id: event.margin_pool_id.to_string(),
        asset_type: event.asset_type.to_string(),
        supplier: event.supplier.to_string(),
        amount: event.supply_amount as i64,
        shares: event.supply_shares as i64,
        onchain_timestamp: event.timestamp as i64,
    }
}
