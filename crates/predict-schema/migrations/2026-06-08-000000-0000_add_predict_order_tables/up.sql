CREATE TABLE IF NOT EXISTS order_minted (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    expiry_market_id         TEXT      NOT NULL,
    predict_manager_id       TEXT      NOT NULL,
    order_id                 TEXT      NOT NULL,
    position_root_id         TEXT      NOT NULL,
    owner                    TEXT      NOT NULL,
    lower_strike             NUMERIC   NOT NULL,
    higher_strike            NUMERIC   NOT NULL,
    leverage                 BIGINT    NOT NULL, -- small integer multiplier
    entry_probability        BIGINT    NOT NULL, -- 1e9-scaled, <= ~1e9
    quantity                 NUMERIC   NOT NULL,
    contribution             NUMERIC   NOT NULL,
    trading_fee              NUMERIC   NOT NULL,
    builder_fee              NUMERIC   NOT NULL,
    penalty_fee              NUMERIC   NOT NULL,
    builder_code_id          TEXT
);
CREATE INDEX IF NOT EXISTS idx_order_minted_expiry_market_ts ON order_minted(expiry_market_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_order_minted_manager_ts ON order_minted(predict_manager_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_order_minted_order_id ON order_minted(order_id);
CREATE INDEX IF NOT EXISTS idx_order_minted_position_root ON order_minted(position_root_id);

CREATE TABLE IF NOT EXISTS live_order_redeemed (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    expiry_market_id         TEXT      NOT NULL,
    predict_manager_id       TEXT      NOT NULL,
    order_id                 TEXT      NOT NULL,
    position_root_id         TEXT      NOT NULL,
    owner                    TEXT      NOT NULL,
    quantity_closed          NUMERIC   NOT NULL,
    remaining_quantity       NUMERIC   NOT NULL,
    replacement_order_id     TEXT,
    redeem_amount            NUMERIC   NOT NULL,
    trading_fee              NUMERIC   NOT NULL,
    builder_fee              NUMERIC   NOT NULL,
    penalty_fee              NUMERIC   NOT NULL,
    builder_code_id          TEXT
);
CREATE INDEX IF NOT EXISTS idx_live_redeemed_expiry_market_ts ON live_order_redeemed(expiry_market_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_live_redeemed_manager_ts ON live_order_redeemed(predict_manager_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_live_redeemed_position_root ON live_order_redeemed(position_root_id);

CREATE TABLE IF NOT EXISTS settled_order_redeemed (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    expiry_market_id         TEXT      NOT NULL,
    predict_manager_id       TEXT      NOT NULL,
    order_id                 TEXT      NOT NULL,
    position_root_id         TEXT      NOT NULL,
    owner                    TEXT      NOT NULL,
    quantity_closed          NUMERIC   NOT NULL,
    settlement_price         NUMERIC   NOT NULL,
    payout_amount            NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_settled_redeemed_expiry_market_ts ON settled_order_redeemed(expiry_market_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_settled_redeemed_manager_ts ON settled_order_redeemed(predict_manager_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_settled_redeemed_position_root ON settled_order_redeemed(position_root_id);

CREATE TABLE IF NOT EXISTS liquidated_order_redeemed (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    expiry_market_id         TEXT      NOT NULL,
    predict_manager_id       TEXT      NOT NULL,
    order_id                 TEXT      NOT NULL,
    position_root_id         TEXT      NOT NULL,
    owner                    TEXT      NOT NULL,
    quantity_closed          NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_liq_redeemed_expiry_market_ts ON liquidated_order_redeemed(expiry_market_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_liq_redeemed_manager_ts ON liquidated_order_redeemed(predict_manager_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_liq_redeemed_position_root ON liquidated_order_redeemed(position_root_id);

CREATE TABLE IF NOT EXISTS order_liquidated (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    expiry_market_id         TEXT      NOT NULL,
    order_id                 TEXT      NOT NULL,
    quantity                 NUMERIC   NOT NULL,
    gross_value              NUMERIC   NOT NULL,
    floor_amount             NUMERIC   NOT NULL,
    liquidation_ltv          BIGINT    NOT NULL -- 1e9-scaled, <= ~1e9
);
CREATE INDEX IF NOT EXISTS idx_order_liquidated_expiry_market_ts ON order_liquidated(expiry_market_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_order_liquidated_order_id ON order_liquidated(order_id);
