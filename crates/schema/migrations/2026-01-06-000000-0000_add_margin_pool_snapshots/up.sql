CREATE TABLE margin_pool_snapshots (
    id BIGSERIAL PRIMARY KEY,
    margin_pool_id TEXT NOT NULL,
    asset_type TEXT NOT NULL,
    timestamp TIMESTAMP NOT NULL DEFAULT NOW(),

    -- Pool state (raw values from RPC)
    total_supply BIGINT NOT NULL,
    total_borrow BIGINT NOT NULL,
    vault_balance BIGINT NOT NULL,
    supply_cap BIGINT NOT NULL,
    interest_rate BIGINT NOT NULL,
    available_withdrawal BIGINT NOT NULL,

    -- Computed metrics
    utilization_rate DOUBLE PRECISION NOT NULL,
    solvency_ratio DOUBLE PRECISION,
    available_liquidity_pct DOUBLE PRECISION
);

CREATE INDEX idx_margin_pool_snapshots_pool_time
    ON margin_pool_snapshots (margin_pool_id, timestamp DESC);
