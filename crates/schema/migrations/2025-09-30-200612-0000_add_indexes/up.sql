CREATE INDEX IF NOT EXISTS idx_order_fills_checkpoint_timestamp_ms
    ON order_fills (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_order_fills_pool_id_price
    ON order_fills (pool_id, price);

CREATE INDEX IF NOT EXISTS idx_order_updates_checkpoint_timestamp_ms
    ON order_updates (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_order_updates_pool_id_price
    ON order_updates (pool_id, price);

CREATE INDEX IF NOT EXISTS idx_balances_checkpoint_timestamp_ms
    ON balances (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_balances_balance_manager_id
    ON balances (balance_manager_id);

CREATE INDEX IF NOT EXISTS idx_balances_asset
    ON balances (asset);