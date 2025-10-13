-- Create margin_pool_operations table
CREATE TABLE IF NOT EXISTS margin_pool_operations
(
    event_digest                TEXT         PRIMARY KEY,
    digest                      TEXT         NOT NULL,
    sender                      TEXT         NOT NULL,
    checkpoint                  BIGINT       NOT NULL,
    timestamp                   TIMESTAMP    DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT       NOT NULL,
    package                     TEXT         NOT NULL,
    margin_pool_id              TEXT         NOT NULL,
    asset_type                  TEXT         NOT NULL,
    supplier                    TEXT         NOT NULL,
    amount                      BIGINT       NOT NULL,
    shares                      BIGINT       NOT NULL,
    operation_type              TEXT         NOT NULL,
    onchain_timestamp           BIGINT       NOT NULL
);

-- Create margin_manager_operations table
CREATE TABLE IF NOT EXISTS margin_manager_operations
(
    event_digest                TEXT         PRIMARY KEY,
    digest                      TEXT         NOT NULL,
    sender                      TEXT         NOT NULL,
    checkpoint                  BIGINT       NOT NULL,
    timestamp                   TIMESTAMP    DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT       NOT NULL,
    package                     TEXT         NOT NULL,
    margin_manager_id           TEXT         NOT NULL,
    balance_manager_id          TEXT,
    owner                       TEXT,
    margin_pool_id              TEXT,
    operation_type              TEXT         NOT NULL,
    loan_amount                 BIGINT,
    total_borrow                BIGINT,
    total_shares                BIGINT,
    repay_amount                BIGINT,
    repay_shares                BIGINT,
    liquidation_amount          BIGINT,
    pool_reward                 BIGINT,
    pool_default                BIGINT,
    risk_ratio                  BIGINT,
    onchain_timestamp           BIGINT       NOT NULL
);

-- Create margin_pool_admin table
CREATE TABLE IF NOT EXISTS margin_pool_admin
(
    event_digest                TEXT         PRIMARY KEY,
    digest                      TEXT         NOT NULL,
    sender                      TEXT         NOT NULL,
    checkpoint                  BIGINT       NOT NULL,
    timestamp                   TIMESTAMP    DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT       NOT NULL,
    package                     TEXT         NOT NULL,
    margin_pool_id              TEXT         NOT NULL,
    event_type                  TEXT         NOT NULL,
    maintainer_cap_id           TEXT,
    asset_type                  TEXT,
    deepbook_pool_id            TEXT,
    pool_cap_id                 TEXT,
    enabled                     BOOLEAN,
    config_json                 JSONB,
    onchain_timestamp           BIGINT       NOT NULL
);

-- Create margin_fees table
CREATE TABLE IF NOT EXISTS margin_fees
(
    event_digest                TEXT         PRIMARY KEY,
    digest                      TEXT         NOT NULL,
    sender                      TEXT         NOT NULL,
    checkpoint                  BIGINT       NOT NULL,
    timestamp                   TIMESTAMP    DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT       NOT NULL,
    package                     TEXT         NOT NULL,
    fee_type                    TEXT         NOT NULL,
    margin_pool_id              TEXT,
    maintainer_cap_id           TEXT,
    referral_id                 TEXT,
    owner                       TEXT,
    fees                        BIGINT,
    maintainer_fees             BIGINT,
    protocol_fees               BIGINT,
    referral_fees               BIGINT,
    total_shares                BIGINT,
    onchain_timestamp           BIGINT       NOT NULL
);

-- Create margin_registry_events table
CREATE TABLE IF NOT EXISTS margin_registry_events
(
    event_digest                TEXT         PRIMARY KEY,
    digest                      TEXT         NOT NULL,
    sender                      TEXT         NOT NULL,
    checkpoint                  BIGINT       NOT NULL,
    timestamp                   TIMESTAMP    DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT       NOT NULL,
    package                     TEXT         NOT NULL,
    event_type                  TEXT         NOT NULL,
    maintainer_cap_id           TEXT,
    allowed                     BOOLEAN,
    pool_id                     TEXT,
    enabled                     BOOLEAN,
    config_json                 JSONB,
    onchain_timestamp           BIGINT       NOT NULL
);
