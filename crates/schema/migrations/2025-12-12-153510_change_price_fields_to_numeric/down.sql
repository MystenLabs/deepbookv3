ALTER TABLE margin_manager_state
    ALTER COLUMN current_price TYPE BIGINT,
    ALTER COLUMN lowest_trigger_above_price TYPE BIGINT,
    ALTER COLUMN highest_trigger_below_price TYPE BIGINT;
