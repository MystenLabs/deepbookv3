-- Your SQL goes here
-- Event emitted when a new balance_manager is created.
CREATE TABLE balance_managers ( 
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