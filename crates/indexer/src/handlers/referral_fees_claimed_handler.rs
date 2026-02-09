use crate::models::deepbook_margin::protocol_fees::ReferralFeesClaimedEvent;
use deepbook_schema::models::ReferralFeesClaimedEvent as ReferralFeesClaimedEventModel;

define_handler! {
    name: ReferralFeesClaimedHandler,
    processor_name: "referral_fees_claimed",
    event_type: ReferralFeesClaimedEvent,
    db_model: ReferralFeesClaimedEventModel,
    table: referral_fees_claimed,
    map_event: |event, meta| ReferralFeesClaimedEventModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        referral_id: event.referral_id.to_string(),
        owner: event.owner.to_string(),
        fees: event.fees as i64,
        onchain_timestamp: meta.checkpoint_timestamp_ms(), // No timestamp in event
    }
}
