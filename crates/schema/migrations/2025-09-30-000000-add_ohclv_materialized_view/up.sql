-- Create OHCLV data with materialized views

-- Create time_interval type if it doesn't exist
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'time_interval') THEN
        CREATE TYPE time_interval AS ENUM ('1m', '5m', '15m', '30m', '1h', '4h', '1d', '1w');
    END IF;
END$$;

-- Create materialized view if it doesn't exist
CREATE MATERIALIZED VIEW IF NOT EXISTS ohclv_data AS
WITH interval_data AS (
    -- 1 minute intervals
    SELECT
        f.pool_id,
        '1m'::time_interval as interval,
        date_trunc('minute', to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) as bucket_time,
        f.price::numeric / POWER(10, p.quote_asset_decimals) as adjusted_price,
        f.base_quantity::numeric / POWER(10, p.base_asset_decimals) as adjusted_base_quantity,
        f.quote_quantity::numeric / POWER(10, p.quote_asset_decimals) as adjusted_quote_quantity,
        f.checkpoint_timestamp_ms
    FROM order_fills f
    INNER JOIN pools p ON f.pool_id = p.pool_id

    UNION ALL

    -- 5 minute intervals
    SELECT
        f.pool_id,
        '5m'::time_interval as interval,
        date_trunc('hour', to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) +
        INTERVAL '5 min' * FLOOR(EXTRACT(minute FROM to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) / 5) as bucket_time,
        f.price::numeric / POWER(10, p.quote_asset_decimals) as adjusted_price,
        f.base_quantity::numeric / POWER(10, p.base_asset_decimals) as adjusted_base_quantity,
        f.quote_quantity::numeric / POWER(10, p.quote_asset_decimals) as adjusted_quote_quantity,
        f.checkpoint_timestamp_ms
    FROM order_fills f
    INNER JOIN pools p ON f.pool_id = p.pool_id

    UNION ALL

    -- 15 minute intervals
    SELECT
        f.pool_id,
        '15m'::time_interval as interval,
        date_trunc('hour', to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) +
        INTERVAL '15 min' * FLOOR(EXTRACT(minute FROM to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) / 15) as bucket_time,
        f.price::numeric / POWER(10, p.quote_asset_decimals) as adjusted_price,
        f.base_quantity::numeric / POWER(10, p.base_asset_decimals) as adjusted_base_quantity,
        f.quote_quantity::numeric / POWER(10, p.quote_asset_decimals) as adjusted_quote_quantity,
        f.checkpoint_timestamp_ms
    FROM order_fills f
    INNER JOIN pools p ON f.pool_id = p.pool_id

    UNION ALL

    -- 30 minute intervals
    SELECT
        f.pool_id,
        '30m'::time_interval as interval,
        date_trunc('hour', to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) +
        INTERVAL '30 min' * FLOOR(EXTRACT(minute FROM to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) / 30) as bucket_time,
        f.price::numeric / POWER(10, p.quote_asset_decimals) as adjusted_price,
        f.base_quantity::numeric / POWER(10, p.base_asset_decimals) as adjusted_base_quantity,
        f.quote_quantity::numeric / POWER(10, p.quote_asset_decimals) as adjusted_quote_quantity,
        f.checkpoint_timestamp_ms
    FROM order_fills f
    INNER JOIN pools p ON f.pool_id = p.pool_id

    UNION ALL

    -- 1 hour intervals
    SELECT
        f.pool_id,
        '1h'::time_interval as interval,
        date_trunc('hour', to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) as bucket_time,
        f.price::numeric / POWER(10, p.quote_asset_decimals) as adjusted_price,
        f.base_quantity::numeric / POWER(10, p.base_asset_decimals) as adjusted_base_quantity,
        f.quote_quantity::numeric / POWER(10, p.quote_asset_decimals) as adjusted_quote_quantity,
        f.checkpoint_timestamp_ms
    FROM order_fills f
    INNER JOIN pools p ON f.pool_id = p.pool_id

    UNION ALL

    -- 4 hour intervals
    SELECT
        f.pool_id,
        '4h'::time_interval as interval,
        date_trunc('day', to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) +
        INTERVAL '4 hour' * FLOOR(EXTRACT(hour FROM to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) / 4) as bucket_time,
        f.price::numeric / POWER(10, p.quote_asset_decimals) as adjusted_price,
        f.base_quantity::numeric / POWER(10, p.base_asset_decimals) as adjusted_base_quantity,
        f.quote_quantity::numeric / POWER(10, p.quote_asset_decimals) as adjusted_quote_quantity,
        f.checkpoint_timestamp_ms
    FROM order_fills f
    INNER JOIN pools p ON f.pool_id = p.pool_id

    UNION ALL

    -- 1 day intervals
    SELECT
        f.pool_id,
        '1d'::time_interval as interval,
        date_trunc('day', to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) as bucket_time,
        f.price::numeric / POWER(10, p.quote_asset_decimals) as adjusted_price,
        f.base_quantity::numeric / POWER(10, p.base_asset_decimals) as adjusted_base_quantity,
        f.quote_quantity::numeric / POWER(10, p.quote_asset_decimals) as adjusted_quote_quantity,
        f.checkpoint_timestamp_ms
    FROM order_fills f
    INNER JOIN pools p ON f.pool_id = p.pool_id

    UNION ALL

    -- 1 week intervals
    SELECT
        f.pool_id,
        '1w'::time_interval as interval,
        date_trunc('week', to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) as bucket_time,
        f.price::numeric / POWER(10, p.quote_asset_decimals) as adjusted_price,
        f.base_quantity::numeric / POWER(10, p.base_asset_decimals) as adjusted_base_quantity,
        f.quote_quantity::numeric / POWER(10, p.quote_asset_decimals) as adjusted_quote_quantity,
        f.checkpoint_timestamp_ms
    FROM order_fills f
    INNER JOIN pools p ON f.pool_id = p.pool_id
)
SELECT DISTINCT ON (pool_id, interval, bucket_time)
    pool_id,
    interval,
    bucket_time,
    FIRST_VALUE(adjusted_price) OVER (
        PARTITION BY pool_id, interval, bucket_time
        ORDER BY checkpoint_timestamp_ms
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) as open,
    MAX(adjusted_price) OVER (
        PARTITION BY pool_id, interval, bucket_time
    ) as high,
    MIN(adjusted_price) OVER (
        PARTITION BY pool_id, interval, bucket_time
    ) as low,
    LAST_VALUE(adjusted_price) OVER (
        PARTITION BY pool_id, interval, bucket_time
        ORDER BY checkpoint_timestamp_ms
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    ) as close,
    SUM(adjusted_base_quantity) OVER (
        PARTITION BY pool_id, interval, bucket_time
    ) as base_volume,
    SUM(adjusted_quote_quantity) OVER (
        PARTITION BY pool_id, interval, bucket_time
    ) as quote_volume,
    COUNT(*) OVER (
        PARTITION BY pool_id, interval, bucket_time
    ) as trade_count,
    MIN(checkpoint_timestamp_ms) OVER (
        PARTITION BY pool_id, interval, bucket_time
    ) as first_trade_timestamp,
    MAX(checkpoint_timestamp_ms) OVER (
        PARTITION BY pool_id, interval, bucket_time
    ) as last_trade_timestamp
FROM interval_data;

-- Create indexes if they don't exist
CREATE INDEX IF NOT EXISTS idx_ohclv_pool_interval_time ON ohclv_data (pool_id, interval, bucket_time DESC);
CREATE INDEX IF NOT EXISTS idx_ohclv_time ON ohclv_data (bucket_time DESC);
CREATE INDEX IF NOT EXISTS idx_ohclv_pool_time ON ohclv_data (pool_id, bucket_time DESC);

CREATE OR REPLACE FUNCTION refresh_ohclv_data()
RETURNS void AS $$
BEGIN
    REFRESH MATERIALIZED VIEW CONCURRENTLY ohclv_data;
END;
$$ LANGUAGE plpgsql;

CREATE OR REPLACE PROCEDURE incremental_refresh_ohclv(
    start_timestamp BIGINT DEFAULT NULL,
    end_timestamp BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF start_timestamp IS NULL THEN
        start_timestamp := (EXTRACT(EPOCH FROM NOW() - INTERVAL '24 hours') * 1000)::BIGINT;
    END IF;

    IF end_timestamp IS NULL THEN
        end_timestamp := (EXTRACT(EPOCH FROM NOW()) * 1000)::BIGINT;
    END IF;

    DELETE FROM ohclv_data
    WHERE last_trade_timestamp >= start_timestamp
      AND first_trade_timestamp <= end_timestamp;

    INSERT INTO ohclv_data
    WITH interval_data AS (
        SELECT
            f.pool_id,
            '1m'::time_interval as interval,
            date_trunc('minute', to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) as bucket_time,
            f.price::numeric / POWER(10, p.quote_asset_decimals) as adjusted_price,
            f.base_quantity::numeric / POWER(10, p.base_asset_decimals) as adjusted_base_quantity,
            f.quote_quantity::numeric / POWER(10, p.quote_asset_decimals) as adjusted_quote_quantity,
            f.checkpoint_timestamp_ms
        FROM order_fills f
        INNER JOIN pools p ON f.pool_id = p.pool_id
        WHERE f.checkpoint_timestamp_ms >= start_timestamp
          AND f.checkpoint_timestamp_ms <= end_timestamp

        UNION ALL

        SELECT
            f.pool_id,
            '5m'::time_interval as interval,
            date_trunc('hour', to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) +
            INTERVAL '5 min' * FLOOR(EXTRACT(minute FROM to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) / 5) as bucket_time,
            f.price::numeric / POWER(10, p.quote_asset_decimals) as adjusted_price,
            f.base_quantity::numeric / POWER(10, p.base_asset_decimals) as adjusted_base_quantity,
            f.quote_quantity::numeric / POWER(10, p.quote_asset_decimals) as adjusted_quote_quantity,
            f.checkpoint_timestamp_ms
        FROM order_fills f
        INNER JOIN pools p ON f.pool_id = p.pool_id
        WHERE f.checkpoint_timestamp_ms >= start_timestamp
          AND f.checkpoint_timestamp_ms <= end_timestamp

        UNION ALL

        SELECT
            f.pool_id,
            '15m'::time_interval as interval,
            date_trunc('hour', to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) +
            INTERVAL '15 min' * FLOOR(EXTRACT(minute FROM to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) / 15) as bucket_time,
            f.price::numeric / POWER(10, p.quote_asset_decimals) as adjusted_price,
            f.base_quantity::numeric / POWER(10, p.base_asset_decimals) as adjusted_base_quantity,
            f.quote_quantity::numeric / POWER(10, p.quote_asset_decimals) as adjusted_quote_quantity,
            f.checkpoint_timestamp_ms
        FROM order_fills f
        INNER JOIN pools p ON f.pool_id = p.pool_id
        WHERE f.checkpoint_timestamp_ms >= start_timestamp
          AND f.checkpoint_timestamp_ms <= end_timestamp

        UNION ALL

        SELECT
            f.pool_id,
            '30m'::time_interval as interval,
            date_trunc('hour', to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) +
            INTERVAL '30 min' * FLOOR(EXTRACT(minute FROM to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) / 30) as bucket_time,
            f.price::numeric / POWER(10, p.quote_asset_decimals) as adjusted_price,
            f.base_quantity::numeric / POWER(10, p.base_asset_decimals) as adjusted_base_quantity,
            f.quote_quantity::numeric / POWER(10, p.quote_asset_decimals) as adjusted_quote_quantity,
            f.checkpoint_timestamp_ms
        FROM order_fills f
        INNER JOIN pools p ON f.pool_id = p.pool_id
        WHERE f.checkpoint_timestamp_ms >= start_timestamp
          AND f.checkpoint_timestamp_ms <= end_timestamp

        UNION ALL

        SELECT
            f.pool_id,
            '1h'::time_interval as interval,
            date_trunc('hour', to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) as bucket_time,
            f.price::numeric / POWER(10, p.quote_asset_decimals) as adjusted_price,
            f.base_quantity::numeric / POWER(10, p.base_asset_decimals) as adjusted_base_quantity,
            f.quote_quantity::numeric / POWER(10, p.quote_asset_decimals) as adjusted_quote_quantity,
            f.checkpoint_timestamp_ms
        FROM order_fills f
        INNER JOIN pools p ON f.pool_id = p.pool_id
        WHERE f.checkpoint_timestamp_ms >= start_timestamp
          AND f.checkpoint_timestamp_ms <= end_timestamp

        UNION ALL

        SELECT
            f.pool_id,
            '4h'::time_interval as interval,
            date_trunc('day', to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) +
            INTERVAL '4 hour' * FLOOR(EXTRACT(hour FROM to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) / 4) as bucket_time,
            f.price::numeric / POWER(10, p.quote_asset_decimals) as adjusted_price,
            f.base_quantity::numeric / POWER(10, p.base_asset_decimals) as adjusted_base_quantity,
            f.quote_quantity::numeric / POWER(10, p.quote_asset_decimals) as adjusted_quote_quantity,
            f.checkpoint_timestamp_ms
        FROM order_fills f
        INNER JOIN pools p ON f.pool_id = p.pool_id
        WHERE f.checkpoint_timestamp_ms >= start_timestamp
          AND f.checkpoint_timestamp_ms <= end_timestamp

        UNION ALL

        SELECT
            f.pool_id,
            '1d'::time_interval as interval,
            date_trunc('day', to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) as bucket_time,
            f.price::numeric / POWER(10, p.quote_asset_decimals) as adjusted_price,
            f.base_quantity::numeric / POWER(10, p.base_asset_decimals) as adjusted_base_quantity,
            f.quote_quantity::numeric / POWER(10, p.quote_asset_decimals) as adjusted_quote_quantity,
            f.checkpoint_timestamp_ms
        FROM order_fills f
        INNER JOIN pools p ON f.pool_id = p.pool_id
        WHERE f.checkpoint_timestamp_ms >= start_timestamp
          AND f.checkpoint_timestamp_ms <= end_timestamp

        UNION ALL

        SELECT
            f.pool_id,
            '1w'::time_interval as interval,
            date_trunc('week', to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) as bucket_time,
            f.price::numeric / POWER(10, p.quote_asset_decimals) as adjusted_price,
            f.base_quantity::numeric / POWER(10, p.base_asset_decimals) as adjusted_base_quantity,
            f.quote_quantity::numeric / POWER(10, p.quote_asset_decimals) as adjusted_quote_quantity,
            f.checkpoint_timestamp_ms
        FROM order_fills f
        INNER JOIN pools p ON f.pool_id = p.pool_id
        WHERE f.checkpoint_timestamp_ms >= start_timestamp
          AND f.checkpoint_timestamp_ms <= end_timestamp
    )
    SELECT DISTINCT ON (pool_id, interval, bucket_time)
        pool_id,
        interval,
        bucket_time,
        FIRST_VALUE(adjusted_price) OVER w as open,
        MAX(adjusted_price) OVER w as high,
        MIN(adjusted_price) OVER w as low,
        LAST_VALUE(adjusted_price) OVER w as close,
        SUM(adjusted_base_quantity) OVER w as base_volume,
        SUM(adjusted_quote_quantity) OVER w as quote_volume,
        COUNT(*) OVER w as trade_count,
        MIN(checkpoint_timestamp_ms) OVER w as first_trade_timestamp,
        MAX(checkpoint_timestamp_ms) OVER w as last_trade_timestamp
    FROM interval_data
    WINDOW w AS (
        PARTITION BY pool_id, interval, bucket_time
        ORDER BY checkpoint_timestamp_ms
        ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING
    );
END;
$$;