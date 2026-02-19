use crate::models::deepbook::balance_manager::BalanceManagerEvent;
use deepbook_schema::models::BalanceManagerEvent as BalanceManagerEventModel;

define_handler! {
    name: BalanceManagerEventHandler,
    processor_name: "balance_manager_event",
    event_type: BalanceManagerEvent,
    db_model: BalanceManagerEventModel,
    table: balance_managers,
    map_event: |event, meta| BalanceManagerEventModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        balance_manager_id: event.balance_manager_id.to_string(),
        owner: event.owner.to_string(),
    }
}
