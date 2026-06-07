CREATE TABLE IF NOT EXISTS builder_fees_claimed (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    builder_code_id                  TEXT      NOT NULL,
    owner                            TEXT      NOT NULL,
    amount                           NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_builder_fees_claimed_code_ts ON builder_fees_claimed(builder_code_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_builder_fees_claimed_owner_ts ON builder_fees_claimed(owner, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS trading_loss_rebate_claimed (
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
    predict_manager_id               TEXT      NOT NULL,
    trading_fees_paid                NUMERIC   NOT NULL,
    gross_profit                     NUMERIC   NOT NULL,
    eligible_rebate                  NUMERIC   NOT NULL,
    rebate_amount                    NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_trading_loss_rebate_claimed_manager_ts ON trading_loss_rebate_claimed(predict_manager_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_trading_loss_rebate_claimed_expiry_ts ON trading_loss_rebate_claimed(expiry_market_id, checkpoint_timestamp_ms);
