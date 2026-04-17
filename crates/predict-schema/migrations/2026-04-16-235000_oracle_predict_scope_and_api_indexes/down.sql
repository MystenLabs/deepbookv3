DROP INDEX IF EXISTS idx_quote_asset_disabled_predict_event_order;
DROP INDEX IF EXISTS idx_quote_asset_enabled_predict_event_order;
DROP INDEX IF EXISTS idx_withdrawn_predict_id_time;
DROP INDEX IF EXISTS idx_supplied_predict_id_time;
DROP INDEX IF EXISTS idx_position_redeemed_manager_id_market_order;
DROP INDEX IF EXISTS idx_position_minted_manager_id_market_order;
DROP INDEX IF EXISTS idx_oracle_svi_updated_oracle_id_event_order;
DROP INDEX IF EXISTS idx_oracle_prices_updated_oracle_id_event_order;
DROP INDEX IF EXISTS idx_oracle_created_predict_id_event_order;

ALTER TABLE oracle_created
    DROP COLUMN IF EXISTS predict_id;
