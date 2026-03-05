-- ReferralClaimed - tracks referral rebate claims from pools
CREATE TABLE referral_claimed (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    pool_id                     TEXT        NOT NULL,
    referral_id                 TEXT        NOT NULL,
    owner                       TEXT        NOT NULL,
    base_amount                 BIGINT      NOT NULL,
    quote_amount                BIGINT      NOT NULL,
    deep_amount                 BIGINT      NOT NULL
);

-- EWMAUpdate - tracks EWMA price/variance updates per pool
CREATE TABLE ewma_updates (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    pool_id                     TEXT        NOT NULL,
    gas_price                   BIGINT      NOT NULL,
    mean                        BIGINT      NOT NULL,
    variance                    BIGINT      NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

-- TakerFeePenaltyApplied - tracks when taker fee penalties are applied to orders
CREATE TABLE taker_fee_penalty_applied (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    pool_id                     TEXT        NOT NULL,
    balance_manager_id          TEXT        NOT NULL,
    order_id                    NUMERIC     NOT NULL,
    taker_fee_without_penalty   BIGINT      NOT NULL,
    taker_fee                   BIGINT      NOT NULL
);

CREATE INDEX idx_referral_claimed_pool ON referral_claimed(pool_id);
CREATE INDEX idx_referral_claimed_owner ON referral_claimed(owner);
CREATE INDEX idx_referral_claimed_checkpoint ON referral_claimed(checkpoint);

CREATE INDEX idx_ewma_updates_pool ON ewma_updates(pool_id);
CREATE INDEX idx_ewma_updates_checkpoint ON ewma_updates(checkpoint);

CREATE INDEX idx_taker_fee_penalty_pool ON taker_fee_penalty_applied(pool_id);
CREATE INDEX idx_taker_fee_penalty_balance_manager ON taker_fee_penalty_applied(balance_manager_id);
CREATE INDEX idx_taker_fee_penalty_checkpoint ON taker_fee_penalty_applied(checkpoint);
