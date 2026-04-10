CREATE TABLE IF NOT EXISTS maker_incentive_fund_created
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
    creator                 TEXT         NOT NULL,
    created_at_ms           BIGINT       NOT NULL
);

CREATE INDEX idx_maker_incentive_fund_created_checkpoint_ts
    ON maker_incentive_fund_created (checkpoint_timestamp_ms DESC);
CREATE INDEX idx_maker_incentive_fund_created_pool_id
    ON maker_incentive_fund_created (pool_id);
CREATE INDEX idx_maker_incentive_fund_created_fund_id
    ON maker_incentive_fund_created (fund_id);

CREATE TABLE IF NOT EXISTS maker_incentive_epoch_results_submitted
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
    epoch_start_ms          BIGINT       NOT NULL,
    epoch_end_ms            BIGINT       NOT NULL,
    total_allocation        BIGINT       NOT NULL,
    num_makers              BIGINT       NOT NULL
);

CREATE INDEX idx_maker_incentive_epoch_results_checkpoint_ts
    ON maker_incentive_epoch_results_submitted (checkpoint_timestamp_ms DESC);
CREATE INDEX idx_maker_incentive_epoch_results_pool_id
    ON maker_incentive_epoch_results_submitted (pool_id);
CREATE INDEX idx_maker_incentive_epoch_results_fund_id
    ON maker_incentive_epoch_results_submitted (fund_id);

CREATE TABLE IF NOT EXISTS maker_incentive_reward_claimed
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
    epoch_start_ms          BIGINT       NOT NULL,
    balance_manager_id      TEXT         NOT NULL,
    amount                  BIGINT       NOT NULL
);

CREATE INDEX idx_maker_incentive_reward_claimed_checkpoint_ts
    ON maker_incentive_reward_claimed (checkpoint_timestamp_ms DESC);
CREATE INDEX idx_maker_incentive_reward_claimed_pool_id
    ON maker_incentive_reward_claimed (pool_id);
CREATE INDEX idx_maker_incentive_reward_claimed_fund_id
    ON maker_incentive_reward_claimed (fund_id);
CREATE INDEX idx_maker_incentive_reward_claimed_balance_manager
    ON maker_incentive_reward_claimed (balance_manager_id);
