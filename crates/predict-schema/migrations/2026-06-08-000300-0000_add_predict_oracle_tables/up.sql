CREATE TABLE IF NOT EXISTS block_scholes_prices_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    market_oracle_id                 TEXT      NOT NULL,
    spot                             NUMERIC   NOT NULL,
    forward                          NUMERIC   NOT NULL,
    basis                            NUMERIC   NOT NULL,
    source_timestamp_ms              BIGINT    NOT NULL, -- unix ms timestamp
    update_timestamp_ms              BIGINT    NOT NULL  -- unix ms timestamp
);
CREATE INDEX IF NOT EXISTS idx_block_scholes_prices_updated_oracle_ts ON block_scholes_prices_updated(market_oracle_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS block_scholes_svi_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    market_oracle_id                 TEXT      NOT NULL,
    a                                NUMERIC   NOT NULL,
    b                                NUMERIC   NOT NULL,
    rho                              NUMERIC   NOT NULL, -- signed (I64 magnitude/is_negative)
    m                                NUMERIC   NOT NULL, -- signed (I64 magnitude/is_negative)
    sigma                            NUMERIC   NOT NULL,
    source_timestamp_ms              BIGINT    NOT NULL, -- unix ms timestamp
    update_timestamp_ms              BIGINT    NOT NULL  -- unix ms timestamp
);
CREATE INDEX IF NOT EXISTS idx_block_scholes_svi_updated_oracle_ts ON block_scholes_svi_updated(market_oracle_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS pyth_source_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    pyth_source_id                   TEXT      NOT NULL,
    feed_id                          BIGINT    NOT NULL, -- u32 feed id, fits in i64
    spot                             NUMERIC   NOT NULL,
    source_timestamp_ms              BIGINT    NOT NULL, -- unix ms timestamp
    update_timestamp_ms              BIGINT    NOT NULL  -- unix ms timestamp
);
CREATE INDEX IF NOT EXISTS idx_pyth_source_updated_source_ts ON pyth_source_updated(pyth_source_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_pyth_source_updated_feed_id ON pyth_source_updated(feed_id);

CREATE TABLE IF NOT EXISTS market_oracle_settled (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    market_oracle_id                 TEXT      NOT NULL,
    expiry                           BIGINT    NOT NULL, -- unix ms timestamp
    settlement_price                 NUMERIC   NOT NULL,
    spot_source                      SMALLINT  NOT NULL, -- u8: 1=Pyth, 2=Block Scholes fallback
    source_timestamp_ms              BIGINT    NOT NULL, -- unix ms timestamp
    update_timestamp_ms              BIGINT    NOT NULL  -- unix ms timestamp
);
CREATE INDEX IF NOT EXISTS idx_market_oracle_settled_oracle_ts ON market_oracle_settled(market_oracle_id, checkpoint_timestamp_ms);
