use crate::models::deepbook::balance_manager::DeepBookReferralCreatedEvent;
use deepbook_schema::models::DeepBookReferralCreatedEvent as DeepBookReferralCreatedEventModel;

define_handler! {
    name: DeepBookReferralCreatedEventHandler,
    processor_name: "deepbook_referral_created_event",
    event_type: DeepBookReferralCreatedEvent,
    db_model: DeepBookReferralCreatedEventModel,
    table: deepbook_referral_created,
    map_event: |event, meta| DeepBookReferralCreatedEventModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        referral_id: event.referral_id.to_string(),
        owner: event.owner.to_string(),
    }
}
