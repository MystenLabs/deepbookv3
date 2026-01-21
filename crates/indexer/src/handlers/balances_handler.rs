use crate::models::deepbook::balance_manager::BalanceEvent;
use deepbook_schema::models::Balances;

define_handler! {
    name: BalancesHandler,
    processor_name: "balances",
    event_type: BalanceEvent,
    db_model: Balances,
    table: balances,
    map_event: |event, meta| Balances {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        balance_manager_id: event.balance_manager_id.to_string(),
        asset: event.asset.to_string(),
        amount: event.amount as i64,
        deposit: event.deposit,
    }
}
