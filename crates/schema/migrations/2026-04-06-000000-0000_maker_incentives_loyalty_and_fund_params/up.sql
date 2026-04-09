-- Extra fund parameters on FundCreated (indexed from chain events).
ALTER TABLE maker_incentive_fund_created
    ADD COLUMN IF NOT EXISTS alpha_bps BIGINT,
    ADD COLUMN IF NOT EXISTS quality_p BIGINT,
    ADD COLUMN IF NOT EXISTS epoch_duration_ms BIGINT,
    ADD COLUMN IF NOT EXISTS window_duration_ms BIGINT;

-- Tracks makers who received a positive score for an epoch (for loyalty streaks).
CREATE TABLE IF NOT EXISTS maker_incentive_maker_participation
(
    fund_id              TEXT   NOT NULL,
    epoch_start_ms       BIGINT NOT NULL,
    balance_manager_id   TEXT   NOT NULL,
    PRIMARY KEY (fund_id, epoch_start_ms, balance_manager_id)
);

CREATE INDEX IF NOT EXISTS idx_maker_incentive_participation_fund_epoch
    ON maker_incentive_maker_participation (fund_id, epoch_start_ms DESC);

CREATE INDEX IF NOT EXISTS idx_maker_incentive_participation_maker
    ON maker_incentive_maker_participation (balance_manager_id);
