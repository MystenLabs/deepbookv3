use crate::models::deepbook::pool::ReferralFeeEvent;
use deepbook_schema::models::ReferralFeeEvent as ReferralFeeEventModel;

define_handler! {
    name: ReferralFeeEventHandler,
    processor_name: "referral_fee_events",
    event_type: ReferralFeeEvent,
    db_model: ReferralFeeEventModel,
    table: referral_fee_events,
    map_event: |event, meta| ReferralFeeEventModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        pool_id: event.pool_id.to_string(),
        referral_id: event.referral_id.to_string(),
        base_fee: event.base_fee as i64,
        quote_fee: event.quote_fee as i64,
        deep_fee: event.deep_fee as i64,
    }
}
