ALTER TABLE liquidation
    ADD COLUMN remaining_base_asset BIGINT NOT NULL DEFAULT 0,
    ADD COLUMN remaining_quote_asset BIGINT NOT NULL DEFAULT 0,
    ADD COLUMN remaining_base_debt BIGINT NOT NULL DEFAULT 0,
    ADD COLUMN remaining_quote_debt BIGINT NOT NULL DEFAULT 0,
    ADD COLUMN base_pyth_price BIGINT NOT NULL DEFAULT 0,
    ADD COLUMN base_pyth_decimals SMALLINT NOT NULL DEFAULT 0,
    ADD COLUMN quote_pyth_price BIGINT NOT NULL DEFAULT 0,
    ADD COLUMN quote_pyth_decimals SMALLINT NOT NULL DEFAULT 0;
