-- Predict Managers
CREATE TABLE predict_managers (
    object_id TEXT PRIMARY KEY,
    owner_address TEXT NOT NULL,
    checkpoint BIGINT NOT NULL,
    timestamp BIGINT NOT NULL
);

-- Predict User Positions (MarketKey based)
CREATE TABLE predict_user_positions (
    manager_id TEXT NOT NULL,
    oracle_id TEXT NOT NULL,
    expiry BIGINT NOT NULL,
    strike BIGINT NOT NULL,
    is_up BOOLEAN NOT NULL,
    free_quantity BIGINT NOT NULL,
    locked_quantity BIGINT NOT NULL,
    checkpoint BIGINT NOT NULL,
    timestamp BIGINT NOT NULL,
    PRIMARY KEY (manager_id, oracle_id, expiry, strike, is_up)
);

-- Predict Collateral (CollateralKey based)
CREATE TABLE predict_collateral (
    manager_id TEXT NOT NULL,
    oracle_id TEXT NOT NULL,
    expiry BIGINT NOT NULL,
    strike BIGINT NOT NULL,
    quantity BIGINT NOT NULL,
    checkpoint BIGINT NOT NULL,
    timestamp BIGINT NOT NULL,
    PRIMARY KEY (manager_id, oracle_id, expiry, strike)
);

-- Predict Oracles
CREATE TABLE predict_oracles (
    object_id TEXT PRIMARY KEY,
    underlying_asset TEXT NOT NULL,
    pyth_lazer_feed_id INTEGER NOT NULL,
    expiry BIGINT NOT NULL,
    min_strike BIGINT NOT NULL,
    tick_size BIGINT NOT NULL,
    status SMALLINT NOT NULL, -- 0: Inactive, 1: Active, 2: PendingSettlement, 3: Settled
    settlement_price BIGINT,
    checkpoint BIGINT NOT NULL,
    timestamp BIGINT NOT NULL
);

-- Events: Position Minted
CREATE TABLE predict_events_minted (
    tx_digest TEXT NOT NULL,
    event_index BIGINT NOT NULL,
    checkpoint BIGINT NOT NULL,
    timestamp BIGINT NOT NULL,
    predict_id TEXT NOT NULL,
    manager_id TEXT NOT NULL,
    trader TEXT NOT NULL,
    quote_asset TEXT NOT NULL,
    oracle_id TEXT NOT NULL,
    expiry BIGINT NOT NULL,
    strike BIGINT NOT NULL,
    is_up BOOLEAN NOT NULL,
    quantity BIGINT NOT NULL,
    cost BIGINT NOT NULL,
    fee_amount BIGINT NOT NULL,
    PRIMARY KEY (tx_digest, event_index)
);

-- Events: Position Redeemed
CREATE TABLE predict_events_redeemed (
    tx_digest TEXT NOT NULL,
    event_index BIGINT NOT NULL,
    checkpoint BIGINT NOT NULL,
    timestamp BIGINT NOT NULL,
    predict_id TEXT NOT NULL,
    manager_id TEXT NOT NULL,
    owner TEXT NOT NULL,
    executor TEXT NOT NULL,
    quote_asset TEXT NOT NULL,
    oracle_id TEXT NOT NULL,
    expiry BIGINT NOT NULL,
    strike BIGINT NOT NULL,
    is_up BOOLEAN NOT NULL,
    quantity BIGINT NOT NULL,
    payout BIGINT NOT NULL,
    fee_amount BIGINT NOT NULL,
    is_settled BOOLEAN NOT NULL,
    PRIMARY KEY (tx_digest, event_index)
);

-- Events: Oracle Settled
CREATE TABLE predict_events_oracle_settled (
    tx_digest TEXT NOT NULL,
    event_index BIGINT NOT NULL,
    checkpoint BIGINT NOT NULL,
    timestamp BIGINT NOT NULL,
    oracle_id TEXT NOT NULL,
    expiry BIGINT NOT NULL,
    settlement_price BIGINT NOT NULL,
    spot_timestamp_ms BIGINT NOT NULL,
    PRIMARY KEY (tx_digest, event_index)
);

-- Predict Vaults (Aggregate state of Predict objects)
CREATE TABLE predict_vaults (
    object_id TEXT PRIMARY KEY,
    quote_asset TEXT NOT NULL,
    balance BIGINT NOT NULL,
    total_mtm BIGINT NOT NULL,
    total_max_payout BIGINT NOT NULL,
    total_lp_supply BIGINT NOT NULL,
    
    -- Pricing Config
    base_fee BIGINT NOT NULL,
    min_fee BIGINT NOT NULL,
    utilization_multiplier BIGINT NOT NULL,
    
    -- Risk Config
    max_total_exposure_pct BIGINT NOT NULL,
    mtm_freshness_ms BIGINT NOT NULL,
    
    -- Fee Reserve
    total_fees_accrued BIGINT NOT NULL,
    lp_fees_accrued BIGINT NOT NULL,
    protocol_fees_accrued BIGINT NOT NULL,
    insurance_fees_accrued BIGINT NOT NULL,
    
    trading_paused BOOLEAN NOT NULL,
    checkpoint BIGINT NOT NULL,
    timestamp BIGINT NOT NULL
);

-- Events: LP Supplied
CREATE TABLE predict_events_supplied (
    tx_digest TEXT NOT NULL,
    event_index BIGINT NOT NULL,
    checkpoint BIGINT NOT NULL,
    timestamp BIGINT NOT NULL,
    predict_id TEXT NOT NULL,
    supplier TEXT NOT NULL,
    quote_asset TEXT NOT NULL,
    amount BIGINT NOT NULL,
    shares_minted BIGINT NOT NULL,
    PRIMARY KEY (tx_digest, event_index)
);

-- Events: LP Withdrawn
CREATE TABLE predict_events_withdrawn (
    tx_digest TEXT NOT NULL,
    event_index BIGINT NOT NULL,
    checkpoint BIGINT NOT NULL,
    timestamp BIGINT NOT NULL,
    predict_id TEXT NOT NULL,
    withdrawer TEXT NOT NULL,
    quote_asset TEXT NOT NULL,
    amount BIGINT NOT NULL,
    shares_burned BIGINT NOT NULL,
    PRIMARY KEY (tx_digest, event_index)
);

CREATE INDEX idx_predict_user_positions_manager ON predict_user_positions(manager_id);
CREATE INDEX idx_predict_collateral_manager ON predict_collateral(manager_id);
CREATE INDEX idx_predict_events_minted_trader ON predict_events_minted(trader);
CREATE INDEX idx_predict_events_redeemed_owner ON predict_events_redeemed(owner);
CREATE INDEX idx_predict_events_supplied_supplier ON predict_events_supplied(supplier);
CREATE INDEX idx_predict_events_withdrawn_withdrawer ON predict_events_withdrawn(withdrawer);
