use crate::models::deepbook_margin::margin_pool::SupplierCapMinted;
use deepbook_schema::models::SupplierCapMinted as SupplierCapMintedModel;

define_handler! {
    name: SupplierCapMintedHandler,
    processor_name: "supplier_cap_minted",
    event_type: SupplierCapMinted,
    db_model: SupplierCapMintedModel,
    table: supplier_cap_minted,
    map_event: |event, meta| SupplierCapMintedModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        supplier_cap_id: event.supplier_cap_id.to_string(),
        onchain_timestamp: event.timestamp as i64,
    }
}
