ALTER TABLE liquidation
    ALTER COLUMN remaining_base_asset TYPE DECIMAL(20,0) USING remaining_base_asset::DECIMAL(20,0),
    ALTER COLUMN remaining_quote_asset TYPE DECIMAL(20,0) USING remaining_quote_asset::DECIMAL(20,0),
    ALTER COLUMN remaining_base_debt TYPE DECIMAL(20,0) USING remaining_base_debt::DECIMAL(20,0),
    ALTER COLUMN remaining_quote_debt TYPE DECIMAL(20,0) USING remaining_quote_debt::DECIMAL(20,0);
