use crate::models::deepbook_margin::margin_pool::SupplyReferralMinted;
use deepbook_schema::models::SupplyReferralMinted as SupplyReferralMintedModel;

define_handler! {
    name: SupplyReferralMintedHandler,
    processor_name: "supply_referral_minted",
    event_type: SupplyReferralMinted,
    db_model: SupplyReferralMintedModel,
    table: supply_referral_minted,
    map_event: |event, meta| SupplyReferralMintedModel {
        event_digest: meta.event_digest(),
        digest: meta.digest(),
        sender: meta.sender(),
        checkpoint: meta.checkpoint(),
        checkpoint_timestamp_ms: meta.checkpoint_timestamp_ms(),
        package: meta.package(),
        margin_pool_id: event.margin_pool_id.to_string(),
        supply_referral_id: event.supply_referral_id.to_string(),
        owner: event.owner.to_string(),
        onchain_timestamp: event.timestamp as i64,
    }
}
