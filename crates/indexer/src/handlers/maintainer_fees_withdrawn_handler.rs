use crate::models::deepbook_margin::margin_pool::MaintainerFeesWithdrawn;
use deepbook_schema::models::MaintainerFeesWithdrawn as MaintainerFeesWithdrawnModel;

define_handler! {
    name: MaintainerFeesWithdrawnHandler,
    processor_name: "maintainer_fees_withdrawn",
    event_type: MaintainerFeesWithdrawn,
    db_model: MaintainerFeesWithdrawnModel,
    table: maintainer_fees_withdrawn,
    map_event: |event, meta| MaintainerFeesWithdrawnModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        margin_pool_id: event.margin_pool_id.to_string(),
        margin_pool_cap_id: event.margin_pool_cap_id.to_string(),
        maintainer_fees: event.maintainer_fees as i64,
        onchain_timestamp: event.timestamp as i64,
    }
}
