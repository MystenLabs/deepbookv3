use crate::models::deepbook_margin::margin_manager::LoanBorrowedEvent;
use deepbook_schema::models::LoanBorrowed;

define_handler! {
    name: LoanBorrowedHandler,
    processor_name: "loan_borrowed",
    event_type: LoanBorrowedEvent,
    db_model: LoanBorrowed,
    table: loan_borrowed,
    map_event: |event, meta| LoanBorrowed {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        margin_manager_id: event.margin_manager_id.to_string(),
        margin_pool_id: event.margin_pool_id.to_string(),
        loan_amount: event.loan_amount as i64,
        loan_shares: event.loan_shares as i64,
        onchain_timestamp: event.timestamp as i64,
    }
}
