ALTER TABLE liquidation
    ALTER COLUMN remaining_base_asset TYPE BIGINT USING remaining_base_asset::BIGINT,
    ALTER COLUMN remaining_quote_asset TYPE BIGINT USING remaining_quote_asset::BIGINT,
    ALTER COLUMN remaining_base_debt TYPE BIGINT USING remaining_base_debt::BIGINT,
    ALTER COLUMN remaining_quote_debt TYPE BIGINT USING remaining_quote_debt::BIGINT;
