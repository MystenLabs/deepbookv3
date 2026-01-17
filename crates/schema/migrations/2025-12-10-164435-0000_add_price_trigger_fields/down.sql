ALTER TABLE margin_manager_state
    DROP COLUMN current_price,
    DROP COLUMN lowest_trigger_above_price,
    DROP COLUMN highest_trigger_below_price;
