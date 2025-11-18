CREATE TABLE margin_manager_state (
    id SERIAL PRIMARY KEY,
    margin_manager_id VARCHAR(66) NOT NULL,
    deepbook_pool_id VARCHAR(66) NOT NULL,
    base_margin_pool_id VARCHAR(66),
    quote_margin_pool_id VARCHAR(66),
    base_asset_id VARCHAR(255),
    base_asset_symbol VARCHAR(50),
    quote_asset_id VARCHAR(255),
    quote_asset_symbol VARCHAR(50),
    risk_ratio DECIMAL(20, 10),
    base_asset DECIMAL(40, 20),
    quote_asset DECIMAL(40, 20),
    base_debt DECIMAL(40, 20),
    quote_debt DECIMAL(40, 20),
    base_pyth_price BIGINT,
    base_pyth_decimals INTEGER,
    quote_pyth_price BIGINT,
    quote_pyth_decimals INTEGER,
    created_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP
);

CREATE INDEX idx_margin_manager_state_manager_id ON margin_manager_state(margin_manager_id);
CREATE INDEX idx_margin_manager_state_deepbook_pool_id ON margin_manager_state(deepbook_pool_id);
CREATE INDEX idx_margin_manager_state_risk_ratio ON margin_manager_state(risk_ratio);
CREATE INDEX idx_margin_manager_state_updated_at ON margin_manager_state(updated_at);
