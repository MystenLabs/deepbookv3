CREATE TABLE IF NOT EXISTS predict_manager_created (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    predict_manager_id       TEXT      NOT NULL,
    balance_manager_id       TEXT      NOT NULL,
    owner                    TEXT      NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_predict_manager_created_owner_ts ON predict_manager_created(owner, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_predict_manager_created_manager_id ON predict_manager_created(predict_manager_id);
CREATE INDEX IF NOT EXISTS idx_predict_manager_created_balance_manager_id ON predict_manager_created(balance_manager_id);

CREATE TABLE IF NOT EXISTS builder_code_created (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    builder_code_id          TEXT      NOT NULL,
    owner                    TEXT      NOT NULL,
    builder_code_index       NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_builder_code_created_owner_ts ON builder_code_created(owner, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_builder_code_created_builder_code_id ON builder_code_created(builder_code_id);

CREATE TABLE IF NOT EXISTS builder_code_set (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    predict_manager_id       TEXT      NOT NULL,
    owner                    TEXT      NOT NULL,
    builder_code_id          TEXT
);
CREATE INDEX IF NOT EXISTS idx_builder_code_set_manager_ts ON builder_code_set(predict_manager_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS predict_trade_cap_minted (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    predict_manager_id       TEXT      NOT NULL,
    cap_id                   TEXT      NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_predict_trade_cap_minted_manager_ts ON predict_trade_cap_minted(predict_manager_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_predict_trade_cap_minted_cap_id ON predict_trade_cap_minted(cap_id);

CREATE TABLE IF NOT EXISTS predict_deposit_cap_minted (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    predict_manager_id       TEXT      NOT NULL,
    cap_id                   TEXT      NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_predict_deposit_cap_minted_manager_ts ON predict_deposit_cap_minted(predict_manager_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_predict_deposit_cap_minted_cap_id ON predict_deposit_cap_minted(cap_id);

CREATE TABLE IF NOT EXISTS predict_withdraw_cap_minted (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    predict_manager_id       TEXT      NOT NULL,
    cap_id                   TEXT      NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_predict_withdraw_cap_minted_manager_ts ON predict_withdraw_cap_minted(predict_manager_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_predict_withdraw_cap_minted_cap_id ON predict_withdraw_cap_minted(cap_id);
