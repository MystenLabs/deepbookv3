CREATE TABLE IF NOT EXISTS maker_incentive_treasury_withdrawn
(
    event_digest            TEXT         PRIMARY KEY,
    digest                  TEXT         NOT NULL,
    sender                  TEXT         NOT NULL,
    checkpoint              BIGINT       NOT NULL,
    timestamp               TIMESTAMP    DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT       NOT NULL,
    package                 TEXT         NOT NULL,
    pool_id                 TEXT         NOT NULL,
    fund_id                 TEXT         NOT NULL,
    owner                   TEXT         NOT NULL,
    amount                  BIGINT       NOT NULL,
    treasury_after          BIGINT       NOT NULL,
    locked_after            BIGINT       NOT NULL,
    withdrawable_after      BIGINT       NOT NULL,
    reward_per_epoch        BIGINT       NOT NULL
);

CREATE INDEX idx_maker_incentive_treasury_withdrawn_checkpoint_ts
    ON maker_incentive_treasury_withdrawn (checkpoint_timestamp_ms DESC);
CREATE INDEX idx_maker_incentive_treasury_withdrawn_pool_id
    ON maker_incentive_treasury_withdrawn (pool_id);
CREATE INDEX idx_maker_incentive_treasury_withdrawn_fund_id
    ON maker_incentive_treasury_withdrawn (fund_id);
