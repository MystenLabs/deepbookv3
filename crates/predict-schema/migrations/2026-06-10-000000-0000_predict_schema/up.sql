CREATE TABLE IF NOT EXISTS order_minted (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    expiry_market_id         TEXT      NOT NULL,
    predict_manager_id       TEXT      NOT NULL,
    order_id                 TEXT      NOT NULL,
    position_root_id         TEXT      NOT NULL,
    owner                    TEXT      NOT NULL,
    lower_strike             NUMERIC   NOT NULL,
    higher_strike            NUMERIC   NOT NULL,
    leverage                 BIGINT    NOT NULL,
    entry_probability        BIGINT    NOT NULL,
    quantity                 NUMERIC   NOT NULL,
    net_premium              NUMERIC   NOT NULL,
    trading_fee              NUMERIC   NOT NULL,
    builder_fee              NUMERIC   NOT NULL,
    penalty_fee              NUMERIC   NOT NULL,
    builder_code_id          TEXT
);
CREATE INDEX IF NOT EXISTS idx_order_minted_expiry_market_ts ON order_minted(expiry_market_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_order_minted_manager_ts ON order_minted(predict_manager_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_order_minted_order_id ON order_minted(order_id);
CREATE INDEX IF NOT EXISTS idx_order_minted_position_root ON order_minted(position_root_id);

CREATE TABLE IF NOT EXISTS live_order_redeemed (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    expiry_market_id         TEXT      NOT NULL,
    predict_manager_id       TEXT      NOT NULL,
    order_id                 TEXT      NOT NULL,
    position_root_id         TEXT      NOT NULL,
    owner                    TEXT      NOT NULL,
    quantity_closed          NUMERIC   NOT NULL,
    remaining_quantity       NUMERIC   NOT NULL,
    replacement_order_id     TEXT,
    redeem_amount            NUMERIC   NOT NULL,
    trading_fee              NUMERIC   NOT NULL,
    builder_fee              NUMERIC   NOT NULL,
    penalty_fee              NUMERIC   NOT NULL,
    builder_code_id          TEXT
);
CREATE INDEX IF NOT EXISTS idx_live_redeemed_expiry_market_ts ON live_order_redeemed(expiry_market_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_live_redeemed_manager_ts ON live_order_redeemed(predict_manager_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_live_redeemed_position_root ON live_order_redeemed(position_root_id);

CREATE TABLE IF NOT EXISTS settled_order_redeemed (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    expiry_market_id         TEXT      NOT NULL,
    predict_manager_id       TEXT      NOT NULL,
    order_id                 TEXT      NOT NULL,
    position_root_id         TEXT      NOT NULL,
    owner                    TEXT      NOT NULL,
    quantity_closed          NUMERIC   NOT NULL,
    settlement_price         NUMERIC   NOT NULL,
    payout_amount            NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_settled_redeemed_expiry_market_ts ON settled_order_redeemed(expiry_market_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_settled_redeemed_manager_ts ON settled_order_redeemed(predict_manager_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_settled_redeemed_position_root ON settled_order_redeemed(position_root_id);

CREATE TABLE IF NOT EXISTS liquidated_order_redeemed (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    expiry_market_id         TEXT      NOT NULL,
    predict_manager_id       TEXT      NOT NULL,
    order_id                 TEXT      NOT NULL,
    position_root_id         TEXT      NOT NULL,
    owner                    TEXT      NOT NULL,
    quantity_closed          NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_liq_redeemed_expiry_market_ts ON liquidated_order_redeemed(expiry_market_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_liq_redeemed_manager_ts ON liquidated_order_redeemed(predict_manager_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_liq_redeemed_position_root ON liquidated_order_redeemed(position_root_id);

CREATE TABLE IF NOT EXISTS order_liquidated (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    expiry_market_id         TEXT      NOT NULL,
    order_id                 TEXT      NOT NULL,
    quantity                 NUMERIC   NOT NULL,
    gross_value              NUMERIC   NOT NULL,
    floor_amount             NUMERIC   NOT NULL,
    liquidation_ltv          BIGINT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_order_liquidated_expiry_market_ts ON order_liquidated(expiry_market_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_order_liquidated_order_id ON order_liquidated(order_id);

CREATE TABLE IF NOT EXISTS predict_manager_created (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    predict_manager_id       TEXT      NOT NULL,
    balance_manager_id       TEXT      NOT NULL,
    owner                    TEXT      NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_predict_manager_created_owner_ts ON predict_manager_created(owner, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_predict_manager_created_manager_id ON predict_manager_created(predict_manager_id);
CREATE INDEX IF NOT EXISTS idx_predict_manager_created_balance_manager_id ON predict_manager_created(balance_manager_id);

CREATE TABLE IF NOT EXISTS builder_code_created (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    builder_code_id          TEXT      NOT NULL,
    owner                    TEXT      NOT NULL,
    builder_code_index       NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_builder_code_created_owner_ts ON builder_code_created(owner, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_builder_code_created_builder_code_id ON builder_code_created(builder_code_id);

CREATE TABLE IF NOT EXISTS builder_code_set (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    predict_manager_id       TEXT      NOT NULL,
    owner                    TEXT      NOT NULL,
    builder_code_id          TEXT
);
CREATE INDEX IF NOT EXISTS idx_builder_code_set_manager_ts ON builder_code_set(predict_manager_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS predict_trade_cap_minted (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    predict_manager_id       TEXT      NOT NULL,
    cap_id                   TEXT      NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_predict_trade_cap_minted_manager_ts ON predict_trade_cap_minted(predict_manager_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_predict_trade_cap_minted_cap_id ON predict_trade_cap_minted(cap_id);

CREATE TABLE IF NOT EXISTS predict_deposit_cap_minted (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    predict_manager_id       TEXT      NOT NULL,
    cap_id                   TEXT      NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_predict_deposit_cap_minted_manager_ts ON predict_deposit_cap_minted(predict_manager_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_predict_deposit_cap_minted_cap_id ON predict_deposit_cap_minted(cap_id);

CREATE TABLE IF NOT EXISTS predict_withdraw_cap_minted (
    event_digest             TEXT      PRIMARY KEY,
    digest                   TEXT      NOT NULL,
    sender                   TEXT      NOT NULL,
    checkpoint               BIGINT    NOT NULL,
    tx_index                 BIGINT    NOT NULL,
    event_index              BIGINT    NOT NULL,
    timestamp                TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms  BIGINT    NOT NULL,
    package                  TEXT      NOT NULL,
    predict_manager_id       TEXT      NOT NULL,
    cap_id                   TEXT      NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_predict_withdraw_cap_minted_manager_ts ON predict_withdraw_cap_minted(predict_manager_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_predict_withdraw_cap_minted_cap_id ON predict_withdraw_cap_minted(cap_id);

CREATE TABLE IF NOT EXISTS pricing_config_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    protocol_config_id               TEXT      NOT NULL,
    pyth_spot_freshness_ms           BIGINT    NOT NULL,
    block_scholes_prices_freshness_ms BIGINT   NOT NULL,
    block_scholes_svi_freshness_ms   BIGINT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_pricing_config_updated_config_ts ON pricing_config_updated(protocol_config_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS fee_config_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    protocol_config_id               TEXT      NOT NULL,
    protocol_reserve_profit_share    BIGINT    NOT NULL,
    withdraw_fee_alpha               BIGINT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_fee_config_updated_config_ts ON fee_config_updated(protocol_config_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS risk_config_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    protocol_config_id               TEXT      NOT NULL,
    valuation_liquidation_budget     BIGINT    NOT NULL,
    trade_liquidation_budget         BIGINT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_risk_config_updated_config_ts ON risk_config_updated(protocol_config_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS expiry_cash_template_config_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    protocol_config_id               TEXT      NOT NULL,
    trading_loss_rebate_rate         BIGINT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_expiry_cash_template_config_updated_config_ts ON expiry_cash_template_config_updated(protocol_config_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS strike_exposure_template_config_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    protocol_config_id               TEXT      NOT NULL,
    terminal_floor_index             BIGINT    NOT NULL,
    liquidation_ltv                  BIGINT    NOT NULL,
    backing_buffer_lambda            BIGINT    NOT NULL,
    base_fee                         NUMERIC   NOT NULL,
    min_fee                          NUMERIC   NOT NULL,
    min_ask_price                    NUMERIC   NOT NULL,
    max_ask_price                    NUMERIC   NOT NULL,
    expiry_fee_window_ms             BIGINT    NOT NULL,
    expiry_fee_max_multiplier        BIGINT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_strike_exposure_template_config_updated_config_ts ON strike_exposure_template_config_updated(protocol_config_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS market_oracle_template_config_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    protocol_config_id               TEXT      NOT NULL,
    settlement_freshness_ms          BIGINT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_market_oracle_template_config_updated_config_ts ON market_oracle_template_config_updated(protocol_config_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS ewma_config_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    protocol_config_id               TEXT      NOT NULL,
    alpha                            BIGINT    NOT NULL,
    z_score_threshold                BIGINT    NOT NULL,
    penalty_rate                     NUMERIC   NOT NULL,
    enabled                          BOOLEAN   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_ewma_config_updated_config_ts ON ewma_config_updated(protocol_config_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS stake_config_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    protocol_config_id               TEXT      NOT NULL,
    lower_benefit_power              NUMERIC   NOT NULL,
    upper_benefit_power              NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_stake_config_updated_config_ts ON stake_config_updated(protocol_config_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS trading_paused_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    protocol_config_id               TEXT      NOT NULL,
    paused                           BOOLEAN   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_trading_paused_updated_config_ts ON trading_paused_updated(protocol_config_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS market_created (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    expiry_market_id                 TEXT      NOT NULL,
    market_oracle_id                 TEXT      NOT NULL,
    pool_vault_id                    TEXT      NOT NULL,
    pyth_source_id                   TEXT      NOT NULL,
    pyth_lazer_feed_id               BIGINT    NOT NULL,
    expiry                           BIGINT    NOT NULL,
    min_strike                       NUMERIC   NOT NULL,
    tick_size                        NUMERIC   NOT NULL,
    max_strike                       NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_market_created_market_ts ON market_created(expiry_market_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_market_created_market_oracle_id ON market_created(market_oracle_id);
CREATE INDEX IF NOT EXISTS idx_market_created_pool_vault_id ON market_created(pool_vault_id);
CREATE INDEX IF NOT EXISTS idx_market_created_pyth_source_id ON market_created(pyth_source_id);

CREATE TABLE IF NOT EXISTS market_config_snapshot (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    expiry_market_id                 TEXT      NOT NULL,
    market_oracle_id                 TEXT      NOT NULL,
    terminal_floor_index             BIGINT    NOT NULL,
    liquidation_ltv                  BIGINT    NOT NULL,
    backing_buffer_lambda            BIGINT    NOT NULL,
    base_fee                         NUMERIC   NOT NULL,
    min_fee                          NUMERIC   NOT NULL,
    min_ask_price                    NUMERIC   NOT NULL,
    max_ask_price                    NUMERIC   NOT NULL,
    expiry_fee_window_ms             BIGINT    NOT NULL,
    expiry_fee_max_multiplier        BIGINT    NOT NULL,
    trading_loss_rebate_rate         BIGINT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_market_config_snapshot_market_ts ON market_config_snapshot(expiry_market_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_market_config_snapshot_market_oracle_id ON market_config_snapshot(market_oracle_id);

CREATE TABLE IF NOT EXISTS market_oracle_config_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    market_oracle_id                 TEXT      NOT NULL,
    settlement_freshness_ms          BIGINT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_market_oracle_config_updated_oracle_ts ON market_oracle_config_updated(market_oracle_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS expiry_market_mint_paused_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    expiry_market_id                 TEXT      NOT NULL,
    paused                           BOOLEAN   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_expiry_market_mint_paused_updated_market_ts ON expiry_market_mint_paused_updated(expiry_market_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS block_scholes_prices_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    market_oracle_id                 TEXT      NOT NULL,
    spot                             NUMERIC   NOT NULL,
    forward                          NUMERIC   NOT NULL,
    basis                            NUMERIC   NOT NULL,
    source_timestamp_ms              BIGINT    NOT NULL,
    update_timestamp_ms              BIGINT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_block_scholes_prices_updated_oracle_ts ON block_scholes_prices_updated(market_oracle_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS block_scholes_svi_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    market_oracle_id                 TEXT      NOT NULL,
    a                                NUMERIC   NOT NULL,
    b                                NUMERIC   NOT NULL,
    rho                              NUMERIC   NOT NULL,
    m                                NUMERIC   NOT NULL,
    sigma                            NUMERIC   NOT NULL,
    source_timestamp_ms              BIGINT    NOT NULL,
    update_timestamp_ms              BIGINT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_block_scholes_svi_updated_oracle_ts ON block_scholes_svi_updated(market_oracle_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS pyth_source_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    pyth_source_id                   TEXT      NOT NULL,
    feed_id                          BIGINT    NOT NULL,
    spot                             NUMERIC   NOT NULL,
    source_timestamp_ms              BIGINT    NOT NULL,
    update_timestamp_ms              BIGINT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_pyth_source_updated_source_ts ON pyth_source_updated(pyth_source_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_pyth_source_updated_feed_id ON pyth_source_updated(feed_id);

CREATE TABLE IF NOT EXISTS market_oracle_settled (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    market_oracle_id                 TEXT      NOT NULL,
    expiry                           BIGINT    NOT NULL,
    settlement_price                 NUMERIC   NOT NULL,
    spot_source                      SMALLINT  NOT NULL,
    source_timestamp_ms              BIGINT    NOT NULL,
    update_timestamp_ms              BIGINT    NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_market_oracle_settled_oracle_ts ON market_oracle_settled(market_oracle_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS supply_executed (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    pool_vault_id                    TEXT      NOT NULL,
    payment                          NUMERIC   NOT NULL,
    shares_minted                    NUMERIC   NOT NULL,
    pool_value_before                NUMERIC   NOT NULL,
    incentive_value                  NUMERIC   NOT NULL,
    total_supply_after               NUMERIC   NOT NULL,
    idle_balance_after               NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_supply_executed_vault_ts ON supply_executed(pool_vault_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS withdraw_executed (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    pool_vault_id                    TEXT      NOT NULL,
    shares_burned                    NUMERIC   NOT NULL,
    payout                           NUMERIC   NOT NULL,
    withdraw_fee                     NUMERIC   NOT NULL,
    pool_value_before                NUMERIC   NOT NULL,
    total_supply_after               NUMERIC   NOT NULL,
    idle_balance_after               NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_withdraw_executed_vault_ts ON withdraw_executed(pool_vault_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS expiry_cash_rebalanced (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    pool_vault_id                    TEXT      NOT NULL,
    expiry_market_id                 TEXT      NOT NULL,
    amount                           NUMERIC   NOT NULL,
    to_expiry                        BOOLEAN   NOT NULL,
    target_cash                      NUMERIC   NOT NULL,
    expiry_cash_after                NUMERIC   NOT NULL,
    idle_balance_after               NUMERIC   NOT NULL,
    sent_to_expiry_after             NUMERIC   NOT NULL,
    received_from_expiry_after       NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_expiry_cash_rebalanced_vault_ts ON expiry_cash_rebalanced(pool_vault_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_expiry_cash_rebalanced_expiry_ts ON expiry_cash_rebalanced(expiry_market_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS expiry_max_funding_updated (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    pool_vault_id                    TEXT      NOT NULL,
    expiry_market_id                 TEXT      NOT NULL,
    max_expiry_funding               NUMERIC   NOT NULL,
    net_funding                      NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_expiry_max_funding_updated_vault_ts ON expiry_max_funding_updated(pool_vault_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_expiry_max_funding_updated_expiry_ts ON expiry_max_funding_updated(expiry_market_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS expiry_cash_received (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    pool_vault_id                    TEXT      NOT NULL,
    expiry_market_id                 TEXT      NOT NULL,
    settlement_price                 NUMERIC   NOT NULL,
    amount                           NUMERIC   NOT NULL,
    idle_balance_after               NUMERIC   NOT NULL,
    sent_to_expiry_after             NUMERIC   NOT NULL,
    received_from_expiry_after       NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_expiry_cash_received_vault_ts ON expiry_cash_received(pool_vault_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_expiry_cash_received_expiry_ts ON expiry_cash_received(expiry_market_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS expiry_profit_materialized (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    pool_vault_id                    TEXT      NOT NULL,
    expiry_market_id                 TEXT      NOT NULL,
    lp_profit                        NUMERIC   NOT NULL,
    protocol_profit                  NUMERIC   NOT NULL,
    idle_balance_after               NUMERIC   NOT NULL,
    protocol_reserve_balance_after   NUMERIC   NOT NULL,
    profit_basis_after               NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_expiry_profit_materialized_vault_ts ON expiry_profit_materialized(pool_vault_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_expiry_profit_materialized_expiry_ts ON expiry_profit_materialized(expiry_market_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS deep_staked (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    pool_vault_id                    TEXT      NOT NULL,
    predict_manager_id               TEXT      NOT NULL,
    amount                           NUMERIC   NOT NULL,
    active_stake_after               NUMERIC   NOT NULL,
    inactive_stake_after             NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_deep_staked_manager_ts ON deep_staked(predict_manager_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_deep_staked_vault_ts ON deep_staked(pool_vault_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS deep_unstaked (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    pool_vault_id                    TEXT      NOT NULL,
    predict_manager_id               TEXT      NOT NULL,
    amount                           NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_deep_unstaked_manager_ts ON deep_unstaked(predict_manager_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_deep_unstaked_vault_ts ON deep_unstaked(pool_vault_id, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS builder_fees_claimed (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    builder_code_id                  TEXT      NOT NULL,
    owner                            TEXT      NOT NULL,
    amount                           NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_builder_fees_claimed_code_ts ON builder_fees_claimed(builder_code_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_builder_fees_claimed_owner_ts ON builder_fees_claimed(owner, checkpoint_timestamp_ms);

CREATE TABLE IF NOT EXISTS trading_loss_rebate_claimed (
    event_digest                     TEXT      PRIMARY KEY,
    digest                           TEXT      NOT NULL,
    sender                           TEXT      NOT NULL,
    checkpoint                       BIGINT    NOT NULL,
    tx_index                         BIGINT    NOT NULL,
    event_index                      BIGINT    NOT NULL,
    timestamp                        TIMESTAMP DEFAULT CURRENT_TIMESTAMP NOT NULL,
    checkpoint_timestamp_ms          BIGINT    NOT NULL,
    package                          TEXT      NOT NULL,
    expiry_market_id                 TEXT      NOT NULL,
    predict_manager_id               TEXT      NOT NULL,
    trading_fees_paid                NUMERIC   NOT NULL,
    gross_profit                     NUMERIC   NOT NULL,
    eligible_rebate                  NUMERIC   NOT NULL,
    rebate_amount                    NUMERIC   NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_trading_loss_rebate_claimed_manager_ts ON trading_loss_rebate_claimed(predict_manager_id, checkpoint_timestamp_ms);
CREATE INDEX IF NOT EXISTS idx_trading_loss_rebate_claimed_expiry_ts ON trading_loss_rebate_claimed(expiry_market_id, checkpoint_timestamp_ms);
