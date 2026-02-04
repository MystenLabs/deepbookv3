CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_order_fills_pool_id_checkpoint_timestamp_ms
    ON order_fills (pool_id, checkpoint_timestamp_ms);

CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_order_fills_pool_id_checkpoint_timestamp_ms_desc
    ON order_fills (pool_id, checkpoint_timestamp_ms DESC);
