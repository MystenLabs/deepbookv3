-- Index for /orders endpoint: supports DISTINCT ON (order_id) with ORDER BY order_id, checkpoint_timestamp_ms DESC
-- Used by latest_events CTE in get_orders_status query
CREATE INDEX IF NOT EXISTS idx_order_updates_pool_order_ts_desc
    ON order_updates (pool_id, order_id, checkpoint_timestamp_ms DESC);

-- Partial index for placed_events CTE: only indexes rows where status = 'Placed'
-- Supports DISTINCT ON (order_id) with ORDER BY order_id, checkpoint_timestamp_ms ASC
CREATE INDEX IF NOT EXISTS idx_order_updates_pool_placed_order_ts
    ON order_updates (pool_id, order_id, checkpoint_timestamp_ms)
    WHERE status = 'Placed';
