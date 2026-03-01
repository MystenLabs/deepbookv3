-- Oracle tables

CREATE TABLE IF NOT EXISTS oracle_activated
(
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    oracle_id               TEXT        NOT NULL,
    expiry                  BIGINT      NOT NULL,
    onchain_timestamp       BIGINT      NOT NULL
);

CREATE TABLE IF NOT EXISTS oracle_settled
(
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    oracle_id               TEXT        NOT NULL,
    expiry                  BIGINT      NOT NULL,
    settlement_price        BIGINT      NOT NULL,
    onchain_timestamp       BIGINT      NOT NULL
);

CREATE TABLE IF NOT EXISTS oracle_prices_updated
(
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    oracle_id               TEXT        NOT NULL,
    spot                    BIGINT      NOT NULL,
    forward                 BIGINT      NOT NULL,
    onchain_timestamp       BIGINT      NOT NULL
);

CREATE TABLE IF NOT EXISTS oracle_svi_updated
(
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    oracle_id               TEXT        NOT NULL,
    a                       BIGINT      NOT NULL,
    b                       BIGINT      NOT NULL,
    rho                     BIGINT      NOT NULL,
    rho_negative            BOOLEAN     NOT NULL,
    m                       BIGINT      NOT NULL,
    m_negative              BOOLEAN     NOT NULL,
    sigma                   BIGINT      NOT NULL,
    risk_free_rate          BIGINT      NOT NULL,
    onchain_timestamp       BIGINT      NOT NULL
);

-- Registry tables

CREATE TABLE IF NOT EXISTS predict_created
(
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    predict_id              TEXT        NOT NULL
);

CREATE TABLE IF NOT EXISTS oracle_created
(
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    oracle_id               TEXT        NOT NULL,
    oracle_cap_id           TEXT        NOT NULL,
    expiry                  BIGINT      NOT NULL
);

CREATE TABLE IF NOT EXISTS admin_vault_balance_changed
(
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    predict_id              TEXT        NOT NULL,
    amount                  BIGINT      NOT NULL,
    deposit                 BOOLEAN     NOT NULL
);

-- Trading tables

CREATE TABLE IF NOT EXISTS position_minted
(
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    predict_id              TEXT        NOT NULL,
    manager_id              TEXT        NOT NULL,
    trader                  TEXT        NOT NULL,
    oracle_id               TEXT        NOT NULL,
    expiry                  BIGINT      NOT NULL,
    strike                  BIGINT      NOT NULL,
    is_up                   BOOLEAN     NOT NULL,
    quantity                BIGINT      NOT NULL,
    cost                    BIGINT      NOT NULL,
    ask_price               BIGINT      NOT NULL
);

CREATE TABLE IF NOT EXISTS position_redeemed
(
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    predict_id              TEXT        NOT NULL,
    manager_id              TEXT        NOT NULL,
    trader                  TEXT        NOT NULL,
    oracle_id               TEXT        NOT NULL,
    expiry                  BIGINT      NOT NULL,
    strike                  BIGINT      NOT NULL,
    is_up                   BOOLEAN     NOT NULL,
    quantity                BIGINT      NOT NULL,
    payout                  BIGINT      NOT NULL,
    bid_price               BIGINT      NOT NULL,
    is_settled              BOOLEAN     NOT NULL
);

CREATE TABLE IF NOT EXISTS collateralized_position_minted
(
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    predict_id              TEXT        NOT NULL,
    manager_id              TEXT        NOT NULL,
    trader                  TEXT        NOT NULL,
    oracle_id               TEXT        NOT NULL,
    locked_expiry           BIGINT      NOT NULL,
    locked_strike           BIGINT      NOT NULL,
    locked_is_up            BOOLEAN     NOT NULL,
    minted_expiry           BIGINT      NOT NULL,
    minted_strike           BIGINT      NOT NULL,
    minted_is_up            BOOLEAN     NOT NULL,
    quantity                BIGINT      NOT NULL
);

CREATE TABLE IF NOT EXISTS collateralized_position_redeemed
(
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    predict_id              TEXT        NOT NULL,
    manager_id              TEXT        NOT NULL,
    trader                  TEXT        NOT NULL,
    oracle_id               TEXT        NOT NULL,
    locked_expiry           BIGINT      NOT NULL,
    locked_strike           BIGINT      NOT NULL,
    locked_is_up            BOOLEAN     NOT NULL,
    minted_expiry           BIGINT      NOT NULL,
    minted_strike           BIGINT      NOT NULL,
    minted_is_up            BOOLEAN     NOT NULL,
    quantity                BIGINT      NOT NULL
);

-- Admin tables

CREATE TABLE IF NOT EXISTS trading_pause_updated
(
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    predict_id              TEXT        NOT NULL,
    paused                  BOOLEAN     NOT NULL
);

CREATE TABLE IF NOT EXISTS pricing_config_updated
(
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    predict_id              TEXT        NOT NULL,
    base_spread             BIGINT      NOT NULL,
    max_skew_multiplier     BIGINT      NOT NULL,
    utilization_multiplier  BIGINT      NOT NULL
);

CREATE TABLE IF NOT EXISTS risk_config_updated
(
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    predict_id              TEXT        NOT NULL,
    max_total_exposure_pct  BIGINT      NOT NULL
);

-- User tables

CREATE TABLE IF NOT EXISTS predict_manager_created
(
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    manager_id              TEXT        NOT NULL,
    owner                   TEXT        NOT NULL
);
