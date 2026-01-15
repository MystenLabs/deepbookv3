-- Migration: Add TPSL (Take Profit/Stop Loss) and Collateral event tables
-- These tables support the margin module events that were previously missing from the indexer

-- Collateral Events - tracks user collateral deposits and withdrawals into margin positions
-- event_type: 'deposit' or 'withdraw'
CREATE TABLE collateral_events (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    event_type                  TEXT        NOT NULL,
    margin_manager_id           TEXT        NOT NULL,
    amount                      NUMERIC     NOT NULL,
    asset_type                  TEXT        NOT NULL,
    -- Deposit fields (also used for withdraw single-asset pricing)
    pyth_decimals               SMALLINT    NOT NULL,
    pyth_price                  NUMERIC     NOT NULL,
    -- Withdraw-specific fields (nullable for deposits)
    withdraw_base_asset         BOOLEAN,
    base_pyth_decimals          SMALLINT,
    base_pyth_price             NUMERIC,
    quote_pyth_decimals         SMALLINT,
    quote_pyth_price            NUMERIC,
    remaining_base_asset        NUMERIC,
    remaining_quote_asset       NUMERIC,
    remaining_base_debt         NUMERIC,
    remaining_quote_debt        NUMERIC,
    onchain_timestamp           BIGINT      NOT NULL
);

-- Conditional Order Events - tracks TPSL (take profit/stop loss) order lifecycle
-- event_type: 'added', 'cancelled', 'executed', 'insufficient_funds'
CREATE TABLE conditional_order_events (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    event_type                  TEXT        NOT NULL,
    manager_id                  TEXT        NOT NULL,
    pool_id                     TEXT,
    conditional_order_id        BIGINT      NOT NULL,
    trigger_below_price         BOOLEAN     NOT NULL,
    trigger_price               NUMERIC     NOT NULL,
    is_limit_order              BOOLEAN     NOT NULL,
    client_order_id             BIGINT      NOT NULL,
    order_type                  SMALLINT    NOT NULL,
    self_matching_option        SMALLINT    NOT NULL,
    price                       NUMERIC     NOT NULL,
    quantity                    NUMERIC     NOT NULL,
    is_bid                      BOOLEAN     NOT NULL,
    pay_with_deep               BOOLEAN     NOT NULL,
    expire_timestamp            BIGINT      NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

-- Create indexes for common query patterns
CREATE INDEX idx_collateral_events_margin_manager ON collateral_events(margin_manager_id);
CREATE INDEX idx_collateral_events_checkpoint ON collateral_events(checkpoint);
CREATE INDEX idx_collateral_events_type ON collateral_events(event_type);

CREATE INDEX idx_conditional_order_events_manager ON conditional_order_events(manager_id);
CREATE INDEX idx_conditional_order_events_pool ON conditional_order_events(pool_id);
CREATE INDEX idx_conditional_order_events_checkpoint ON conditional_order_events(checkpoint);
CREATE INDEX idx_conditional_order_events_order_id ON conditional_order_events(conditional_order_id);
CREATE INDEX idx_conditional_order_events_type ON conditional_order_events(event_type);
