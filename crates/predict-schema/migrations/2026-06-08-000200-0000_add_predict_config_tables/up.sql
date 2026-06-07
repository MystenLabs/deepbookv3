CREATE TABLE IF NOT EXISTS pricing_config_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    protocol_config_id               TEXT      NOT NULL,
    pyth_spot_freshness_ms           BIGINT    NOT NULL, -- staleness window in ms
    block_scholes_prices_freshness_ms BIGINT   NOT NULL, -- staleness window in ms
    block_scholes_svi_freshness_ms   BIGINT    NOT NULL  -- staleness window in ms
);
CREATE INDEX IF NOT EXISTS idx_pricing_config_updated_config_ts ON pricing_config_updated(protocol_config_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS fee_config_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    protocol_config_id               TEXT      NOT NULL,
    protocol_reserve_profit_share    BIGINT    NOT NULL -- 1e9-scaled ratio, <= ~1e9
);
CREATE INDEX IF NOT EXISTS idx_fee_config_updated_config_ts ON fee_config_updated(protocol_config_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS risk_config_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    protocol_config_id               TEXT      NOT NULL,
    valuation_liquidation_budget     BIGINT    NOT NULL, -- candidate-count budget, bounded
    trade_liquidation_budget         BIGINT    NOT NULL  -- candidate-count budget, bounded
);
CREATE INDEX IF NOT EXISTS idx_risk_config_updated_config_ts ON risk_config_updated(protocol_config_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS expiry_cash_template_config_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    protocol_config_id               TEXT      NOT NULL,
    trading_loss_rebate_rate         BIGINT    NOT NULL -- 1e9-scaled ratio, <= ~1e9
);
CREATE INDEX IF NOT EXISTS idx_expiry_cash_template_config_updated_config_ts ON expiry_cash_template_config_updated(protocol_config_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS strike_exposure_template_config_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    protocol_config_id               TEXT      NOT NULL,
    terminal_floor_index             BIGINT    NOT NULL, -- 1e9-scaled index, bounded
    liquidation_ltv                  BIGINT    NOT NULL, -- 1e9-scaled ratio, <= ~1e9
    base_fee                         NUMERIC   NOT NULL,
    min_fee                          NUMERIC   NOT NULL,
    min_ask_price                    NUMERIC   NOT NULL,
    max_ask_price                    NUMERIC   NOT NULL,
    expiry_fee_window_ms             BIGINT    NOT NULL, -- window in ms, bounded
    expiry_fee_max_multiplier        BIGINT    NOT NULL  -- 1e9-scaled multiplier, bounded
);
CREATE INDEX IF NOT EXISTS idx_strike_exposure_template_config_updated_config_ts ON strike_exposure_template_config_updated(protocol_config_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS market_oracle_template_config_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    protocol_config_id               TEXT      NOT NULL,
    settlement_freshness_ms          BIGINT    NOT NULL, -- staleness window in ms
    max_spot_deviation               BIGINT    NOT NULL, -- 1e9-scaled ratio, <= ~1e9
    max_basis_deviation              BIGINT    NOT NULL, -- 1e9-scaled ratio, <= ~1e9
    min_basis                        NUMERIC   NOT NULL, -- basis amount (price-class), NUMERIC like other price/amount fields
    max_basis                        NUMERIC   NOT NULL  -- basis amount (price-class), NUMERIC like other price/amount fields
);
CREATE INDEX IF NOT EXISTS idx_market_oracle_template_config_updated_config_ts ON market_oracle_template_config_updated(protocol_config_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS ewma_config_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    protocol_config_id               TEXT      NOT NULL,
    alpha                            BIGINT    NOT NULL, -- 1e9-scaled smoothing factor, <= ~1e9
    z_score_threshold                BIGINT    NOT NULL, -- 1e9-scaled threshold, bounded
    additional_fee                   NUMERIC   NOT NULL, -- fee amount (price-class), NUMERIC like other price/amount fields
    enabled                          BOOLEAN   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ewma_config_updated_config_ts ON ewma_config_updated(protocol_config_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS stake_config_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    protocol_config_id               TEXT      NOT NULL,
    lower_benefit_power              NUMERIC   NOT NULL,
    upper_benefit_power              NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_stake_config_updated_config_ts ON stake_config_updated(protocol_config_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS trading_paused_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    protocol_config_id               TEXT      NOT NULL,
    paused                           BOOLEAN   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_trading_paused_updated_config_ts ON trading_paused_updated(protocol_config_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS market_created (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    expiry_market_id                 TEXT      NOT NULL,
    market_oracle_id                 TEXT      NOT NULL,
    pool_vault_id                    TEXT      NOT NULL,
    pyth_source_id                   TEXT      NOT NULL,
    pyth_lazer_feed_id               BIGINT    NOT NULL, -- u32 feed id, fits in i64
    expiry                           BIGINT    NOT NULL, -- unix ms timestamp
    min_strike                       NUMERIC   NOT NULL,
    tick_size                        NUMERIC   NOT NULL,
    max_strike                       NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_market_created_market_ts ON market_created(expiry_market_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_market_created_market_oracle_id ON market_created(market_oracle_id);
CREATE INDEX IF NOT EXISTS idx_market_created_pool_vault_id ON market_created(pool_vault_id);
CREATE INDEX IF NOT EXISTS idx_market_created_pyth_source_id ON market_created(pyth_source_id);

CREATE TABLE IF NOT EXISTS market_config_snapshot (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    expiry_market_id                 TEXT      NOT NULL,
    market_oracle_id                 TEXT      NOT NULL,
    terminal_floor_index             BIGINT    NOT NULL, -- 1e9-scaled index, bounded
    liquidation_ltv                  BIGINT    NOT NULL, -- 1e9-scaled ratio, <= ~1e9
    base_fee                         NUMERIC   NOT NULL,
    min_fee                          NUMERIC   NOT NULL,
    min_ask_price                    NUMERIC   NOT NULL,
    max_ask_price                    NUMERIC   NOT NULL,
    expiry_fee_window_ms             BIGINT    NOT NULL, -- window in ms, bounded
    expiry_fee_max_multiplier        BIGINT    NOT NULL, -- 1e9-scaled multiplier, bounded
    trading_loss_rebate_rate         BIGINT    NOT NULL  -- 1e9-scaled ratio, <= ~1e9
);
CREATE INDEX IF NOT EXISTS idx_market_config_snapshot_market_ts ON market_config_snapshot(expiry_market_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_market_config_snapshot_market_oracle_id ON market_config_snapshot(market_oracle_id);

CREATE TABLE IF NOT EXISTS market_oracle_bounds_updated (
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
    settlement_freshness_ms          BIGINT    NOT NULL, -- staleness window in ms
    max_spot_deviation               BIGINT    NOT NULL, -- 1e9-scaled ratio, <= ~1e9
    max_basis_deviation              BIGINT    NOT NULL, -- 1e9-scaled ratio, <= ~1e9
    min_basis                        NUMERIC   NOT NULL, -- basis amount (price-class), NUMERIC like other price/amount fields
    max_basis                        NUMERIC   NOT NULL  -- basis amount (price-class), NUMERIC like other price/amount fields
);
CREATE INDEX IF NOT EXISTS idx_market_oracle_bounds_updated_oracle_ts ON market_oracle_bounds_updated(market_oracle_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS expiry_market_mint_paused_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    expiry_market_id                 TEXT      NOT NULL,
    paused                           BOOLEAN   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_expiry_market_mint_paused_updated_market_ts ON expiry_market_mint_paused_updated(expiry_market_id, checkpoint_timestamp_ms);
