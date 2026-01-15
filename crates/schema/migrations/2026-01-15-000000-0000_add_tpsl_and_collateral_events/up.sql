-- Migration: Add TPSL (Take Profit/Stop Loss) and Collateral event tables
-- These tables support the margin module events that were previously missing from the indexer

-- Deposit Collateral Event - tracks user collateral deposits into margin positions
CREATE TABLE deposit_collateral (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    margin_manager_id           TEXT        NOT NULL,
    amount                      NUMERIC     NOT NULL,
    asset_type                  TEXT        NOT NULL,
    pyth_decimals               SMALLINT    NOT NULL,
    pyth_price                  NUMERIC     NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

-- Withdraw Collateral Event - tracks user collateral withdrawals from margin positions
CREATE TABLE withdraw_collateral (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    margin_manager_id           TEXT        NOT NULL,
    amount                      NUMERIC     NOT NULL,
    asset_type                  TEXT        NOT NULL,
    withdraw_base_asset         BOOLEAN     NOT NULL,
    base_pyth_decimals          SMALLINT    NOT NULL,
    base_pyth_price             NUMERIC     NOT NULL,
    quote_pyth_decimals         SMALLINT    NOT NULL,
    quote_pyth_price            NUMERIC     NOT NULL,
    remaining_base_asset        NUMERIC     NOT NULL,
    remaining_quote_asset       NUMERIC     NOT NULL,
    remaining_base_debt         NUMERIC     NOT NULL,
    remaining_quote_debt        NUMERIC     NOT NULL,
    onchain_timestamp           BIGINT      NOT NULL
);

-- Conditional Order Added - tracks creation of TPSL (take profit/stop loss) orders
CREATE TABLE conditional_order_added (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    manager_id                  TEXT        NOT NULL,
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

-- Conditional Order Cancelled - tracks cancellation of TPSL orders
CREATE TABLE conditional_order_cancelled (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    manager_id                  TEXT        NOT NULL,
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

-- Conditional Order Executed - tracks when TPSL orders are triggered and executed
CREATE TABLE conditional_order_executed (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    manager_id                  TEXT        NOT NULL,
    pool_id                     TEXT        NOT NULL,
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

-- Conditional Order Insufficient Funds - tracks when TPSL orders fail due to lack of funds
CREATE TABLE conditional_order_insufficient_funds (
    event_digest                TEXT        PRIMARY KEY,
    digest                      TEXT        NOT NULL,
    sender                      TEXT        NOT NULL,
    checkpoint                  BIGINT      NOT NULL,
    timestamp                   TIMESTAMP   DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms     BIGINT      NOT NULL,
    package                     TEXT        NOT NULL,
    manager_id                  TEXT        NOT NULL,
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
CREATE INDEX idx_deposit_collateral_margin_manager ON deposit_collateral(margin_manager_id);
CREATE INDEX idx_deposit_collateral_checkpoint ON deposit_collateral(checkpoint);

CREATE INDEX idx_withdraw_collateral_margin_manager ON withdraw_collateral(margin_manager_id);
CREATE INDEX idx_withdraw_collateral_checkpoint ON withdraw_collateral(checkpoint);

CREATE INDEX idx_conditional_order_added_manager ON conditional_order_added(manager_id);
CREATE INDEX idx_conditional_order_added_checkpoint ON conditional_order_added(checkpoint);
CREATE INDEX idx_conditional_order_added_order_id ON conditional_order_added(conditional_order_id);

CREATE INDEX idx_conditional_order_cancelled_manager ON conditional_order_cancelled(manager_id);
CREATE INDEX idx_conditional_order_cancelled_checkpoint ON conditional_order_cancelled(checkpoint);
CREATE INDEX idx_conditional_order_cancelled_order_id ON conditional_order_cancelled(conditional_order_id);

CREATE INDEX idx_conditional_order_executed_manager ON conditional_order_executed(manager_id);
CREATE INDEX idx_conditional_order_executed_pool ON conditional_order_executed(pool_id);
CREATE INDEX idx_conditional_order_executed_checkpoint ON conditional_order_executed(checkpoint);
CREATE INDEX idx_conditional_order_executed_order_id ON conditional_order_executed(conditional_order_id);

CREATE INDEX idx_conditional_order_insufficient_funds_manager ON conditional_order_insufficient_funds(manager_id);
CREATE INDEX idx_conditional_order_insufficient_funds_checkpoint ON conditional_order_insufficient_funds(checkpoint);
CREATE INDEX idx_conditional_order_insufficient_funds_order_id ON conditional_order_insufficient_funds(conditional_order_id);
