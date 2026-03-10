use crate::models::deepbook::pool::ReferralClaimed;
use deepbook_schema::models::ReferralClaimed as ReferralClaimedModel;

define_handler! {
    name: ReferralClaimedHandler,
    processor_name: "referral_claimed",
    event_type: ReferralClaimed,
    db_model: ReferralClaimedModel,
    table: referral_claimed,
    map_event: |event, meta| ReferralClaimedModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        referral_id: event.referral_id.to_string(),
        owner: event.owner.to_string(),
        base_amount: event.base_amount as i64,
        quote_amount: event.quote_amount as i64,
        deep_amount: event.deep_amount as i64,
    }
}
