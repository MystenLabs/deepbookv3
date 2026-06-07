CREATE TABLE IF NOT EXISTS supply_executed (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    pool_vault_id                    TEXT      NOT NULL,
    payment                          NUMERIC   NOT NULL,
    shares_minted                    NUMERIC   NOT NULL,
    pool_value_before                NUMERIC   NOT NULL,
    incentive_value                  NUMERIC   NOT NULL,
    total_supply_after               NUMERIC   NOT NULL,
    idle_balance_after               NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_supply_executed_vault_ts ON supply_executed(pool_vault_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS withdraw_executed (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    pool_vault_id                    TEXT      NOT NULL,
    shares_burned                    NUMERIC   NOT NULL,
    payout                           NUMERIC   NOT NULL,
    pool_value_before                NUMERIC   NOT NULL,
    total_supply_after               NUMERIC   NOT NULL,
    idle_balance_after               NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_withdraw_executed_vault_ts ON withdraw_executed(pool_vault_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS expiry_cash_rebalanced (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    pool_vault_id                    TEXT      NOT NULL,
    expiry_market_id                 TEXT      NOT NULL,
    amount                           NUMERIC   NOT NULL,
    to_expiry                        BOOLEAN   NOT NULL,
    target_cash                      NUMERIC   NOT NULL,
    expiry_cash_after                NUMERIC   NOT NULL,
    idle_balance_after               NUMERIC   NOT NULL,
    sent_to_expiry_after             NUMERIC   NOT NULL,
    received_from_expiry_after       NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_expiry_cash_rebalanced_vault_ts ON expiry_cash_rebalanced(pool_vault_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_expiry_cash_rebalanced_expiry_ts ON expiry_cash_rebalanced(expiry_market_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS expiry_max_funding_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    pool_vault_id                    TEXT      NOT NULL,
    expiry_market_id                 TEXT      NOT NULL,
    max_expiry_funding               NUMERIC   NOT NULL,
    net_funding                      NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_expiry_max_funding_updated_vault_ts ON expiry_max_funding_updated(pool_vault_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_expiry_max_funding_updated_expiry_ts ON expiry_max_funding_updated(expiry_market_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS expiry_cash_received (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    pool_vault_id                    TEXT      NOT NULL,
    expiry_market_id                 TEXT      NOT NULL,
    settlement_price                 NUMERIC   NOT NULL,
    amount                           NUMERIC   NOT NULL,
    idle_balance_after               NUMERIC   NOT NULL,
    sent_to_expiry_after             NUMERIC   NOT NULL,
    received_from_expiry_after       NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_expiry_cash_received_vault_ts ON expiry_cash_received(pool_vault_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_expiry_cash_received_expiry_ts ON expiry_cash_received(expiry_market_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS expiry_profit_materialized (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    pool_vault_id                    TEXT      NOT NULL,
    expiry_market_id                 TEXT      NOT NULL,
    lp_profit                        NUMERIC   NOT NULL,
    protocol_profit                  NUMERIC   NOT NULL,
    idle_balance_after               NUMERIC   NOT NULL,
    protocol_reserve_balance_after   NUMERIC   NOT NULL,
    profit_basis_after               NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_expiry_profit_materialized_vault_ts ON expiry_profit_materialized(pool_vault_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_expiry_profit_materialized_expiry_ts ON expiry_profit_materialized(expiry_market_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS deep_staked (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    pool_vault_id                    TEXT      NOT NULL,
    predict_manager_id               TEXT      NOT NULL,
    amount                           NUMERIC   NOT NULL,
    active_stake_after               NUMERIC   NOT NULL,
    inactive_stake_after             NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_deep_staked_manager_ts ON deep_staked(predict_manager_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_deep_staked_vault_ts ON deep_staked(pool_vault_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS deep_unstaked (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    pool_vault_id                    TEXT      NOT NULL,
    predict_manager_id               TEXT      NOT NULL,
    amount                           NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_deep_unstaked_manager_ts ON deep_unstaked(predict_manager_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_deep_unstaked_vault_ts ON deep_unstaked(pool_vault_id, checkpoint_timestamp_ms);
