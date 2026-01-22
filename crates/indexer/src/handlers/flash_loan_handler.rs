use crate::models::deepbook::vault::FlashLoanBorrowed;
use deepbook_schema::models::Flashloan;

define_handler! {
    name: FlashLoanHandler,
    processor_name: "flash_loan",
    event_type: FlashLoanBorrowed,
    db_model: Flashloan,
    table: flashloans,
    map_event: |event, meta| Flashloan {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        borrow_quantity: event.borrow_quantity as i64,
        borrow: true,
        type_name: event.type_name.to_string(),
    }
}
