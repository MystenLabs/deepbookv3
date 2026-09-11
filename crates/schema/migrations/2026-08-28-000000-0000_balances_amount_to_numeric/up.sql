-- Store on-chain u64 deposit amounts losslessly. The previous BIGINT column
-- (signed i64) wrapped values above i64::MAX via `amount as i64` in the indexer.
-- net_deposits_hourly depends on balances.amount, so drop it before the type change.

DROP MATERIALIZED VIEW IF EXISTS net_deposits_hourly;

ALTER TABLE balances
    ALTER COLUMN amount TYPE NUMERIC USING amount::NUMERIC;

CREATE MATERIALIZED VIEW IF NOT EXISTS net_deposits_hourly AS
SELECT
    asset,
    (checkpoint_timestamp_ms / 3600000) * 3600000 AS hour_bucket_ms,
    SUM(CASE WHEN deposit THEN amount ELSE -amount END) AS net_amount_delta
FROM balances
GROUP BY asset, (checkpoint_timestamp_ms / 3600000) * 3600000;

CREATE UNIQUE INDEX IF NOT EXISTS idx_net_deposits_hourly_asset_bucket
    ON net_deposits_hourly (asset, hour_bucket_ms);

CREATE INDEX IF NOT EXISTS idx_net_deposits_hourly_bucket_asset
    ON net_deposits_hourly (hour_bucket_ms, asset);
