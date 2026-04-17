-- Per-maker materialized view for epoch pool health metrics.
-- Keyed on (pool_id, epoch_start_ms, balance_manager_id).
-- Pool-level aggregates are derived from this view in the API layer.

CREATE MATERIALIZED VIEW IF NOT EXISTS pool_epoch_maker_metrics AS
WITH
-- All "Placed" orders with epoch / 1-hour window assignment
placed AS (
    SELECT
        pool_id,
        balance_manager_id,
        order_id,
        price::FLOAT8                                        AS price,
        original_quantity::FLOAT8                             AS qty,
        is_bid,
        (checkpoint_timestamp_ms / 86400000) * 86400000      AS epoch_start_ms,
        ((checkpoint_timestamp_ms % 86400000) / 3600000)::INT AS window_idx
    FROM order_updates
    WHERE status = 'Placed'
),

-- Per-maker fill statistics
maker_fills AS (
    SELECT
        pool_id,
        (checkpoint_timestamp_ms / 86400000) * 86400000     AS epoch_start_ms,
        maker_balance_manager_id                             AS balance_manager_id,
        COUNT(*)::BIGINT                                     AS fill_count,
        SUM(base_quantity)::BIGINT                           AS base_volume,
        SUM(quote_quantity)::BIGINT                          AS quote_volume,
        -- Net flow: taker_is_bid => taker buys base => maker sells base (negative base, positive quote)
        SUM(CASE WHEN taker_is_bid THEN -base_quantity ELSE base_quantity END)::BIGINT  AS net_base_flow,
        SUM(CASE WHEN taker_is_bid THEN quote_quantity ELSE -quote_quantity END)::BIGINT AS net_quote_flow
    FROM order_fills
    GROUP BY pool_id,
             (checkpoint_timestamp_ms / 86400000) * 86400000,
             maker_balance_manager_id
),

-- Per-maker per-window quoting statistics
maker_window AS (
    SELECT
        pool_id,
        epoch_start_ms,
        balance_manager_id,
        window_idx,
        SUM(CASE WHEN is_bid THEN price * qty ELSE 0 END) /
            NULLIF(SUM(CASE WHEN is_bid THEN qty ELSE 0 END), 0)     AS vwap_bid,
        SUM(CASE WHEN NOT is_bid THEN price * qty ELSE 0 END) /
            NULLIF(SUM(CASE WHEN NOT is_bid THEN qty ELSE 0 END), 0) AS vwap_ask,
        BOOL_OR(is_bid) AND BOOL_OR(NOT is_bid)                      AS has_two_sided,
        SUM(CASE WHEN is_bid THEN qty ELSE 0 END)                    AS bid_depth,
        SUM(CASE WHEN NOT is_bid THEN qty ELSE 0 END)                AS ask_depth,
        COUNT(DISTINCT order_id)::BIGINT                              AS order_count
    FROM placed
    GROUP BY pool_id, epoch_start_ms, balance_manager_id, window_idx
),

-- Extract spread for two-sided windows only (used by maker_epoch and maker_depth_bands)
maker_window_mid AS (
    SELECT
        pool_id,
        epoch_start_ms,
        balance_manager_id,
        window_idx,
        (vwap_bid + vwap_ask) / 2.0 AS mid_price,
        (vwap_ask - vwap_bid) / ((vwap_ask + vwap_bid) / 2.0) * 10000.0 AS spread_bps
    FROM maker_window
    WHERE has_two_sided AND vwap_bid > 0 AND vwap_ask > vwap_bid
),

-- Per-maker depth within bps bands per window (using maker's own mid as reference)
maker_depth_bands AS (
    SELECT
        p.pool_id,
        p.epoch_start_ms,
        p.balance_manager_id,
        w.window_idx,
        -- 5 bps
        SUM(CASE WHEN p.is_bid AND p.price >= w.mid_price * 0.9995 THEN p.qty ELSE 0 END) AS bid_5,
        SUM(CASE WHEN NOT p.is_bid AND p.price <= w.mid_price * 1.0005 THEN p.qty ELSE 0 END) AS ask_5,
        -- 10 bps
        SUM(CASE WHEN p.is_bid AND p.price >= w.mid_price * 0.999 THEN p.qty ELSE 0 END) AS bid_10,
        SUM(CASE WHEN NOT p.is_bid AND p.price <= w.mid_price * 1.001 THEN p.qty ELSE 0 END) AS ask_10,
        -- 25 bps
        SUM(CASE WHEN p.is_bid AND p.price >= w.mid_price * 0.9975 THEN p.qty ELSE 0 END) AS bid_25,
        SUM(CASE WHEN NOT p.is_bid AND p.price <= w.mid_price * 1.0025 THEN p.qty ELSE 0 END) AS ask_25,
        -- 50 bps
        SUM(CASE WHEN p.is_bid AND p.price >= w.mid_price * 0.995 THEN p.qty ELSE 0 END) AS bid_50,
        SUM(CASE WHEN NOT p.is_bid AND p.price <= w.mid_price * 1.005 THEN p.qty ELSE 0 END) AS ask_50,
        -- 100 bps
        SUM(CASE WHEN p.is_bid AND p.price >= w.mid_price * 0.99 THEN p.qty ELSE 0 END) AS bid_100,
        SUM(CASE WHEN NOT p.is_bid AND p.price <= w.mid_price * 1.01 THEN p.qty ELSE 0 END) AS ask_100
    FROM placed p
    JOIN maker_window_mid w
        ON  p.pool_id = w.pool_id
        AND p.epoch_start_ms = w.epoch_start_ms
        AND p.balance_manager_id = w.balance_manager_id
        AND p.window_idx = w.window_idx
    GROUP BY p.pool_id, p.epoch_start_ms, p.balance_manager_id, w.window_idx
),

-- Aggregate depth bands across windows into JSONB per maker
maker_depth_agg AS (
    SELECT
        pool_id,
        epoch_start_ms,
        balance_manager_id,
        jsonb_build_array(
            jsonb_build_object('bps', 5,   'bid', COALESCE(AVG(bid_5), 0),   'ask', COALESCE(AVG(ask_5), 0)),
            jsonb_build_object('bps', 10,  'bid', COALESCE(AVG(bid_10), 0),  'ask', COALESCE(AVG(ask_10), 0)),
            jsonb_build_object('bps', 25,  'bid', COALESCE(AVG(bid_25), 0),  'ask', COALESCE(AVG(ask_25), 0)),
            jsonb_build_object('bps', 50,  'bid', COALESCE(AVG(bid_50), 0),  'ask', COALESCE(AVG(ask_50), 0)),
            jsonb_build_object('bps', 100, 'bid', COALESCE(AVG(bid_100), 0), 'ask', COALESCE(AVG(ask_100), 0))
        ) AS depth_profile
    FROM maker_depth_bands
    GROUP BY pool_id, epoch_start_ms, balance_manager_id
),

-- Aggregate per-maker epoch stats from window data
maker_epoch AS (
    SELECT
        pool_id,
        epoch_start_ms,
        balance_manager_id,
        SUM(order_count)::BIGINT AS order_count,
        -- Median VWAP spread across two-sided windows
        COALESCE(
            PERCENTILE_CONT(0.5) WITHIN GROUP (ORDER BY spread_bps)
            FILTER (WHERE spread_bps IS NOT NULL),
            0
        )::FLOAT8 AS vwap_spread_bps,
        -- Bitmask: bit i set if maker had two-sided quotes in window i
        COALESCE(bit_or(
            CASE WHEN has_two_sided THEN (1 << window_idx) ELSE 0 END
        ), 0)::INT AS quoting_window_mask,
        COALESCE(AVG(bid_depth) FILTER (WHERE has_two_sided), 0)::FLOAT8 AS avg_bid_depth,
        COALESCE(AVG(ask_depth) FILTER (WHERE has_two_sided), 0)::FLOAT8 AS avg_ask_depth
    FROM maker_window
    LEFT JOIN maker_window_mid USING (pool_id, epoch_start_ms, balance_manager_id, window_idx)
    GROUP BY pool_id, epoch_start_ms, balance_manager_id
)

SELECT
    me.pool_id::TEXT,
    me.epoch_start_ms::BIGINT,
    (me.epoch_start_ms + 86400000)::BIGINT                  AS epoch_end_ms,
    me.balance_manager_id::TEXT,
    me.order_count::BIGINT,
    COALESCE(mf.fill_count, 0)::BIGINT                      AS fill_count,
    COALESCE(mf.base_volume, 0)::BIGINT                     AS base_volume,
    COALESCE(mf.quote_volume, 0)::BIGINT                    AS quote_volume,
    COALESCE(mf.net_base_flow, 0)::BIGINT                   AS net_base_flow,
    COALESCE(mf.net_quote_flow, 0)::BIGINT                  AS net_quote_flow,
    me.vwap_spread_bps::FLOAT8,
    me.quoting_window_mask::INT,
    me.avg_bid_depth::FLOAT8,
    me.avg_ask_depth::FLOAT8,
    COALESCE(d.depth_profile, '[]'::JSONB)                   AS depth_profile
FROM maker_epoch me
LEFT JOIN maker_fills mf
    ON  me.pool_id = mf.pool_id
    AND me.epoch_start_ms = mf.epoch_start_ms
    AND me.balance_manager_id = mf.balance_manager_id
LEFT JOIN maker_depth_agg d
    ON  me.pool_id = d.pool_id
    AND me.epoch_start_ms = d.epoch_start_ms
    AND me.balance_manager_id = d.balance_manager_id;

-- Unique index required for REFRESH MATERIALIZED VIEW CONCURRENTLY
CREATE UNIQUE INDEX IF NOT EXISTS idx_pemm_pool_epoch_maker
    ON pool_epoch_maker_metrics (pool_id, epoch_start_ms, balance_manager_id);

-- Index for pool+epoch range queries (pool-level aggregation)
CREATE INDEX IF NOT EXISTS idx_pemm_pool_epoch
    ON pool_epoch_maker_metrics (pool_id, epoch_start_ms);
