DROP MATERIALIZED VIEW IF EXISTS net_deposits_hourly;

ALTER TABLE balances
    ALTER COLUMN amount TYPE BIGINT USING amount::BIGINT;

CREATE MATERIALIZED VIEW IF NOT EXISTS net_deposits_hourly AS
SELECT
    asset,
    (checkpoint_timestamp_ms / 3600000) * 3600000 AS hour_bucket_ms,
    SUM(CASE WHEN deposit THEN amount ELSE -amount END)::BIGINT AS net_amount_delta
FROM balances
GROUP BY asset, (checkpoint_timestamp_ms / 3600000) * 3600000;

CREATE UNIQUE INDEX IF NOT EXISTS idx_net_deposits_hourly_asset_bucket
    ON net_deposits_hourly (asset, hour_bucket_ms);

CREATE INDEX IF NOT EXISTS idx_net_deposits_hourly_bucket_asset
    ON net_deposits_hourly (hour_bucket_ms, asset);
