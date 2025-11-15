CREATE TABLE maintainer_fees_withdrawn (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    margin_pool_id              TEXT        NOT NULL,
    margin_pool_cap_id          TEXT        NOT NULL,
    maintainer_fees             BIGINT      NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

CREATE TABLE protocol_fees_withdrawn (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    margin_pool_id              TEXT        NOT NULL,
    protocol_fees               BIGINT      NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

CREATE TABLE supplier_cap_minted (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    supplier_cap_id             TEXT        NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

CREATE TABLE supply_referral_minted (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    margin_pool_id              TEXT        NOT NULL,
    supply_referral_id          TEXT        NOT NULL,
    owner                       TEXT        NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

CREATE TABLE pause_cap_updated (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    pause_cap_id                TEXT        NOT NULL,
    allowed                     BOOLEAN     NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

CREATE TABLE protocol_fees_increased (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    margin_pool_id              TEXT        NOT NULL,
    total_shares                BIGINT      NOT NULL,
    referral_fees               BIGINT      NOT NULL,
    maintainer_fees             BIGINT      NOT NULL,
    protocol_fees               BIGINT      NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

CREATE TABLE referral_fees_claimed (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    referral_id                 TEXT        NOT NULL,
    owner                       TEXT        NOT NULL,
    fees                        BIGINT      NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

-- Indexes for maintainer_fees_withdrawn table
CREATE INDEX IF NOT EXISTS idx_maintainer_fees_withdrawn_checkpoint_timestamp_ms
    ON maintainer_fees_withdrawn (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_maintainer_fees_withdrawn_margin_pool_id
    ON maintainer_fees_withdrawn (margin_pool_id);

CREATE INDEX IF NOT EXISTS idx_maintainer_fees_withdrawn_margin_pool_cap_id
    ON maintainer_fees_withdrawn (margin_pool_cap_id);

-- Indexes for protocol_fees_withdrawn table
CREATE INDEX IF NOT EXISTS idx_protocol_fees_withdrawn_checkpoint_timestamp_ms
    ON protocol_fees_withdrawn (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_protocol_fees_withdrawn_margin_pool_id
    ON protocol_fees_withdrawn (margin_pool_id);

-- Indexes for supplier_cap_minted table
CREATE INDEX IF NOT EXISTS idx_supplier_cap_minted_checkpoint_timestamp_ms
    ON supplier_cap_minted (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_supplier_cap_minted_supplier_cap_id
    ON supplier_cap_minted (supplier_cap_id);

-- Indexes for supply_referral_minted table
CREATE INDEX IF NOT EXISTS idx_supply_referral_minted_checkpoint_timestamp_ms
    ON supply_referral_minted (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_supply_referral_minted_margin_pool_id
    ON supply_referral_minted (margin_pool_id);

CREATE INDEX IF NOT EXISTS idx_supply_referral_minted_owner
    ON supply_referral_minted (owner);

CREATE INDEX IF NOT EXISTS idx_supply_referral_minted_supply_referral_id
    ON supply_referral_minted (supply_referral_id);

-- Indexes for pause_cap_updated table
CREATE INDEX IF NOT EXISTS idx_pause_cap_updated_checkpoint_timestamp_ms
    ON pause_cap_updated (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_pause_cap_updated_pause_cap_id
    ON pause_cap_updated (pause_cap_id);

-- Indexes for protocol_fees_increased table
CREATE INDEX IF NOT EXISTS idx_protocol_fees_increased_checkpoint_timestamp_ms
    ON protocol_fees_increased (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_protocol_fees_increased_margin_pool_id
    ON protocol_fees_increased (margin_pool_id);

-- Indexes for referral_fees_claimed table
CREATE INDEX IF NOT EXISTS idx_referral_fees_claimed_checkpoint_timestamp_ms
    ON referral_fees_claimed (checkpoint_timestamp_ms);

CREATE INDEX IF NOT EXISTS idx_referral_fees_claimed_referral_id
    ON referral_fees_claimed (referral_id);

CREATE INDEX IF NOT EXISTS idx_referral_fees_claimed_owner
    ON referral_fees_claimed (owner);

