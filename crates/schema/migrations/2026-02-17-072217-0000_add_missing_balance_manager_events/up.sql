-- Event emitted when a new balance_manager is created.
CREATE TABLE balance_manager_created ( 
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    balance_manager_id          TEXT        NOT NULL,
    owner                       TEXT        NOT NULL
);

-- Event emitted when a deepbook referral is created.
CREATE TABLE deepbook_referral_created (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    referral_id                 TEXT        NOT NULL,
    owner                       TEXT        NOT NULL
);

-- Event emitted when a deepbook referral is set.
CREATE TABLE deepbook_referral_set (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    referral_id                 TEXT        NOT NULL,
    balance_manager_id          TEXT        NOT NULL
);

-- balance_manager_created
CREATE INDEX IF NOT EXISTS idx_balance_manager_created_owner ON balance_manager_created (owner);
CREATE INDEX IF NOT EXISTS idx_balance_manager_created_balance_manager_id ON balance_manager_created (balance_manager_id);
CREATE INDEX IF NOT EXISTS idx_balance_manager_created_checkpoint_timestamp_ms ON balance_manager_created (checkpoint_timestamp_ms);

-- deepbook_referral_created
CREATE INDEX IF NOT EXISTS idx_deepbook_referral_created_owner ON deepbook_referral_created (owner);
CREATE INDEX IF NOT EXISTS idx_deepbook_referral_created_referral_id ON deepbook_referral_created (referral_id);
CREATE INDEX IF NOT EXISTS idx_deepbook_referral_created_checkpoint_timestamp_ms ON deepbook_referral_created (checkpoint_timestamp_ms);

-- deepbook_referral_set
CREATE INDEX IF NOT EXISTS idx_deepbook_referral_set_balance_manager_id ON deepbook_referral_set (balance_manager_id);
CREATE INDEX IF NOT EXISTS idx_deepbook_referral_set_referral_id ON deepbook_referral_set (referral_id);
CREATE INDEX IF NOT EXISTS idx_deepbook_referral_set_checkpoint_timestamp_ms ON deepbook_referral_set (checkpoint_timestamp_ms);
