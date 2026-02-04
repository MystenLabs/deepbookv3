CREATE INDEX IF NOT EXISTS idx_order_fills_pool_id_checkpoint_timestamp_ms
    ON order_fills (pool_id, checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_order_fills_pool_id_checkpoint_timestamp_ms_desc
    ON order_fills (pool_id, checkpoint_timestamp_ms DESC);

CREATE INDEX IF NOT EXISTS idx_order_fills_maker_balance_manager_id
    ON order_fills (maker_balance_manager_id);

CREATE INDEX IF NOT EXISTS idx_order_fills_taker_balance_manager_id
    ON order_fills (taker_balance_manager_id);

CREATE INDEX IF NOT EXISTS idx_order_updates_pool_id_status_balance_manager_id
    ON order_updates (pool_id, status, balance_manager_id);

CREATE INDEX IF NOT EXISTS idx_balances_balance_manager_id_asset_deposit
    ON balances (balance_manager_id, asset) WHERE deposit = true;

CREATE INDEX IF NOT EXISTS idx_collateral_events_margin_manager_id_checkpoint_timestamp_ms
    ON collateral_events (margin_manager_id, checkpoint_timestamp_ms DESC);

CREATE INDEX IF NOT EXISTS idx_margin_manager_state_deepbook_pool_id
    ON margin_manager_state (deepbook_pool_id);
