-- Materialized view for net deposits aggregated by asset at hourly intervals
-- Stores the net change (deposits - withdrawals) per asset per hour bucket

CREATE MATERIALIZED VIEW IF NOT EXISTS net_deposits_hourly AS
SELECT
    asset,
    -- Truncate to hour boundary (ms)
    (checkpoint_timestamp_ms / 3600000) * 3600000 AS hour_bucket_ms,
    SUM(CASE WHEN deposit THEN amount ELSE -amount END)::BIGINT AS net_amount_delta
FROM balances
GROUP BY asset, (checkpoint_timestamp_ms / 3600000) * 3600000;

-- Unique index required for REFRESH MATERIALIZED VIEW CONCURRENTLY
CREATE UNIQUE INDEX IF NOT EXISTS idx_net_deposits_hourly_asset_bucket
    ON net_deposits_hourly (asset, hour_bucket_ms);

-- Index for efficient lookups by asset with hour ordering
CREATE INDEX IF NOT EXISTS idx_net_deposits_hourly_bucket_asset
    ON net_deposits_hourly (hour_bucket_ms, asset);
