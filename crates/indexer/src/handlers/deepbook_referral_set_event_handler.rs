use crate::models::deepbook::balance_manager::DeepBookReferralSetEvent;
use deepbook_schema::models::DeepBookReferralSetEvent as DeepBookReferralSetEventModel;

define_handler! {
    name: DeepBookReferralSetEventHandler,
    processor_name: "deepbook_referral_set_event",
    event_type: DeepBookReferralSetEvent,
    db_model: DeepBookReferralSetEventModel,
    table: deepbook_referral_set,
    map_event: |event, meta| DeepBookReferralSetEventModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        referral_id: event.referral_id.to_string(),
        balance_manager_id: event.balance_manager_id.to_string(),
    }
}
