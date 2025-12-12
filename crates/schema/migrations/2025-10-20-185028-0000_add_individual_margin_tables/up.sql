CREATE TABLE margin_manager_created (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    margin_manager_id           TEXT        NOT NULL,
    balance_manager_id          TEXT        NOT NULL,
    owner                       TEXT        NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

CREATE TABLE loan_borrowed (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    margin_manager_id           TEXT        NOT NULL,
    margin_pool_id              TEXT        NOT NULL,
    loan_amount                 BIGINT      NOT NULL,
    total_borrow                BIGINT      NOT NULL,
    total_shares                BIGINT      NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

CREATE TABLE loan_repaid (
    event_digest                 TEXT        PRIMARY KEY,
    digest                        TEXT        NOT NULL,
    sender                        TEXT        NOT NULL,
    checkpoint                    BIGINT      NOT NULL,
    timestamp                     TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms       BIGINT      NOT NULL,
    package                       TEXT        NOT NULL,
    margin_manager_id             TEXT        NOT NULL,
    margin_pool_id                TEXT        NOT NULL,
    repay_amount                  BIGINT      NOT NULL,
    repay_shares                  BIGINT      NOT NULL,
    onchain_timestamp             BIGINT      NOT NULL
);

CREATE TABLE liquidation (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    margin_manager_id           TEXT        NOT NULL,
    margin_pool_id              TEXT        NOT NULL,
    liquidation_amount          BIGINT      NOT NULL,
    pool_reward                 BIGINT      NOT NULL,
    pool_default                BIGINT      NOT NULL,
    risk_ratio                  BIGINT      NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

CREATE TABLE asset_supplied (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    margin_pool_id              TEXT        NOT NULL,
    asset_type                  TEXT        NOT NULL,
    supplier                    TEXT        NOT NULL,
    amount                      BIGINT      NOT NULL,
    shares                      BIGINT      NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

CREATE TABLE asset_withdrawn (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    margin_pool_id              TEXT        NOT NULL,
    asset_type                  TEXT        NOT NULL,
    supplier                    TEXT        NOT NULL,
    amount                      BIGINT      NOT NULL,
    shares                      BIGINT      NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

CREATE TABLE margin_pool_created (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    margin_pool_id              TEXT        NOT NULL,
    maintainer_cap_id           TEXT        NOT NULL,
    asset_type                  TEXT        NOT NULL,
    config_json                 JSONB       NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

CREATE TABLE deepbook_pool_updated (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    margin_pool_id              TEXT        NOT NULL,
    deepbook_pool_id            TEXT        NOT NULL,
    pool_cap_id                 TEXT        NOT NULL,
    enabled                     BOOLEAN     NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

CREATE TABLE interest_params_updated (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    margin_pool_id              TEXT        NOT NULL,
    pool_cap_id                 TEXT        NOT NULL,
    config_json                 JSONB       NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

CREATE TABLE margin_pool_config_updated (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    margin_pool_id              TEXT        NOT NULL,
    pool_cap_id                 TEXT        NOT NULL,
    config_json                  JSONB       NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

CREATE TABLE maintainer_cap_updated (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    maintainer_cap_id           TEXT        NOT NULL,
    allowed                     BOOLEAN     NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

CREATE TABLE deepbook_pool_registered (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    pool_id                     TEXT        NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

CREATE TABLE deepbook_pool_updated_registry (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    pool_id                     TEXT        NOT NULL,
    enabled                     BOOLEAN     NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

CREATE TABLE deepbook_pool_config_updated (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    pool_id                     TEXT        NOT NULL,
    config_json                 JSONB       NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);