-- Oracle tables
CREATE TABLE IF NOT EXISTS oracle_activated (
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

CREATE TABLE IF NOT EXISTS oracle_settled (
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

CREATE TABLE IF NOT EXISTS oracle_prices_updated (
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

-- OracleSVIUpdated: rho and m are signed (I64). risk_free_rate removed.
CREATE TABLE IF NOT EXISTS oracle_svi_updated (
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
    onchain_timestamp       BIGINT      NOT NULL
);

-- Registry tables
CREATE TABLE IF NOT EXISTS predict_created (
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    predict_id              TEXT        NOT NULL
);

-- OracleCreated: added underlying_asset, min_strike, tick_size.
CREATE TABLE IF NOT EXISTS oracle_created (
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    oracle_id               TEXT        NOT NULL,
    oracle_cap_id           TEXT        NOT NULL,
    underlying_asset        TEXT        NOT NULL,
    expiry                  BIGINT      NOT NULL,
    min_strike              BIGINT      NOT NULL,
    tick_size               BIGINT      NOT NULL
);

-- Trading tables
-- PositionMinted: added quote_asset.
CREATE TABLE IF NOT EXISTS position_minted (
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
    quote_asset             TEXT        NOT NULL,
    oracle_id               TEXT        NOT NULL,
    expiry                  BIGINT      NOT NULL,
    strike                  BIGINT      NOT NULL,
    is_up                   BOOLEAN     NOT NULL,
    quantity                BIGINT      NOT NULL,
    cost                    BIGINT      NOT NULL,
    ask_price               BIGINT      NOT NULL
);

-- PositionRedeemed: renamed trader->owner, added executor, added quote_asset.
CREATE TABLE IF NOT EXISTS position_redeemed (
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    predict_id              TEXT        NOT NULL,
    manager_id              TEXT        NOT NULL,
    owner                   TEXT        NOT NULL,
    executor                TEXT        NOT NULL,
    quote_asset             TEXT        NOT NULL,
    oracle_id               TEXT        NOT NULL,
    expiry                  BIGINT      NOT NULL,
    strike                  BIGINT      NOT NULL,
    is_up                   BOOLEAN     NOT NULL,
    quantity                BIGINT      NOT NULL,
    payout                  BIGINT      NOT NULL,
    bid_price               BIGINT      NOT NULL,
    is_settled              BOOLEAN     NOT NULL
);

CREATE TABLE IF NOT EXISTS range_minted (
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
    quote_asset             TEXT        NOT NULL,
    oracle_id               TEXT        NOT NULL,
    expiry                  BIGINT      NOT NULL,
    lower_strike            BIGINT      NOT NULL,
    higher_strike           BIGINT      NOT NULL,
    quantity                BIGINT      NOT NULL,
    cost                    BIGINT      NOT NULL,
    ask_price               BIGINT      NOT NULL
);

CREATE TABLE IF NOT EXISTS range_redeemed (
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
    quote_asset             TEXT        NOT NULL,
    oracle_id               TEXT        NOT NULL,
    expiry                  BIGINT      NOT NULL,
    lower_strike            BIGINT      NOT NULL,
    higher_strike           BIGINT      NOT NULL,
    quantity                BIGINT      NOT NULL,
    payout                  BIGINT      NOT NULL,
    bid_price               BIGINT      NOT NULL,
    is_settled              BOOLEAN     NOT NULL
);

-- LP vault tables
CREATE TABLE IF NOT EXISTS supplied (
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    predict_id              TEXT        NOT NULL,
    supplier                TEXT        NOT NULL,
    quote_asset             TEXT        NOT NULL,
    amount                  BIGINT      NOT NULL,
    shares_minted           BIGINT      NOT NULL
);

CREATE TABLE IF NOT EXISTS withdrawn (
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    predict_id              TEXT        NOT NULL,
    withdrawer              TEXT        NOT NULL,
    quote_asset             TEXT        NOT NULL,
    amount                  BIGINT      NOT NULL,
    shares_burned           BIGINT      NOT NULL
);

-- Admin tables
CREATE TABLE IF NOT EXISTS trading_pause_updated (
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

-- PricingConfigUpdated: replaced max_skew_multiplier with min_spread,
-- min_ask_price, max_ask_price.
CREATE TABLE IF NOT EXISTS pricing_config_updated (
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    predict_id              TEXT        NOT NULL,
    base_spread             BIGINT      NOT NULL,
    min_spread              BIGINT      NOT NULL,
    utilization_multiplier  BIGINT      NOT NULL,
    min_ask_price           BIGINT      NOT NULL,
    max_ask_price           BIGINT      NOT NULL
);

CREATE TABLE IF NOT EXISTS risk_config_updated (
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

CREATE TABLE IF NOT EXISTS oracle_ask_bounds_set (
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    predict_id              TEXT        NOT NULL,
    oracle_id               TEXT        NOT NULL,
    min_ask_price           BIGINT      NOT NULL,
    max_ask_price           BIGINT      NOT NULL
);

CREATE TABLE IF NOT EXISTS oracle_ask_bounds_cleared (
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    predict_id              TEXT        NOT NULL,
    oracle_id               TEXT        NOT NULL
);

CREATE TABLE IF NOT EXISTS quote_asset_enabled (
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    predict_id              TEXT        NOT NULL,
    quote_asset             TEXT        NOT NULL
);

CREATE TABLE IF NOT EXISTS quote_asset_disabled (
    event_digest            TEXT        PRIMARY KEY,
    digest                  TEXT        NOT NULL,
    sender                  TEXT        NOT NULL,
    checkpoint              BIGINT      NOT NULL,
    timestamp               TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT      NOT NULL,
    package                 TEXT        NOT NULL,
    predict_id              TEXT        NOT NULL,
    quote_asset             TEXT        NOT NULL
);

-- User tables
-- predict_manager_created: emitted by predict_manager::new (module = "predict_manager").
CREATE TABLE IF NOT EXISTS predict_manager_created (
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
