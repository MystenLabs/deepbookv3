-- Fix OHCLV price calculation to use correct formula
-- Correct formula: price_human = price_onchain / 10^(9 - base_decimals + quote_decimals)

CREATE OR REPLACE PROCEDURE update_ohclv_1m(
    start_timestamp BIGINT DEFAULT NULL,
    end_timestamp BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Default to last 24 hours if no range specified
    IF start_timestamp IS NULL THEN
        start_timestamp := (EXTRACT(EPOCH FROM NOW() - INTERVAL '24 hours') * 1000)::BIGINT;
    END IF;

    IF end_timestamp IS NULL THEN
        end_timestamp := (EXTRACT(EPOCH FROM NOW()) * 1000)::BIGINT;
    END IF;

    INSERT INTO ohclv_1m (
        pool_id,
        bucket_time,
        open,
        high,
        low,
        close,
        base_volume,
        quote_volume,
        trade_count,
        first_trade_timestamp,
        last_trade_timestamp
    )
    SELECT DISTINCT ON (pool_id, bucket_time)
        f.pool_id,
        date_trunc('minute', to_timestamp(f.checkpoint_timestamp_ms / 1000.0)) as bucket_time,
        FIRST_VALUE(f.price::numeric / POWER(10, 9 - p.base_asset_decimals + p.quote_asset_decimals))
            OVER (PARTITION BY f.pool_id, date_trunc('minute', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))
                  ORDER BY f.checkpoint_timestamp_ms
                  ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) as open,
        MAX(f.price::numeric / POWER(10, 9 - p.base_asset_decimals + p.quote_asset_decimals))
            OVER (PARTITION BY f.pool_id, date_trunc('minute', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))) as high,
        MIN(f.price::numeric / POWER(10, 9 - p.base_asset_decimals + p.quote_asset_decimals))
            OVER (PARTITION BY f.pool_id, date_trunc('minute', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))) as low,
        LAST_VALUE(f.price::numeric / POWER(10, 9 - p.base_asset_decimals + p.quote_asset_decimals))
            OVER (PARTITION BY f.pool_id, date_trunc('minute', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))
                  ORDER BY f.checkpoint_timestamp_ms
                  ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) as close,
        SUM(f.base_quantity::numeric / POWER(10, p.base_asset_decimals))
            OVER (PARTITION BY f.pool_id, date_trunc('minute', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))) as base_volume,
        SUM(f.quote_quantity::numeric / POWER(10, p.quote_asset_decimals))
            OVER (PARTITION BY f.pool_id, date_trunc('minute', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))) as quote_volume,
        COUNT(*)
            OVER (PARTITION BY f.pool_id, date_trunc('minute', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))) as trade_count,
        MIN(f.checkpoint_timestamp_ms)
            OVER (PARTITION BY f.pool_id, date_trunc('minute', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))) as first_trade_timestamp,
        MAX(f.checkpoint_timestamp_ms)
            OVER (PARTITION BY f.pool_id, date_trunc('minute', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))) as last_trade_timestamp
    FROM order_fills f
    INNER JOIN pools p ON f.pool_id = p.pool_id
    WHERE f.checkpoint_timestamp_ms >= start_timestamp
      AND f.checkpoint_timestamp_ms <= end_timestamp
    ON CONFLICT (pool_id, bucket_time)
    DO UPDATE SET
        high = GREATEST(EXCLUDED.high, ohclv_1m.high),
        low = LEAST(EXCLUDED.low, ohclv_1m.low),
        close = EXCLUDED.close, -- Latest close wins
        base_volume = EXCLUDED.base_volume, -- For simplicity, replace volume
        quote_volume = EXCLUDED.quote_volume,
        trade_count = EXCLUDED.trade_count,
        first_trade_timestamp = LEAST(EXCLUDED.first_trade_timestamp, ohclv_1m.first_trade_timestamp),
        last_trade_timestamp = GREATEST(EXCLUDED.last_trade_timestamp, ohclv_1m.last_trade_timestamp);
END;
$$;

CREATE OR REPLACE PROCEDURE update_ohclv_1d(
    start_timestamp BIGINT DEFAULT NULL,
    end_timestamp BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
BEGIN
    -- Default to last 7 days if no range specified
    IF start_timestamp IS NULL THEN
        start_timestamp := (EXTRACT(EPOCH FROM NOW() - INTERVAL '7 days') * 1000)::BIGINT;
    END IF;

    IF end_timestamp IS NULL THEN
        end_timestamp := (EXTRACT(EPOCH FROM NOW()) * 1000)::BIGINT;
    END IF;

    INSERT INTO ohclv_1d (
        pool_id,
        bucket_time,
        open,
        high,
        low,
        close,
        base_volume,
        quote_volume,
        trade_count,
        first_trade_timestamp,
        last_trade_timestamp
    )
    SELECT DISTINCT ON (pool_id, bucket_time)
        f.pool_id,
        date_trunc('day', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))::DATE as bucket_time,
        FIRST_VALUE(f.price::numeric / POWER(10, 9 - p.base_asset_decimals + p.quote_asset_decimals))
            OVER (PARTITION BY f.pool_id, date_trunc('day', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))
                  ORDER BY f.checkpoint_timestamp_ms
                  ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) as open,
        MAX(f.price::numeric / POWER(10, 9 - p.base_asset_decimals + p.quote_asset_decimals))
            OVER (PARTITION BY f.pool_id, date_trunc('day', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))) as high,
        MIN(f.price::numeric / POWER(10, 9 - p.base_asset_decimals + p.quote_asset_decimals))
            OVER (PARTITION BY f.pool_id, date_trunc('day', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))) as low,
        LAST_VALUE(f.price::numeric / POWER(10, 9 - p.base_asset_decimals + p.quote_asset_decimals))
            OVER (PARTITION BY f.pool_id, date_trunc('day', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))
                  ORDER BY f.checkpoint_timestamp_ms
                  ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) as close,
        SUM(f.base_quantity::numeric / POWER(10, p.base_asset_decimals))
            OVER (PARTITION BY f.pool_id, date_trunc('day', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))) as base_volume,
        SUM(f.quote_quantity::numeric / POWER(10, p.quote_asset_decimals))
            OVER (PARTITION BY f.pool_id, date_trunc('day', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))) as quote_volume,
        COUNT(*)
            OVER (PARTITION BY f.pool_id, date_trunc('day', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))) as trade_count,
        MIN(f.checkpoint_timestamp_ms)
            OVER (PARTITION BY f.pool_id, date_trunc('day', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))) as first_trade_timestamp,
        MAX(f.checkpoint_timestamp_ms)
            OVER (PARTITION BY f.pool_id, date_trunc('day', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))) as last_trade_timestamp
    FROM order_fills f
    INNER JOIN pools p ON f.pool_id = p.pool_id
    WHERE f.checkpoint_timestamp_ms >= start_timestamp
      AND f.checkpoint_timestamp_ms <= end_timestamp
    ON CONFLICT (pool_id, bucket_time)
    DO UPDATE SET
        high = GREATEST(EXCLUDED.high, ohclv_1d.high),
        low = LEAST(EXCLUDED.low, ohclv_1d.low),
        close = EXCLUDED.close,
        base_volume = EXCLUDED.base_volume,
        quote_volume = EXCLUDED.quote_volume,
        trade_count = EXCLUDED.trade_count,
        first_trade_timestamp = LEAST(EXCLUDED.first_trade_timestamp, ohclv_1d.first_trade_timestamp),
        last_trade_timestamp = GREATEST(EXCLUDED.last_trade_timestamp, ohclv_1d.last_trade_timestamp);
END;
$$;

TRUNCATE TABLE ohclv_1m;
TRUNCATE TABLE ohclv_1d;
CALL update_ohclv_1m(NULL, NULL);
CALL update_ohclv_1d(NULL, NULL);
