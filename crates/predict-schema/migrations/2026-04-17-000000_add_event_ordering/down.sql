ALTER TABLE predict_manager_created DROP COLUMN IF EXISTS event_index;
ALTER TABLE predict_manager_created DROP COLUMN IF EXISTS tx_index;

ALTER TABLE quote_asset_disabled DROP COLUMN IF EXISTS event_index;
ALTER TABLE quote_asset_disabled DROP COLUMN IF EXISTS tx_index;

ALTER TABLE quote_asset_enabled DROP COLUMN IF EXISTS event_index;
ALTER TABLE quote_asset_enabled DROP COLUMN IF EXISTS tx_index;

ALTER TABLE oracle_ask_bounds_cleared DROP COLUMN IF EXISTS event_index;
ALTER TABLE oracle_ask_bounds_cleared DROP COLUMN IF EXISTS tx_index;

ALTER TABLE oracle_ask_bounds_set DROP COLUMN IF EXISTS event_index;
ALTER TABLE oracle_ask_bounds_set DROP COLUMN IF EXISTS tx_index;

ALTER TABLE risk_config_updated DROP COLUMN IF EXISTS event_index;
ALTER TABLE risk_config_updated DROP COLUMN IF EXISTS tx_index;

ALTER TABLE pricing_config_updated DROP COLUMN IF EXISTS event_index;
ALTER TABLE pricing_config_updated DROP COLUMN IF EXISTS tx_index;

ALTER TABLE trading_pause_updated DROP COLUMN IF EXISTS event_index;
ALTER TABLE trading_pause_updated DROP COLUMN IF EXISTS tx_index;

ALTER TABLE withdrawn DROP COLUMN IF EXISTS event_index;
ALTER TABLE withdrawn DROP COLUMN IF EXISTS tx_index;

ALTER TABLE supplied DROP COLUMN IF EXISTS event_index;
ALTER TABLE supplied DROP COLUMN IF EXISTS tx_index;

ALTER TABLE range_redeemed DROP COLUMN IF EXISTS event_index;
ALTER TABLE range_redeemed DROP COLUMN IF EXISTS tx_index;

ALTER TABLE range_minted DROP COLUMN IF EXISTS event_index;
ALTER TABLE range_minted DROP COLUMN IF EXISTS tx_index;

ALTER TABLE position_redeemed DROP COLUMN IF EXISTS event_index;
ALTER TABLE position_redeemed DROP COLUMN IF EXISTS tx_index;

ALTER TABLE position_minted DROP COLUMN IF EXISTS event_index;
ALTER TABLE position_minted DROP COLUMN IF EXISTS tx_index;

ALTER TABLE oracle_created DROP COLUMN IF EXISTS event_index;
ALTER TABLE oracle_created DROP COLUMN IF EXISTS tx_index;

ALTER TABLE predict_created DROP COLUMN IF EXISTS event_index;
ALTER TABLE predict_created DROP COLUMN IF EXISTS tx_index;

ALTER TABLE oracle_svi_updated DROP COLUMN IF EXISTS event_index;
ALTER TABLE oracle_svi_updated DROP COLUMN IF EXISTS tx_index;

ALTER TABLE oracle_prices_updated DROP COLUMN IF EXISTS event_index;
ALTER TABLE oracle_prices_updated DROP COLUMN IF EXISTS tx_index;

ALTER TABLE oracle_settled DROP COLUMN IF EXISTS event_index;
ALTER TABLE oracle_settled DROP COLUMN IF EXISTS tx_index;

ALTER TABLE oracle_activated DROP COLUMN IF EXISTS event_index;
ALTER TABLE oracle_activated DROP COLUMN IF EXISTS tx_index;
