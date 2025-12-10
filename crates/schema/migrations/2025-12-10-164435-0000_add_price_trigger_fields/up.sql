ALTER TABLE margin_manager_state
    ADD COLUMN current_price BIGINT,
    ADD COLUMN lowest_trigger_above_price BIGINT,
    ADD COLUMN highest_trigger_below_price BIGINT;
