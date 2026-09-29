DO $$
BEGIN
    RAISE EXCEPTION 'This migration cannot be reverted because restoring partial OHLCV refreshes would corrupt candle aggregates';
END;
$$;
