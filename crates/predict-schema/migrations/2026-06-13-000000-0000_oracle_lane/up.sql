-- Oracle-lane tables for the standalone Propbook oracle indexer.
--
-- These tables live in the shared `predict` Postgres DB but are written by the
-- separate `oracle-indexer` process (own watermark namespace) and read by
-- `oracle-server`. `embed_migrations!` runs every migration from both indexers;
-- the IF NOT EXISTS guards make that double-run idempotent.
--
-- Standard 9-column event header (event_digest PK + digest/sender/checkpoint/
-- tx_index/event_index/timestamp/checkpoint_timestamp_ms/package) mirrors the
-- predict raw tables. The `(checkpoint, tx_index, event_index)` triple is the
-- only total event order; series are NEVER ordered by source_timestamp_ms (a
-- stale-but-later-landing oracle update can carry an older source timestamp).

-- Live + exact-history Pyth spot observations. `is_exact = false` is the
-- advancing live lane (ObservationRecorded); `is_exact = true` is the exact-ms
-- insert history (ObservationInserted). Raw source fields are stored verbatim;
-- `normalized_spot` is the off-chain replication of pyth_feed::normalize_raw_spot
-- (1e9 scaling), NULL when the raw spot has no positive normalized value.
CREATE TABLE IF NOT EXISTS pyth_observation (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    propbook_oracle_id       TEXT      NOT NULL,
    pyth_source_id           BIGINT    NOT NULL, -- u32 Pyth source id, fits in i64
    price_magnitude          NUMERIC   NOT NULL, -- u64, unbounded
    price_is_negative        BOOLEAN   NOT NULL,
    exponent_magnitude       INTEGER   NOT NULL, -- u16
    exponent_is_negative     BOOLEAN   NOT NULL,
    source_timestamp_us      NUMERIC   NOT NULL, -- u64 native microseconds, unbounded
    normalized_spot          NUMERIC,            -- off-chain 1e9 normalization; NULL when None
    source_timestamp_ms      BIGINT    NOT NULL, -- lane canonical ms timestamp
    update_timestamp_ms      BIGINT    NOT NULL, -- on-chain landing ms (clock.timestamp_ms())
    is_exact                 BOOLEAN   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_pyth_obs_oracle_ts ON pyth_observation(propbook_oracle_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_pyth_obs_oracle_exact_ts ON pyth_observation(propbook_oracle_id, is_exact, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_pyth_obs_ts_brin ON pyth_observation USING brin (checkpoint_timestamp_ms);

-- Live + exact-history Block Scholes surface observations, one row per expiry
-- per observation. Signed SVI params (`rho`, `m`) collapse the on-chain
-- I64 { magnitude, is_negative } into a single signed NUMERIC. `normalized_spot`
-- / `normalized_forward` pass spot/forward through (NULL when either is zero,
-- mirroring block_scholes_feed::normalized_surface_from_read).
CREATE TABLE IF NOT EXISTS block_scholes_observation (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    propbook_oracle_id       TEXT      NOT NULL,
    bs_source_id             BIGINT    NOT NULL, -- u32 BS source id, fits in i64
    expiry_ms                BIGINT    NOT NULL, -- unix ms expiry
    spot                     NUMERIC   NOT NULL, -- u64, unbounded
    forward                  NUMERIC   NOT NULL, -- u64, unbounded
    svi_a                    NUMERIC   NOT NULL, -- u64
    svi_b                    NUMERIC   NOT NULL, -- u64
    svi_rho                  NUMERIC   NOT NULL, -- signed: magnitude negated when is_negative
    svi_m                    NUMERIC   NOT NULL, -- signed: magnitude negated when is_negative
    svi_sigma                NUMERIC   NOT NULL, -- u64
    normalized_spot          NUMERIC,            -- spot passthrough; NULL when spot/forward zero
    normalized_forward       NUMERIC,            -- forward passthrough; NULL when spot/forward zero
    source_timestamp_ms      BIGINT    NOT NULL, -- lane canonical ms timestamp
    update_timestamp_ms      BIGINT    NOT NULL, -- on-chain landing ms (clock.timestamp_ms())
    is_exact                 BOOLEAN   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_bs_obs_oracle_expiry_ts ON block_scholes_observation(propbook_oracle_id, expiry_ms, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_bs_obs_oracle_expiry_exact_ts ON block_scholes_observation(propbook_oracle_id, expiry_ms, is_exact, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_bs_obs_ts_brin ON block_scholes_observation USING brin (checkpoint_timestamp_ms);

-- Registry source-catalog registrations (OracleSourceRegistered).
CREATE TABLE IF NOT EXISTS oracle_source_registered (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    oracle_kind              SMALLINT  NOT NULL, -- 0 = Pyth, 1 = Block Scholes
    source_id                BIGINT    NOT NULL, -- u32 source-local id, fits in i64
    propbook_oracle_id       TEXT      NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_oracle_source_registered_oracle ON oracle_source_registered(propbook_oracle_id);
CREATE INDEX IF NOT EXISTS idx_oracle_source_registered_kind_source ON oracle_source_registered(oracle_kind, source_id);

-- Registry canonical bindings (OracleBound). Insert-only on-chain; the latest
-- triple is the current binding for a (underlying, kind, value_kind).
CREATE TABLE IF NOT EXISTS oracle_bound (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    propbook_underlying_id   BIGINT    NOT NULL, -- u32 underlying id, fits in i64
    oracle_kind              SMALLINT  NOT NULL, -- 0 = Pyth, 1 = Block Scholes
    source_id                BIGINT    NOT NULL, -- u32 source-local id, fits in i64
    propbook_oracle_id       TEXT      NOT NULL,
    value_kind               SMALLINT  NOT NULL  -- 0 = spot, 1 = vol_surface
);
CREATE INDEX IF NOT EXISTS idx_oracle_bound_underlying ON oracle_bound(propbook_underlying_id, oracle_kind, value_kind, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_oracle_bound_oracle ON oracle_bound(propbook_oracle_id);

-- Per-minute OHLC over the live BS spot lane (is_exact = false), keyed by
-- (propbook_oracle_id, expiry_ms). open/close are the first/last live
-- observations in the bucket by the (checkpoint, tx_index, event_index) total
-- order. 30-day trailing window plus the BRIN above keep the CONCURRENTLY
-- refresh bounded by rows-in-window. now() is evaluated at refresh time.
CREATE MATERIALIZED VIEW IF NOT EXISTS oracle_spot_1m AS
WITH live AS (
    SELECT
        propbook_oracle_id,
        expiry_ms,
        (checkpoint_timestamp_ms / 60000) * 60000 AS bucket_ms,
        spot,
        forward,
        checkpoint,
        tx_index,
        event_index,
        ROW_NUMBER() OVER (
            PARTITION BY propbook_oracle_id, expiry_ms, (checkpoint_timestamp_ms / 60000) * 60000
            ORDER BY checkpoint ASC, tx_index ASC, event_index ASC
        ) AS rn_open,
        ROW_NUMBER() OVER (
            PARTITION BY propbook_oracle_id, expiry_ms, (checkpoint_timestamp_ms / 60000) * 60000
            ORDER BY checkpoint DESC, tx_index DESC, event_index DESC
        ) AS rn_close
    FROM block_scholes_observation
    WHERE is_exact = false
      AND checkpoint_timestamp_ms >= EXTRACT(EPOCH FROM now())::BIGINT * 1000 - 2592000000
)
SELECT
    propbook_oracle_id,
    expiry_ms,
    bucket_ms,
    MAX(spot) FILTER (WHERE rn_open = 1)  AS open,
    MAX(spot)                             AS high,
    MIN(spot)                             AS low,
    MAX(spot) FILTER (WHERE rn_close = 1) AS close,
    MAX(forward) FILTER (WHERE rn_close = 1) AS forward,
    COUNT(*)                              AS update_count
FROM live
GROUP BY propbook_oracle_id, expiry_ms, bucket_ms;
-- REFRESH MATERIALIZED VIEW CONCURRENTLY requires a unique index.
CREATE UNIQUE INDEX IF NOT EXISTS idx_oracle_spot_1m_unique ON oracle_spot_1m(propbook_oracle_id, expiry_ms, bucket_ms);
