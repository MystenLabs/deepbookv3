-- Composite index for ticker endpoint queries that filter by pool_id and timestamp range
-- This dramatically improves queries like:
--   SELECT ... FROM order_fills WHERE pool_id = ANY(...) AND checkpoint_timestamp_ms BETWEEN ...
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_order_fills_pool_id_checkpoint_timestamp_ms
    ON order_fills (pool_id, checkpoint_timestamp_ms);

-- Index for queries that need to sort by pool_id and then timestamp (used in DISTINCT ON queries)
-- This helps the "last price" query in the ticker endpoint
CREATE INDEX CONCURRENTLY IF NOT EXISTS idx_order_fills_pool_id_checkpoint_timestamp_ms_desc
    ON order_fills (pool_id, checkpoint_timestamp_ms DESC);
