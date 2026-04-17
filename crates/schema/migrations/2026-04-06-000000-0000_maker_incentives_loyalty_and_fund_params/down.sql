DROP TABLE IF EXISTS maker_incentive_maker_participation;

ALTER TABLE maker_incentive_fund_created
    DROP COLUMN IF EXISTS alpha_bps,
    DROP COLUMN IF EXISTS quality_p,
    DROP COLUMN IF EXISTS epoch_duration_ms,
    DROP COLUMN IF EXISTS window_duration_ms;
