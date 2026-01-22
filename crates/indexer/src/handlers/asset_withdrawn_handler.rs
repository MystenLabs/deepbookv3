use crate::models::deepbook_margin::margin_pool::AssetWithdrawn;
use deepbook_schema::models::AssetWithdrawn as AssetWithdrawnModel;

define_handler! {
    name: AssetWithdrawnHandler,
    processor_name: "asset_withdrawn",
    event_type: AssetWithdrawn,
    db_model: AssetWithdrawnModel,
    table: asset_withdrawn,
    map_event: |event, meta| AssetWithdrawnModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        margin_pool_id: event.margin_pool_id.to_string(),
        asset_type: event.asset_type.to_string(),
        supplier: event.supplier.to_string(),
        amount: event.withdraw_amount as i64,
        shares: event.withdraw_shares as i64,
        onchain_timestamp: event.timestamp as i64,
    }
}
