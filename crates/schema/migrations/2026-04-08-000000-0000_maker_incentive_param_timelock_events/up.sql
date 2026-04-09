CREATE TABLE IF NOT EXISTS maker_incentive_params_scheduled
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
    reward_per_epoch        BIGINT       NOT NULL,
    alpha_bps               BIGINT       NOT NULL,
    quality_p               BIGINT       NOT NULL,
    effective_at_ms         BIGINT       NOT NULL,
    scheduled_at_ms         BIGINT       NOT NULL
);

CREATE INDEX idx_maker_incentive_params_scheduled_checkpoint_ts
    ON maker_incentive_params_scheduled (checkpoint_timestamp_ms DESC);
CREATE INDEX idx_maker_incentive_params_scheduled_pool_id
    ON maker_incentive_params_scheduled (pool_id);
CREATE INDEX idx_maker_incentive_params_scheduled_fund_id
    ON maker_incentive_params_scheduled (fund_id);

CREATE TABLE IF NOT EXISTS maker_incentive_params_applied
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
    reward_per_epoch        BIGINT       NOT NULL,
    alpha_bps               BIGINT       NOT NULL,
    quality_p               BIGINT       NOT NULL
);

CREATE INDEX idx_maker_incentive_params_applied_checkpoint_ts
    ON maker_incentive_params_applied (checkpoint_timestamp_ms DESC);
CREATE INDEX idx_maker_incentive_params_applied_pool_id
    ON maker_incentive_params_applied (pool_id);
CREATE INDEX idx_maker_incentive_params_applied_fund_id
    ON maker_incentive_params_applied (fund_id);

CREATE TABLE IF NOT EXISTS maker_incentive_params_cancelled
(
    event_digest            TEXT         PRIMARY KEY,
    digest                  TEXT         NOT NULL,
    sender                  TEXT         NOT NULL,
    checkpoint              BIGINT       NOT NULL,
    timestamp               TIMESTAMP    DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms BIGINT       NOT NULL,
    package                 TEXT         NOT NULL,
    pool_id                 TEXT         NOT NULL,
    fund_id                 TEXT         NOT NULL
);

CREATE INDEX idx_maker_incentive_params_cancelled_checkpoint_ts
    ON maker_incentive_params_cancelled (checkpoint_timestamp_ms DESC);
CREATE INDEX idx_maker_incentive_params_cancelled_pool_id
    ON maker_incentive_params_cancelled (pool_id);
CREATE INDEX idx_maker_incentive_params_cancelled_fund_id
    ON maker_incentive_params_cancelled (fund_id);
