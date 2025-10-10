CREATE TABLE IF NOT EXISTS ohclv_1m (
    pool_id TEXT NOT NULL,
    bucket_time TIMESTAMP NOT NULL,
    open NUMERIC NOT NULL,
    high NUMERIC NOT NULL,
    low NUMERIC NOT NULL,
    close NUMERIC NOT NULL,
    base_volume NUMERIC NOT NULL,
    quote_volume NUMERIC NOT NULL,
    trade_count INTEGER NOT NULL,
    first_trade_timestamp BIGINT NOT NULL,
    last_trade_timestamp BIGINT NOT NULL,
    PRIMARY KEY (pool_id, bucket_time)
);

CREATE TABLE IF NOT EXISTS ohclv_1d (
    pool_id TEXT NOT NULL,
    bucket_time DATE NOT NULL,
    open NUMERIC NOT NULL,
    high NUMERIC NOT NULL,
    low NUMERIC NOT NULL,
    close NUMERIC NOT NULL,
    base_volume NUMERIC NOT NULL,
    quote_volume NUMERIC NOT NULL,
    trade_count INTEGER NOT NULL,
    first_trade_timestamp BIGINT NOT NULL,
    last_trade_timestamp BIGINT NOT NULL,
    PRIMARY KEY (pool_id, bucket_time)
);

CREATE INDEX IF NOT EXISTS idx_ohclv_1m_pool_time ON ohclv_1m (pool_id, bucket_time DESC);
CREATE INDEX IF NOT EXISTS idx_ohclv_1m_time ON ohclv_1m (bucket_time DESC);
CREATE INDEX IF NOT EXISTS idx_ohclv_1d_pool_time ON ohclv_1d (pool_id, bucket_time DESC);
CREATE INDEX IF NOT EXISTS idx_ohclv_1d_time ON ohclv_1d (bucket_time DESC);

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
        FIRST_VALUE(f.price::numeric / POWER(10, p.quote_asset_decimals))
            OVER (PARTITION BY f.pool_id, date_trunc('minute', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))
                  ORDER BY f.checkpoint_timestamp_ms
                  ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) as open,
        MAX(f.price::numeric / POWER(10, p.quote_asset_decimals))
            OVER (PARTITION BY f.pool_id, date_trunc('minute', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))) as high,
        MIN(f.price::numeric / POWER(10, p.quote_asset_decimals))
            OVER (PARTITION BY f.pool_id, date_trunc('minute', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))) as low,
        LAST_VALUE(f.price::numeric / POWER(10, p.quote_asset_decimals))
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
        FIRST_VALUE(f.price::numeric / POWER(10, p.quote_asset_decimals))
            OVER (PARTITION BY f.pool_id, date_trunc('day', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))
                  ORDER BY f.checkpoint_timestamp_ms
                  ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING) as open,
        MAX(f.price::numeric / POWER(10, p.quote_asset_decimals))
            OVER (PARTITION BY f.pool_id, date_trunc('day', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))) as high,
        MIN(f.price::numeric / POWER(10, p.quote_asset_decimals))
            OVER (PARTITION BY f.pool_id, date_trunc('day', to_timestamp(f.checkpoint_timestamp_ms / 1000.0))) as low,
        LAST_VALUE(f.price::numeric / POWER(10, p.quote_asset_decimals))
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

-- combine intervals 
CREATE OR REPLACE FUNCTION get_ohclv(
    p_interval TEXT,
    p_pool_id TEXT DEFAULT NULL,
    p_start_time TIMESTAMP DEFAULT NULL,
    p_end_time TIMESTAMP DEFAULT NULL,
    p_limit INTEGER DEFAULT 1000
)
RETURNS TABLE (
    pool_id TEXT,
    bucket_time TIMESTAMP,
    open NUMERIC,
    high NUMERIC,
    low NUMERIC,
    close NUMERIC,
    base_volume NUMERIC,
    quote_volume NUMERIC,
    trade_count INTEGER,
    first_trade_timestamp BIGINT,
    last_trade_timestamp BIGINT
)
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_start_time IS NULL THEN
        p_start_time := NOW() - INTERVAL '7 days';
    END IF;

    IF p_end_time IS NULL THEN
        p_end_time := NOW();
    END IF;

    CASE p_interval
        WHEN '1m' THEN
            RETURN QUERY
            SELECT
                o.pool_id, o.bucket_time::TIMESTAMP, o.open, o.high, o.low, o.close,
                o.base_volume, o.quote_volume, o.trade_count,
                o.first_trade_timestamp, o.last_trade_timestamp
            FROM ohclv_1m o
            WHERE (p_pool_id IS NULL OR o.pool_id = p_pool_id)
              AND o.bucket_time >= p_start_time
              AND o.bucket_time <= p_end_time
            ORDER BY o.bucket_time DESC
            LIMIT p_limit;

        WHEN '5m' THEN
            RETURN QUERY
            SELECT
                o.pool_id,
                date_trunc('hour', o.bucket_time) + INTERVAL '5 minutes' * FLOOR(EXTRACT(minute FROM o.bucket_time) / 5) as bucket_time,
                (array_agg(o.open ORDER BY o.bucket_time))[1] as open,
                MAX(o.high) as high,
                MIN(o.low) as low,
                (array_agg(o.close ORDER BY o.bucket_time DESC))[1] as close,
                SUM(o.base_volume) as base_volume,
                SUM(o.quote_volume) as quote_volume,
                SUM(o.trade_count)::INTEGER as trade_count,
                MIN(o.first_trade_timestamp) as first_trade_timestamp,
                MAX(o.last_trade_timestamp) as last_trade_timestamp
            FROM ohclv_1m o
            WHERE (p_pool_id IS NULL OR o.pool_id = p_pool_id)
              AND o.bucket_time >= p_start_time
              AND o.bucket_time <= p_end_time
            GROUP BY o.pool_id, date_trunc('hour', o.bucket_time) + INTERVAL '5 minutes' * FLOOR(EXTRACT(minute FROM o.bucket_time) / 5)
            ORDER BY bucket_time DESC
            LIMIT p_limit;

        WHEN '15m' THEN
            RETURN QUERY
            SELECT
                o.pool_id,
                date_trunc('hour', o.bucket_time) + INTERVAL '15 minutes' * FLOOR(EXTRACT(minute FROM o.bucket_time) / 15) as bucket_time,
                (array_agg(o.open ORDER BY o.bucket_time))[1] as open,
                MAX(o.high) as high,
                MIN(o.low) as low,
                (array_agg(o.close ORDER BY o.bucket_time DESC))[1] as close,
                SUM(o.base_volume) as base_volume,
                SUM(o.quote_volume) as quote_volume,
                SUM(o.trade_count)::INTEGER as trade_count,
                MIN(o.first_trade_timestamp) as first_trade_timestamp,
                MAX(o.last_trade_timestamp) as last_trade_timestamp
            FROM ohclv_1m o
            WHERE (p_pool_id IS NULL OR o.pool_id = p_pool_id)
              AND o.bucket_time >= p_start_time
              AND o.bucket_time <= p_end_time
            GROUP BY o.pool_id, date_trunc('hour', o.bucket_time) + INTERVAL '15 minutes' * FLOOR(EXTRACT(minute FROM o.bucket_time) / 15)
            ORDER BY bucket_time DESC
            LIMIT p_limit;

        WHEN '30m' THEN
            RETURN QUERY
            SELECT
                o.pool_id,
                date_trunc('hour', o.bucket_time) + INTERVAL '30 minutes' * FLOOR(EXTRACT(minute FROM o.bucket_time) / 30) as bucket_time,
                (array_agg(o.open ORDER BY o.bucket_time))[1] as open,
                MAX(o.high) as high,
                MIN(o.low) as low,
                (array_agg(o.close ORDER BY o.bucket_time DESC))[1] as close,
                SUM(o.base_volume) as base_volume,
                SUM(o.quote_volume) as quote_volume,
                SUM(o.trade_count)::INTEGER as trade_count,
                MIN(o.first_trade_timestamp) as first_trade_timestamp,
                MAX(o.last_trade_timestamp) as last_trade_timestamp
            FROM ohclv_1m o
            WHERE (p_pool_id IS NULL OR o.pool_id = p_pool_id)
              AND o.bucket_time >= p_start_time
              AND o.bucket_time <= p_end_time
            GROUP BY o.pool_id, date_trunc('hour', o.bucket_time) + INTERVAL '30 minutes' * FLOOR(EXTRACT(minute FROM o.bucket_time) / 30)
            ORDER BY bucket_time DESC
            LIMIT p_limit;

        WHEN '1h' THEN
            RETURN QUERY
            SELECT
                o.pool_id,
                date_trunc('hour', o.bucket_time) as bucket_time,
                (array_agg(o.open ORDER BY o.bucket_time))[1] as open,
                MAX(o.high) as high,
                MIN(o.low) as low,
                (array_agg(o.close ORDER BY o.bucket_time DESC))[1] as close,
                SUM(o.base_volume) as base_volume,
                SUM(o.quote_volume) as quote_volume,
                SUM(o.trade_count)::INTEGER as trade_count,
                MIN(o.first_trade_timestamp) as first_trade_timestamp,
                MAX(o.last_trade_timestamp) as last_trade_timestamp
            FROM ohclv_1m o
            WHERE (p_pool_id IS NULL OR o.pool_id = p_pool_id)
              AND o.bucket_time >= p_start_time
              AND o.bucket_time <= p_end_time
            GROUP BY o.pool_id, date_trunc('hour', o.bucket_time)
            ORDER BY bucket_time DESC
            LIMIT p_limit;

        WHEN '4h' THEN
            RETURN QUERY
            SELECT
                o.pool_id,
                date_trunc('day', o.bucket_time) + INTERVAL '4 hours' * FLOOR(EXTRACT(hour FROM o.bucket_time) / 4) as bucket_time,
                (array_agg(o.open ORDER BY o.bucket_time))[1] as open,
                MAX(o.high) as high,
                MIN(o.low) as low,
                (array_agg(o.close ORDER BY o.bucket_time DESC))[1] as close,
                SUM(o.base_volume) as base_volume,
                SUM(o.quote_volume) as quote_volume,
                SUM(o.trade_count)::INTEGER as trade_count,
                MIN(o.first_trade_timestamp) as first_trade_timestamp,
                MAX(o.last_trade_timestamp) as last_trade_timestamp
            FROM ohclv_1m o
            WHERE (p_pool_id IS NULL OR o.pool_id = p_pool_id)
              AND o.bucket_time >= p_start_time
              AND o.bucket_time <= p_end_time
            GROUP BY o.pool_id, date_trunc('day', o.bucket_time) + INTERVAL '4 hours' * FLOOR(EXTRACT(hour FROM o.bucket_time) / 4)
            ORDER BY bucket_time DESC
            LIMIT p_limit;

        WHEN '1d' THEN
            RETURN QUERY
            SELECT
                o.pool_id, o.bucket_time::TIMESTAMP, o.open, o.high, o.low, o.close,
                o.base_volume, o.quote_volume, o.trade_count,
                o.first_trade_timestamp, o.last_trade_timestamp
            FROM ohclv_1d o
            WHERE (p_pool_id IS NULL OR o.pool_id = p_pool_id)
              AND o.bucket_time >= p_start_time::DATE
              AND o.bucket_time <= p_end_time::DATE
            ORDER BY o.bucket_time DESC
            LIMIT p_limit;

        WHEN '1w' THEN
            RETURN QUERY
            SELECT
                o.pool_id,
                date_trunc('week', o.bucket_time)::TIMESTAMP as bucket_time,
                (array_agg(o.open ORDER BY o.bucket_time))[1] as open,
                MAX(o.high) as high,
                MIN(o.low) as low,
                (array_agg(o.close ORDER BY o.bucket_time DESC))[1] as close,
                SUM(o.base_volume) as base_volume,
                SUM(o.quote_volume) as quote_volume,
                SUM(o.trade_count)::INTEGER as trade_count,
                MIN(o.first_trade_timestamp) as first_trade_timestamp,
                MAX(o.last_trade_timestamp) as last_trade_timestamp
            FROM ohclv_1d o
            WHERE (p_pool_id IS NULL OR o.pool_id = p_pool_id)
              AND o.bucket_time >= p_start_time::DATE
              AND o.bucket_time <= p_end_time::DATE
            GROUP BY o.pool_id, date_trunc('week', o.bucket_time)
            ORDER BY bucket_time DESC
            LIMIT p_limit;

        ELSE
            RAISE EXCEPTION 'Invalid interval: %. Valid intervals are: 1m, 5m, 15m, 30m, 1h, 4h, 1d, 1w', p_interval;
    END CASE;
END;
$$;

CREATE OR REPLACE PROCEDURE update_all_ohclv(
    start_timestamp BIGINT DEFAULT NULL,
    end_timestamp BIGINT DEFAULT NULL
)
LANGUAGE plpgsql
AS $$
BEGIN
    CALL update_ohclv_1m(start_timestamp, end_timestamp);
    CALL update_ohclv_1d(start_timestamp, end_timestamp);
END;
$$;

-- Examples
-- SELECT * FROM get_ohclv('5m', 'pool_123', NOW() - INTERVAL '1 day', NOW(), 100);
-- SELECT * FROM get_ohclv('1h', NULL, NULL, NULL, 500); -- All pools, last 7 days, 500 candles