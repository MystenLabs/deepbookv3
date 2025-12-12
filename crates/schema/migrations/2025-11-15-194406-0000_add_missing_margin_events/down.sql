-- Drop indexes
DROP INDEX IF EXISTS idx_maintainer_fees_withdrawn_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_maintainer_fees_withdrawn_margin_pool_id;
DROP INDEX IF EXISTS idx_maintainer_fees_withdrawn_margin_pool_cap_id;
DROP INDEX IF EXISTS idx_protocol_fees_withdrawn_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_protocol_fees_withdrawn_margin_pool_id;
DROP INDEX IF EXISTS idx_supplier_cap_minted_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_supplier_cap_minted_supplier_cap_id;
DROP INDEX IF EXISTS idx_supply_referral_minted_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_supply_referral_minted_margin_pool_id;
DROP INDEX IF EXISTS idx_supply_referral_minted_owner;
DROP INDEX IF EXISTS idx_supply_referral_minted_supply_referral_id;
DROP INDEX IF EXISTS idx_pause_cap_updated_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_pause_cap_updated_pause_cap_id;
DROP INDEX IF EXISTS idx_protocol_fees_increased_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_protocol_fees_increased_margin_pool_id;
DROP INDEX IF EXISTS idx_referral_fees_claimed_checkpoint_timestamp_ms;
DROP INDEX IF EXISTS idx_referral_fees_claimed_referral_id;
DROP INDEX IF EXISTS idx_referral_fees_claimed_owner;

-- Drop tables
DROP TABLE IF EXISTS maintainer_fees_withdrawn;
DROP TABLE IF EXISTS protocol_fees_withdrawn;
DROP TABLE IF EXISTS supplier_cap_minted;
DROP TABLE IF EXISTS supply_referral_minted;
DROP TABLE IF EXISTS pause_cap_updated;
DROP TABLE IF EXISTS protocol_fees_increased;
DROP TABLE IF EXISTS referral_fees_claimed;

